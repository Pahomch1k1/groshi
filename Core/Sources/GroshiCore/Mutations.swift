import Foundation

public enum MutationError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case invalid(String)
    case conflict(String)

    public var description: String {
        switch self {
        case .notFound(let s): return "not found: \(s)"
        case .invalid(let s): return "invalid: \(s)"
        case .conflict(let s): return "conflict: \(s)"
        }
    }
}

/// Destination side of a transfer.
public struct TransferTarget: Hashable {
    public var toWalletID: UUID
    /// nil = same amount and currency as the source side.
    public var toAmountMinor: Int64?
    public var toCurrency: String?
    public init(toWalletID: UUID, toAmountMinor: Int64? = nil, toCurrency: String? = nil) {
        self.toWalletID = toWalletID; self.toAmountMinor = toAmountMinor; self.toCurrency = toCurrency
    }
}

/// Field changes for one or more transactions. nil = keep.
public struct TxChanges: Hashable {
    public var kind: TxKind?
    public var amountMinor: Int64?
    public var currency: String?
    public var categoryID: UUID?
    public var walletID: UUID?
    public var date: Date?
    public var note: String?
    /// For transfers: new destination (replaces destination wallet, amount and currency together).
    public var transfer: TransferTarget?
    public init(kind: TxKind? = nil, amountMinor: Int64? = nil, currency: String? = nil, categoryID: UUID? = nil,
                walletID: UUID? = nil, date: Date? = nil, note: String? = nil, transfer: TransferTarget? = nil) {
        self.kind = kind; self.amountMinor = amountMinor; self.currency = currency; self.categoryID = categoryID
        self.walletID = walletID; self.date = date; self.note = note; self.transfer = transfer
    }
}

/// Every change to the data goes through one of these. They are pure functions of AppData,
/// which keeps manual and AI edits consistent and lets the app snapshot state for undo.
public enum Mutation: Hashable {
    case addTransactions([Txn])
    case updateTransactions(ids: [UUID], changes: TxChanges)
    case deleteTransactions([UUID])
    case upsertCategory(Category)
    case deleteCategory(id: UUID, moveTo: UUID?)
    case upsertWallet(Wallet)
    case deleteWallet(id: UUID, moveTo: UUID?)
    case updateSettings(AppSettings)
    case replaceAll(AppData)
    case batch([Mutation])

    /// How many transactions this touches (for "mass change" confirmation policy).
    public var affectedTransactionCount: Int {
        switch self {
        case .addTransactions(let t): return t.count
        case .updateTransactions(let ids, _): return ids.count
        case .deleteTransactions(let ids): return ids.count
        case .batch(let list): return list.reduce(0) { $0 + $1.affectedTransactionCount }
        default: return 0
        }
    }

    public var isDestructive: Bool {
        switch self {
        case .deleteTransactions, .deleteCategory, .deleteWallet, .replaceAll: return true
        case .batch(let list): return list.contains { $0.isDestructive }
        default: return false
        }
    }

    public func apply(to data: inout AppData) throws {
        switch self {
        case .addTransactions(let txs):
            var normalized: [Txn] = []
            for var t in txs {
                try Mutation.validate(&t, in: data)
                guard !data.transactions.contains(where: { $0.id == t.id }) else { throw MutationError.conflict("duplicate id") }
                normalized.append(t)
            }
            data.transactions.append(contentsOf: normalized)

        case .updateTransactions(let ids, let ch):
            for id in ids {
                guard let i = data.transactions.firstIndex(where: { $0.id == id }) else { throw MutationError.notFound("transaction") }
                var t = data.transactions[i]
                if let v = ch.kind { t.kind = v }
                if let v = ch.amountMinor { guard v > 0 else { throw MutationError.invalid("amount") }; t.amountMinor = v }
                if let v = ch.currency { t.currency = v.uppercased() }
                if let v = ch.categoryID { t.categoryID = v }
                if let v = ch.walletID { t.walletID = v }
                if let v = ch.date { t.date = v }
                if let v = ch.note { t.note = v }
                if let tr = ch.transfer {
                    t.toWalletID = tr.toWalletID; t.toAmountMinor = tr.toAmountMinor; t.toCurrency = tr.toCurrency?.uppercased()
                }
                try Mutation.validate(&t, in: data)
                data.transactions[i] = t
            }

        case .deleteTransactions(let ids):
            let set = Set(ids)
            let before = data.transactions.count
            data.transactions.removeAll { set.contains($0.id) }
            if before - data.transactions.count != set.count { throw MutationError.notFound("transaction") }

        case .upsertCategory(let c):
            let name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw MutationError.invalid("empty name") }
            if let other = data.categories.first(where: { $0.id != c.id && $0.kind == c.kind && !$0.isArchived && TextNorm.normalize($0.name) == TextNorm.normalize(name) }) {
                throw MutationError.conflict("category exists: \(other.name)")
            }
            var cc = c; cc.name = name
            if let i = data.categories.firstIndex(where: { $0.id == c.id }) {
                if data.categories[i].kind != cc.kind && data.transactions.contains(where: { $0.categoryID == c.id }) {
                    throw MutationError.invalid("cannot change kind of a used category")
                }
                data.categories[i] = cc
            } else {
                if cc.sortOrder == 0 { cc.sortOrder = (data.categories.filter { $0.kind == cc.kind }.map { $0.sortOrder }.max() ?? 0) + 1 }
                data.categories.append(cc)
            }

        case .deleteCategory(let id, let moveTo):
            guard let cat = data.category(id) else { throw MutationError.notFound("category") }
            let used = data.transactions.contains { $0.categoryID == id }
            if used {
                if let target = moveTo {
                    guard let t = data.category(target), t.kind == cat.kind, t.id != id else { throw MutationError.invalid("bad target category") }
                    for i in data.transactions.indices where data.transactions[i].categoryID == id { data.transactions[i].categoryID = target }
                    data.categories.removeAll { $0.id == id }
                } else {
                    // Keep history intact: archive instead of deleting.
                    if let i = data.categories.firstIndex(where: { $0.id == id }) { data.categories[i].isArchived = true }
                }
            } else {
                data.categories.removeAll { $0.id == id }
            }

        case .upsertWallet(let w):
            let name = w.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw MutationError.invalid("empty name") }
            if let other = data.wallets.first(where: { $0.id != w.id && !$0.isArchived && TextNorm.normalize($0.name) == TextNorm.normalize(name) }) {
                throw MutationError.conflict("wallet exists: \(other.name)")
            }
            var ww = w; ww.name = name
            if let i = data.wallets.firstIndex(where: { $0.id == w.id }) {
                data.wallets[i] = ww
            } else {
                ww.sortOrder = (data.wallets.map { $0.sortOrder }.max() ?? 0) + 1
                data.wallets.append(ww)
            }

