import Foundation

/// Export/import of transactions as CSV.
public enum CSVExchange {
    public static let header = ["Date", "Type", "Amount", "Currency", "Category", "Wallet", "Note", "To Wallet", "To Amount", "To Currency"]

    static let posix = Locale(identifier: "en_US_POSIX")

    public static func export(_ data: AppData, transactions: [Txn]? = nil, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = posix; f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = [header.joined(separator: ",")]
        let txs = (transactions ?? data.transactions).sorted { $0.date < $1.date }
        for t in txs {
            let type: String
            switch t.kind {
            case .income: type = "Income"
            case .expense: type = "Expense"
            case .transfer: type = "Transfer"
            }
            var fields = [
                f.string(from: t.date),
                type,
                MoneyMath.plainString(t.amountMinor, currency: t.currency),
                t.currency,
                t.isTransfer ? "" : (data.category(t.categoryID)?.name ?? ""),
                data.wallet(t.walletID)?.name ?? "",
                t.note
            ]
            if t.isTransfer {
                fields += [t.toWalletID.flatMap { data.wallet($0)?.name } ?? "",
                           MoneyMath.plainString(t.creditedMinor, currency: t.creditedCurrency), t.creditedCurrency]
            } else {
                fields += ["", "", ""]
            }
            lines.append(fields.map { CSV.escape($0) }.joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Import

    public enum Column: String, CaseIterable {
        case date, time, type, amount, income, expense, currency, category, wallet, note, labels, toWallet, toAmount, toCurrency
    }

    static let synonyms: [Column: [String]] = [
        .date: ["date", "дата", "datetime", "date and time", "дата и время", "дата і час", "transaction date", "day"],
        .time: ["time", "время", "час"],
        .type: ["type", "тип", "kind", "transaction type", "тип операции", "тип операції", "income/expense", "category type"],
        .amount: ["amount", "сумма", "сума", "sum", "value", "price"],
        .income: ["income", "доход", "дохід", "приход"],
        .expense: ["expense", "expenses", "расход", "витрата", "витрати", "outcome"],
        .currency: ["currency", "валюта", "currency code", "cur"],
        .category: ["category", "категория", "категорія", "category name", "categories"],
        .wallet: ["wallet", "account", "кошелек", "кошелёк", "гаманець", "счет", "счёт", "рахунок", "wallet name", "account name", "from wallet"],
        .labels: ["labels", "label", "tags", "метки", "мітки", "теги"],
        .note: ["note", "notes", "comment", "comments", "memo", "description", "комментарий", "коментар", "примечание", "нотатка", "заметка", "title", "name"],
        .toWallet: ["to wallet", "to account", "в кошелек", "в гаманець", "destination wallet"],
        .toAmount: ["to amount", "credited amount", "сумма зачисления", "сума зарахування"],
        .toCurrency: ["to currency", "валюта зачисления", "валюта зарахування"]
    ]

    public static func mapHeader(_ header: [String]) -> [Column: Int] {
        var map: [Column: Int] = [:]
        for (i, raw) in header.enumerated() {
            let h = TextNorm.normalize(raw)
            for col in Column.allCases where map[col] == nil {
                if synonyms[col]!.contains(where: { TextNorm.normalize($0) == h }) { map[col] = i; break }
            }
        }
        return map
    }

    /// Per-currency totals of income and expense (transfers excluded), for reconciliation.
    public struct CurrencyTotals: Hashable {
        public var income: [String: Int64] = [:]
        public var expense: [String: Int64] = [:]
    }

    public struct ImportPlan {
        public var newCategories: [Category] = []
        public var newWallets: [Wallet] = []
        public var transactions: [Txn] = []
        public var duplicates: Int = 0
        /// Transfers recognised (Spendee outgoing+incoming pairs merged into one each, or single "Transfer" rows).
        public var pairedTransfers: Int = 0
        /// Transfer rows without a counterpart (other wallet not in the file) — kept as income/expense "Transfer".
        public var unpairedTransfers: Int = 0
        public var errors: [(line: Int, message: String)] = []
        /// Data rows in the file (excluding header and blank lines).
        public var rowCount: Int = 0
        /// Totals as written in the file (valid income/expense rows; transfer rows excluded).
        public var sourceTotals = CurrencyTotals()
        public var transfers: Int { pairedTransfers + unpairedTransfers }
        public var mutation: Mutation {
            .batch(newCategories.map { .upsertCategory($0) } + newWallets.map { .upsertWallet($0) } + [.addTransactions(transactions)])
        }
        /// Totals of income/expense transactions that will be added (unpaired transfer halves excluded).
        public var plannedTotals: CurrencyTotals {
            var t = CurrencyTotals()
            for x in transactions where !x.note.hasPrefix(CSVExchange.unpairedMarker) {
                if x.kind == .income { t.income[x.currency, default: 0] += x.amountMinor }
                if x.kind == .expense { t.expense[x.currency, default: 0] += x.amountMinor }
            }
            return t
        }
    }

    /// Note prefix for transfer halves imported as income/expense (so they can be found and fixed later).
    public static let unpairedMarker = "[transfer] "

    static let dateFormats = [
        "yyyy-MM-dd HH:mm:ssZZZZZ", "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd",
        "dd.MM.yyyy HH:mm:ss", "dd.MM.yyyy HH:mm", "dd.MM.yyyy", "dd.MM.yy",
        "dd/MM/yyyy HH:mm", "dd/MM/yyyy", "MM/dd/yyyy HH:mm", "MM/dd/yyyy", "yyyy/MM/dd HH:mm", "yyyy/MM/dd",
        "MMM d, yyyy HH:mm", "MMM d, yyyy", "d MMM yyyy", "d MMM yyyy HH:mm"
    ]

    public static func parseDate(_ s: String, timeZone: TimeZone) -> Date? {
        let str = s.trimmingCharacters(in: .whitespaces)
        if str.isEmpty { return nil }
        let f = DateFormatter()
        f.locale = posix; f.timeZone = timeZone; f.isLenient = false
        for fmt in dateFormats {
            f.dateFormat = fmt
            if let d = f.date(from: str) { return d }
        }
        if let d = ISO8601.formatter.date(from: str) ?? ISO8601.plain.date(from: str) { return d }
        return nil
    }

    enum RowType { case expense, income, transfer, transferOut, transferIn }

    static func parseType(_ s: String) -> RowType? {
        let v = TextNorm.normalize(s)
        if ["outgoing transfer", "transfer out"].contains(v) { return .transferOut }
        if ["incoming transfer", "transfer in"].contains(v) { return .transferIn }
        if ["transfer", "перевод", "переказ"].contains(v) { return .transfer }
        if ["expense", "expenses", "расход", "расходы", "витрата", "витрати", "-", "out", "outcome", "debit", "spending"].contains(v) { return .expense }
        if ["income", "доход", "доходы", "дохід", "доходи", "+", "in", "credit", "earning"].contains(v) { return .income }
        return nil
    }

    struct Row {
        var line: Int
        var date: Date
        var type: RowType
        var amount: Int64 // positive
        var currency: String
        var walletName: String
        var categoryName: String
        var note: String
        var toWalletName: String
        var toAmount: Int64?
        var toCurrency: String
    }

    public static func plan(csv text: String, into data: AppData, timeZone: TimeZone = .current,
                            fallbackCategoryName: String = "Другое") -> ImportPlan {
        var plan = ImportPlan()
        let table = CSV.parse(text)
        guard let header = table.first else { plan.errors.append((1, "empty file")); return plan }
        let map = mapHeader(header)
        guard map[.date] != nil, map[.amount] != nil || map[.income] != nil || map[.expense] != nil else {
            plan.errors.append((1, "required columns not found: date and amount"))
            return plan
        }
        let base = data.settings.baseCurrency

        func cell(_ row: [String], _ col: Column) -> String {
            guard let i = map[col], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 1. Parse rows.
        var rows: [Row] = []
        for (offset, raw) in table.dropFirst().enumerated() {
            let line = offset + 2
            if raw.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            plan.rowCount += 1
            var dateText = cell(raw, .date)
            let timeText = cell(raw, .time)
            if !timeText.isEmpty { dateText += " " + timeText }
            guard let date = parseDate(dateText, timeZone: timeZone) else { plan.errors.append((line, "bad date '\(dateText)'")); continue }

            let walletName = cell(raw, .wallet)
            var currency = cell(raw, .currency).uppercased()
            if currency.isEmpty { currency = (walletName.isEmpty ? data.defaultWallet : data.walletNamed(walletName))?.currency ?? base }
            if currency.count != 3 { currency = base }

            let typeText = cell(raw, .type)
            var type = parseType(typeText)
            if !typeText.isEmpty && type == nil { plan.errors.append((line, "unknown type '\(typeText)'")); continue }
            var signed: Int64?
            if map[.amount] != nil {
                signed = MoneyMath.parseMinor(cell(raw, .amount), currency: currency)
            } else {
                let inc = MoneyMath.parseMinor(cell(raw, .income), currency: currency) ?? 0
                let exp = MoneyMath.parseMinor(cell(raw, .expense), currency: currency) ?? 0
                if inc != 0 { signed = abs(inc); type = type ?? .income } else if exp != 0 { signed = -abs(exp); type = type ?? .expense }
            }
            guard let s = signed, s != 0 else { plan.errors.append((line, "bad amount")); continue }
            let t = type ?? (s < 0 ? .expense : .income)

            var note = cell(raw, .note)
            let labels = cell(raw, .labels)
            if !labels.isEmpty {
                note += (note.isEmpty ? "" : " ") + labels.split(whereSeparator: { $0 == "," || $0 == ";" })
                    .map { "#" + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            }
            let toCurRaw = cell(raw, .toCurrency).uppercased()
            let toCurrency = toCurRaw.count == 3 ? toCurRaw : currency
            let toAmountText = cell(raw, .toAmount)
            let toAmount = toAmountText.isEmpty ? nil : MoneyMath.parseMinor(toAmountText, currency: toCurrency).map { abs($0) }

            if t == .expense { plan.sourceTotals.expense[currency, default: 0] += abs(s) }
            if t == .income { plan.sourceTotals.income[currency, default: 0] += abs(s) }
            rows.append(Row(line: line, date: date, type: t, amount: abs(s), currency: currency, walletName: walletName,
                            categoryName: cell(raw, .category), note: note, toWalletName: cell(raw, .toWallet),
                            toAmount: toAmount, toCurrency: toCurrency))
        }

        // 2. Pair Spendee transfer halves: outgoing (wallet A) + incoming (wallet B) at the same moment.
        var pairOf: [Int: Int] = [:] // out index -> in index
        var usedIn = Set<Int>()
        let ins = rows.indices.filter { rows[$0].type == .transferIn }
        for o in rows.indices where rows[o].type == .transferOut {
            let candidates = ins.filter { i in
                !usedIn.contains(i) && abs(rows[i].date.timeIntervalSince(rows[o].date)) <= 60 &&
                TextNorm.normalize(rows[i].walletName) != TextNorm.normalize(rows[o].walletName)
            }
            let exact = candidates.first { rows[$0].amount == rows[o].amount && rows[$0].currency == rows[o].currency }
            let crossCurrency = candidates.first { rows[$0].currency != rows[o].currency }
            if let b = exact ?? crossCurrency { pairOf[o] = b; usedIn.insert(b) }
        }

        // 3. Build transactions.
        var work = data
        var paletteIndex = data.categories.count

        func wallet(_ name: String, currency: String) -> Wallet {
            if name.isEmpty, let w = work.defaultWallet { return w }
            if let w = work.walletNamed(name) { return w }
            let w = Wallet(name: name.isEmpty ? "Imported" : name, currency: currency,
                           colorHex: Defaults.palette[(work.wallets.count * 5) % Defaults.palette.count],
                           sortOrder: (work.wallets.map { $0.sortOrder }.max() ?? 0) + 1)
            plan.newWallets.append(w)
            work.wallets.append(w)
            return w
        }

        func category(_ rawName: String, kind: TxKind) -> Category {
            let name = rawName.isEmpty ? fallbackCategoryName : rawName
            if let c = work.categoryNamed(name, kind: kind) { return c }
            let c = Category(name: name, kind: kind, icon: .symbol(name == "Transfer" ? "arrow.left.arrow.right" : "tag.fill"),
                             colorHex: Defaults.palette[paletteIndex % Defaults.palette.count],
                             sortOrder: (work.categories.map { $0.sortOrder }.max() ?? 0) + 1)
            paletteIndex += 1
            plan.newCategories.append(c)
            work.categories.append(c)
            return c
        }

        // Duplicate lookup against existing data (hash keys, so 10k+ rows stay fast).
        func key(_ t: Txn, in d: AppData) -> String {
            let minute = Int((t.date.timeIntervalSince1970 / 60).rounded(.down))
            return [t.kind.rawValue, String(t.amountMinor), t.currency, String(minute),
                    TextNorm.normalize(t.isTransfer ? "" : (d.category(t.categoryID)?.name ?? "")),
                    TextNorm.normalize(d.wallet(t.walletID)?.name ?? ""),
                    TextNorm.normalize(t.toWalletID.flatMap { d.wallet($0)?.name } ?? ""),
                    TextNorm.normalize(t.note)].joined(separator: "|")
        }
        var existing: [String: Int] = [:]
        for t in data.transactions { existing[key(t, in: data), default: 0] += 1 }

        func add(_ t: Txn) {
            let k = key(t, in: work)
            if let n = existing[k], n > 0 { existing[k] = n - 1; plan.duplicates += 1; return }
            plan.transactions.append(t)
        }

        for (idx, r) in rows.enumerated() {
            switch r.type {
            case .expense, .income:
                let kind: TxKind = r.type == .expense ? .expense : .income
                let w = wallet(r.walletName, currency: r.currency)
                let c = category(r.categoryName, kind: kind)
                add(Txn(kind: kind, amountMinor: r.amount, currency: r.currency, categoryID: c.id, walletID: w.id,
                        date: r.date, note: r.note, source: .imported))
            case .transfer:
                guard !r.toWalletName.isEmpty else { plan.errors.append((r.line, "transfer without destination wallet")); continue }
                let from = wallet(r.walletName, currency: r.currency)
                let to = wallet(r.toWalletName, currency: r.toCurrency)
                guard from.id != to.id else { plan.errors.append((r.line, "transfer to the same wallet")); continue }
                plan.pairedTransfers += 1
                add(Txn.transfer(from: from.id, to: to.id, amountMinor: r.amount, currency: r.currency,
                                 toAmountMinor: r.toAmount ?? r.amount, toCurrency: r.toCurrency, date: r.date, note: r.note,
                                 source: .imported))
            case .transferOut:
                if let i = pairOf[idx] {
                    let inRow = rows[i]
                    let from = wallet(r.walletName, currency: r.currency)
                    let to = wallet(inRow.walletName, currency: inRow.currency)
                    plan.pairedTransfers += 1
                    add(Txn.transfer(from: from.id, to: to.id, amountMinor: r.amount, currency: r.currency,
                                     toAmountMinor: inRow.amount, toCurrency: inRow.currency, date: r.date,
                                     note: r.note.isEmpty ? inRow.note : r.note, source: .imported))
                } else {
                    plan.unpairedTransfers += 1
                    let w = wallet(r.walletName, currency: r.currency)
                    add(Txn(kind: .expense, amountMinor: r.amount, currency: r.currency,
                            categoryID: category(r.categoryName.isEmpty ? "Transfer" : r.categoryName, kind: .expense).id,
                            walletID: w.id, date: r.date, note: unpairedMarker + r.note, source: .imported))
                }
            case .transferIn:
                if usedIn.contains(idx) { continue }
                plan.unpairedTransfers += 1
                let w = wallet(r.walletName, currency: r.currency)
                add(Txn(kind: .income, amountMinor: r.amount, currency: r.currency,
                        categoryID: category(r.categoryName.isEmpty ? "Transfer" : r.categoryName, kind: .income).id,
                        walletID: w.id, date: r.date, note: unpairedMarker + r.note, source: .imported))
            }
        }
        return plan
    }
}
