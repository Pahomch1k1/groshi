import Foundation

public enum TxKind: String, Codable, CaseIterable, Hashable {
    case expense
    case income
    /// Money moved between the user's own wallets. Never counted as income or expense.
    case transfer
}

public enum TxSource: String, Codable, Hashable {
    case manual, ai, imported
}

/// Category icon: an SF Symbol from the built-in library, an emoji, or a user-uploaded image file.
public enum CategoryIcon: Codable, Hashable {
    case symbol(String)
    case emoji(String)
    case image(String) // file name inside the app's Icons folder

    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let value = try c.decode(String.self, forKey: .value)
        switch type {
        case "emoji": self = .emoji(value)
        case "image": self = .image(value)
        default: self = .symbol(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symbol(let v): try c.encode("symbol", forKey: .type); try c.encode(v, forKey: .value)
        case .emoji(let v): try c.encode("emoji", forKey: .type); try c.encode(v, forKey: .value)
        case .image(let v): try c.encode("image", forKey: .type); try c.encode(v, forKey: .value)
        }
    }
}

public struct Category: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: TxKind
    public var icon: CategoryIcon
    public var colorHex: String
    public var sortOrder: Int
    public var isArchived: Bool

    public init(id: UUID = UUID(), name: String, kind: TxKind, icon: CategoryIcon, colorHex: String,
                sortOrder: Int = 0, isArchived: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.icon = icon
        self.colorHex = colorHex; self.sortOrder = sortOrder; self.isArchived = isArchived
    }
}

public struct Wallet: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var currency: String
    public var colorHex: String
    public var symbol: String
    public var initialBalanceMinor: Int64
    public var sortOrder: Int
    public var isArchived: Bool

    public init(id: UUID = UUID(), name: String, currency: String, colorHex: String = "#4F7CFF",
                symbol: String = "wallet.pass.fill", initialBalanceMinor: Int64 = 0,
                sortOrder: Int = 0, isArchived: Bool = false) {
        self.id = id; self.name = name; self.currency = currency.uppercased(); self.colorHex = colorHex
        self.symbol = symbol; self.initialBalanceMinor = initialBalanceMinor
        self.sortOrder = sortOrder; self.isArchived = isArchived
    }
}

public struct Txn: Codable, Identifiable, Hashable {
    public var id: UUID
    public var kind: TxKind
    /// Always positive, in minor units of `currency`.
    public var amountMinor: Int64
    public var currency: String
    public var categoryID: UUID
    public var walletID: UUID
    public var date: Date
    public var note: String
    public var createdAt: Date
    public var source: TxSource
    // Transfers only (optional, so data saved by earlier versions decodes unchanged).
    /// Destination wallet; `walletID` is the source wallet.
    public var toWalletID: UUID?
    /// Amount credited to the destination, in `toCurrency`. nil = same as `amountMinor`/`currency`.
    public var toAmountMinor: Int64?
    public var toCurrency: String?
    // Added in 0.2 (optional for compatibility with saved 0.1 data).
    /// Label names attached to the transaction.
    public var labels: [String]?
    /// "Exclude from Overview": kept in history and balances, left out of income/expense statistics.
    public var excluded: Bool?
    /// The recurring rule that produced this transaction, if any.
    public var recurringID: UUID?
    // Added in 0.5 (optional for compatibility).
    /// Id of the AI submission (one voice draft) that created it: a repeated send of the same draft
    /// finds the operations already saved instead of creating them twice.
    public var requestID: String?

    /// Category placeholder used by transfers (they have no category).
    public static let noCategory = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    public init(id: UUID = UUID(), kind: TxKind, amountMinor: Int64, currency: String, categoryID: UUID,
                walletID: UUID, date: Date, note: String = "", createdAt: Date = Date(), source: TxSource = .manual,
                toWalletID: UUID? = nil, toAmountMinor: Int64? = nil, toCurrency: String? = nil,
                labels: [String] = [], excluded: Bool = false, recurringID: UUID? = nil) {
        self.id = id; self.kind = kind; self.amountMinor = abs(amountMinor); self.currency = currency.uppercased()
        self.categoryID = categoryID; self.walletID = walletID; self.date = date; self.note = note
        self.createdAt = createdAt; self.source = source
        self.toWalletID = toWalletID; self.toAmountMinor = toAmountMinor.map { abs($0) }; self.toCurrency = toCurrency?.uppercased()
        self.labels = labels.isEmpty ? nil : labels
        self.excluded = excluded ? true : nil
        self.recurringID = recurringID
    }