        case .deleteWallet(let id, let moveTo):
            guard data.wallet(id) != nil else { throw MutationError.notFound("wallet") }
            let used = data.transactions.contains { $0.involves(wallet: id) }
            if used {
                if let target = moveTo {
                    guard data.wallet(target) != nil, target != id else { throw MutationError.invalid("bad target wallet") }
                    for i in data.transactions.indices {
                        if data.transactions[i].walletID == id { data.transactions[i].walletID = target }
                        if data.transactions[i].toWalletID == id { data.transactions[i].toWalletID = target }
                    }
                    // A transfer between the deleted wallet and the target becomes a self-transfer: drop it.
                    data.transactions.removeAll { $0.isTransfer && $0.walletID == $0.toWalletID }
                    data.wallets.removeAll { $0.id == id }
                } else if let i = data.wallets.firstIndex(where: { $0.id == id }) {
                    data.wallets[i].isArchived = true
                }
            } else {
                data.wallets.removeAll { $0.id == id }
            }
            if data.settings.defaultWalletID == id { data.settings.defaultWalletID = data.activeWallets.first?.id }

        case .updateSettings(let s):
            data.settings = s

        case .replaceAll(let d):
            data = d

        case .batch(let list):
            var copy = data
            for m in list { try m.apply(to: &copy) }
            data = copy
        }
    }
}

extension Mutation {
    /// Checks a transaction against the data and normalizes transfer/category fields.
    static func validate(_ t: inout Txn, in data: AppData) throws {
        guard t.amountMinor > 0 else { throw MutationError.invalid("amount must be positive") }
        guard data.wallet(t.walletID) != nil else { throw MutationError.notFound("wallet") }
        if t.kind == .transfer {
            guard let to = t.toWalletID, data.wallet(to) != nil else { throw MutationError.notFound("destination wallet") }
            guard to != t.walletID else { throw MutationError.invalid("transfer needs two different wallets") }
            if let a = t.toAmountMinor { guard a > 0 else { throw MutationError.invalid("credited amount must be positive") } }
            // Same currency on both sides: store a single amount.
            if t.toCurrency == nil || t.toCurrency == t.currency { t.toCurrency = nil; t.toAmountMinor = nil }
            t.categoryID = Txn.noCategory
        } else {
            guard let c = data.category(t.categoryID) else { throw MutationError.notFound("category") }
            guard c.kind == t.kind else { throw MutationError.invalid("category kind does not match transaction kind") }
            t.toWalletID = nil; t.toAmountMinor = nil; t.toCurrency = nil
        }
    }
}

/// Duplicate protection for new transactions.
public enum DuplicateCheck {
    /// Returns existing transactions that look like the same purchase: same kind, amount, currency, category and day,
    /// and either recorded within the last `recentWindow` seconds or with an identical non-empty note.
    public static func suspects(for new: Txn, in data: AppData, calendar cal: Calendar, now: Date = Date(),
                                recentWindow: TimeInterval = 15 * 60) -> [Txn] {
        data.transactions.filter { t in
            t.id != new.id && t.kind == new.kind && t.amountMinor == new.amountMinor && t.currency == new.currency &&
            t.categoryID == new.categoryID && t.walletID == new.walletID && t.toWalletID == new.toWalletID &&
            cal.isDate(t.date, inSameDayAs: new.date) &&
            (now.timeIntervalSince(t.createdAt) < recentWindow ||
             (!new.note.isEmpty && TextNorm.normalize(t.note) == TextNorm.normalize(new.note)))
        }
    }
}