    public var tags: [String] {
        get { labels ?? [] }
        set { labels = newValue.isEmpty ? nil : newValue }
    }
    public var isExcluded: Bool {
        get { excluded ?? false }
        set { excluded = newValue ? true : nil }
    }
    /// Counted in income/expense statistics.
    public var countsInStats: Bool { !isTransfer && !isExcluded }

    /// Creates a transfer between two wallets. Pass `toAmountMinor`/`toCurrency` when the currencies differ.
    public static func transfer(from: UUID, to: UUID, amountMinor: Int64, currency: String, toAmountMinor: Int64? = nil,
                                toCurrency: String? = nil, date: Date, note: String = "", createdAt: Date = Date(),
                                source: TxSource = .manual) -> Txn {
        let sameCurrency = toCurrency == nil || toCurrency!.uppercased() == currency.uppercased()
        return Txn(kind: .transfer, amountMinor: amountMinor, currency: currency, categoryID: noCategory, walletID: from,
                   date: date, note: note, createdAt: createdAt, source: source, toWalletID: to,
                   toAmountMinor: sameCurrency ? nil : toAmountMinor, toCurrency: sameCurrency ? nil : toCurrency)
    }

    public var isTransfer: Bool { kind == .transfer }

    /// Credited amount and currency on the destination side of a transfer.
    public var creditedMinor: Int64 { toAmountMinor ?? amountMinor }
    public var creditedCurrency: String { toCurrency ?? currency }

    /// Signed amount for cash flow: income positive, expense negative, transfer 0.
    public var signedMinor: Int64 {
        switch kind {
        case .income: return amountMinor
        case .expense: return -amountMinor
        case .transfer: return 0
        }
    }

    /// Effect of this transaction on one wallet's balance (in the currency returned).
    public func balanceEffect(on walletID: UUID) -> (minor: Int64, currency: String)? {
        switch kind {
        case .income: return self.walletID == walletID ? (amountMinor, currency) : nil
        case .expense: return self.walletID == walletID ? (-amountMinor, currency) : nil
        case .transfer:
            if self.walletID == walletID && toWalletID == walletID { return nil }
            if self.walletID == walletID { return (-amountMinor, currency) }
            if toWalletID == walletID { return (creditedMinor, creditedCurrency) }
            return nil
        }
    }

    public func involves(wallet id: UUID) -> Bool { walletID == id || toWalletID == id }
}

public enum AppLanguage: String, Codable, CaseIterable {
    case system, uk, ru, en
}

public enum AppTheme: String, Codable, CaseIterable {
    case system, light, dark
}

public struct AISettings: Codable, Hashable {
    public var enabled: Bool = true
    public static let defaultModel = "gpt-4.1"
    public var model: String = AISettings.defaultModel
    /// Optional proxy endpoint (e.g. a Cloudflare Worker that holds the key). Empty = call OpenAI directly with the Keychain key.
    public var proxyURL: String = ""
    /// BCP-47 locale for speech recognition.
    public var voiceLocale: String = "ru-RU"
    /// Automatically send a voice command when recording stops.
    public var autoSendVoice: Bool = true
    /// Read the assistant's replies aloud.
    public var speakReplies: Bool = true
    /// After a spoken question from the assistant, start listening again automatically.
    public var handsFree: Bool = true
    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, model, proxyURL, voiceLocale, autoSendVoice, speakReplies, handsFree }

    /// Tolerant decoding: files written by older versions lack the newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? AISettings.defaultModel
        // Settings saved before 0.3 still carry the old default; in live tests it asked for dates it had already been given.
        if !c.contains(.speakReplies), model == "gpt-4.1-mini" { model = AISettings.defaultModel }
        proxyURL = try c.decodeIfPresent(String.self, forKey: .proxyURL) ?? ""
        voiceLocale = try c.decodeIfPresent(String.self, forKey: .voiceLocale) ?? "ru-RU"
        autoSendVoice = try c.decodeIfPresent(Bool.self, forKey: .autoSendVoice) ?? true
        speakReplies = try c.decodeIfPresent(Bool.self, forKey: .speakReplies) ?? true
        handsFree = try c.decodeIfPresent(Bool.self, forKey: .handsFree) ?? true
    }
}

public struct AppSettings: Codable, Hashable {
    public var baseCurrency: String = "UAH"
    public var language: AppLanguage = .system
    public var theme: AppTheme = .system
    /// Units of base currency for 1 unit of the given currency, stored as exact decimal strings.
    public var rates: [String: String] = ["USD": "41.50", "EUR": "48.20", "PLN": "11.30"]
    public var ratesUpdatedAt: Date? = nil
    public var defaultWalletID: UUID? = nil
    public var firstWeekday: Int = 2 // Monday
    public var haptics: Bool = true
    public var ai = AISettings()
    public init() {}

    public var converter: CurrencyConverter {
        var r: [String: Decimal] = [:]
        for (k, v) in rates {
            if let d = Decimal(string: v, locale: Locale(identifier: "en_US_POSIX")), d > 0 { r[k.uppercased()] = d }
        }
        return CurrencyConverter(base: baseCurrency, rates: r)
    }
}

/// The whole persisted state. Value type: snapshots make undo trivial and saves atomic.
public struct TxLabel: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var sortOrder: Int
    public init(id: UUID = UUID(), name: String, sortOrder: Int = 0) {
        self.id = id; self.name = name; self.sortOrder = sortOrder
    }
}

public enum Frequency: String, Codable, CaseIterable, Hashable {
    case daily, weekly, monthly, yearly
}

/// A repeating transaction: `template` is copied on each due date.
public struct RecurringRule: Codable, Identifiable, Hashable {
    public var id: UUID
    public var template: Txn
    public var frequency: Frequency
    /// Next date a transaction will be created.
    public var nextDate: Date
    public var endDate: Date?
    public var isActive: Bool
    public init(id: UUID = UUID(), template: Txn, frequency: Frequency, nextDate: Date, endDate: Date? = nil, isActive: Bool = true) {
        self.id = id; self.template = template; self.frequency = frequency; self.nextDate = nextDate
        self.endDate = endDate; self.isActive = isActive
    }
}

public struct AppData: Codable, Hashable {
    public static let currentVersion = 2
    public var version: Int = AppData.currentVersion
    public var categories: [Category] = []
    public var wallets: [Wallet] = []
    public var transactions: [Txn] = []
    public var settings = AppSettings()
    public var labels: [TxLabel] = []
    public var recurring: [RecurringRule] = []

    public init(categories: [Category] = [], wallets: [Wallet] = [], transactions: [Txn] = [], settings: AppSettings = AppSettings()) {
        self.categories = categories; self.wallets = wallets; self.transactions = transactions; self.settings = settings
    }

    private enum CodingKeys: String, CodingKey { case version, categories, wallets, transactions, settings, labels, recurring }

    /// Tolerant decoding: fields added in later versions may be missing in older files.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        categories = try c.decodeIfPresent([Category].self, forKey: .categories) ?? []
        wallets = try c.decodeIfPresent([Wallet].self, forKey: .wallets) ?? []
        transactions = try c.decodeIfPresent([Txn].self, forKey: .transactions) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        labels = try c.decodeIfPresent([TxLabel].self, forKey: .labels) ?? []
        recurring = try c.decodeIfPresent([RecurringRule].self, forKey: .recurring) ?? []
    }

    public var sortedLabels: [TxLabel] {
        labels.sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }
    }

    public func labelNamed(_ name: String) -> TxLabel? {
        let key = TextNorm.normalize(name)
        return labels.first { TextNorm.normalize($0.name) == key }
    }

    // MARK: Lookups

    public func category(_ id: UUID) -> Category? { categories.first { $0.id == id } }
    public func wallet(_ id: UUID) -> Wallet? { wallets.first { $0.id == id } }

    public func categories(of kind: TxKind, includeArchived: Bool = false) -> [Category] {
        categories.filter { $0.kind == kind && (includeArchived || !$0.isArchived) }
            .sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }
    }

    public var activeWallets: [Wallet] {
        wallets.filter { !$0.isArchived }.sorted { $0.sortOrder < $1.sortOrder }
    }

    public var defaultWallet: Wallet? {
        if let id = settings.defaultWalletID, let w = wallet(id), !w.isArchived { return w }
        return activeWallets.first
    }

    /// Case- and diacritic-insensitive name lookup.
    public func categoryNamed(_ name: String, kind: TxKind? = nil) -> Category? {
        let key = TextNorm.normalize(name)
        let pool = categories.filter { kind == nil || $0.kind == kind! }
        return pool.first { TextNorm.normalize($0.name) == key && !$0.isArchived }
            ?? pool.first { TextNorm.normalize($0.name) == key }
    }

    public func walletNamed(_ name: String) -> Wallet? {
        let key = TextNorm.normalize(name)
        return wallets.first { TextNorm.normalize($0.name) == key }
    }

    /// Balance in the wallet's currency (transactions in other currencies converted).
    public func balance(of wallet: Wallet) -> Int64 {
        let conv = settings.converter
        let items = transactions.compactMap { $0.balanceEffect(on: wallet.id) }
        return wallet.initialBalanceMinor + conv.sum(items, into: wallet.currency).total
    }
}

public enum TextNorm {
    public static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
    }
}
