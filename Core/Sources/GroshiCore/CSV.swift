import Foundation

/// RFC 4180 CSV reading/writing.
public enum CSV {
    public static func escape(_ field: String, delimiter: Character = ",") -> String {
        if field.contains(delimiter) || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    public static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).first.map(String.init) ?? text
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        for ch in firstLine {
            if ch == "\"" { inQuotes.toggle() }
            if !inQuotes, counts[ch] != nil { counts[ch]! += 1 }
        }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : (a.key == "," ? false : b.key == ",") }!.key
    }

    public static func parse(_ input: String, delimiter: Character? = nil) -> [[String]] {
        var text = input
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let delim = delimiter ?? detectDelimiter(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(ch)
                }
            } else {
                if ch == "\"" && field.isEmpty {
                    inQuotes = true
                } else if ch == delim {
                    row.append(field); field = ""
                } else if ch == "\n" || ch == "\r" || ch == "\r\n" {
                    if ch == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                } else {
                    field.append(ch)
                }
            }
            i += 1
        }
        return rows
    }
}

/// Export/import of transactions as CSV.
public enum CSVExchange {
    public static let header = ["Date", "Type", "Amount", "Currency", "Category", "Wallet", "Note"]

    static let posix = Locale(identifier: "en_US_POSIX")

    public static func export(_ data: AppData, transactions: [Txn]? = nil, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = posix; f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = [header.joined(separator: ",")]
        let txs = (transactions ?? data.transactions).sorted { $0.date < $1.date }
        for t in txs {
            let fields = [
                f.string(from: t.date),
                t.kind == .income ? "Income" : "Expense",
                MoneyMath.plainString(t.amountMinor, currency: t.currency),
                t.currency,
                data.category(t.categoryID)?.name ?? "",
                data.wallet(t.walletID)?.name ?? "",
                t.note
            ]
            lines.append(fields.map { CSV.escape($0) }.joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Import

    public enum Column: String, CaseIterable { case date, time, type, amount, income, expense, currency, category, wallet, note, labels }

    static let synonyms: [Column: [String]] = [
        .date: ["date", "дата", "datetime", "date and time", "дата и время", "дата і час", "transaction date", "day"],
        .time: ["time", "время", "час"],
        .type: ["type", "тип", "kind", "transaction type", "тип операции", "тип операції", "income/expense"],
        .amount: ["amount", "сумма", "сума", "sum", "value", "price", "amount in default currency"],
        .income: ["income", "доход", "дохід", "приход"],
        .expense: ["expense", "expenses", "расход", "витрата", "витрати", "outcome"],
        .currency: ["currency", "валюта", "currency code", "cur"],
        .category: ["category", "категория", "категорія", "category name", "categories"],
        .wallet: ["wallet", "account", "кошелек", "кошелёк", "гаманець", "счет", "счёт", "рахунок", "wallet name", "account name"],
        .labels: ["labels", "label", "tags", "метки", "мітки", "теги"],
        .note: ["note", "notes", "comment", "comments", "memo", "description", "комментарий", "коментар", "примечание", "нотатка", "заметка", "title", "name"]
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

    public struct ImportPlan {
        public var newCategories: [Category] = []
        public var newWallets: [Wallet] = []
        public var transactions: [Txn] = []
        public var duplicates: Int = 0
        public var transfers: Int = 0
        public var errors: [(line: Int, message: String)] = []
        public var mutation: Mutation {
            .batch(newCategories.map { .upsertCategory($0) } + newWallets.map { .upsertWallet($0) } + [.addTransactions(transactions)])
        }
    }

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

    static func parseKind(_ s: String) -> TxKind? {
        let v = TextNorm.normalize(s)
        if ["expense", "expenses", "расход", "расходы", "витрата", "витрати", "-", "out", "outcome", "debit", "spending", "outgoing transfer", "transfer out"].contains(v) { return .expense }
        if ["income", "доход", "доходы", "дохід", "доходи", "+", "in", "credit", "earning", "incoming transfer", "transfer in"].contains(v) { return .income }
        return nil
    }

    public static func plan(csv text: String, into data: AppData, timeZone: TimeZone = .current,
                            fallbackCategoryName: String = "Другое") -> ImportPlan {
        var plan = ImportPlan()
        let rows = CSV.parse(text)
        guard let header = rows.first else { plan.errors.append((1, "empty file")); return plan }
        let map = mapHeader(header)
        guard map[.date] != nil, map[.amount] != nil || map[.income] != nil || map[.expense] != nil else {
            plan.errors.append((1, "required columns not found: date and amount"))
            return plan
        }
        var work = data
        let base = data.settings.baseCurrency
        var paletteIndex = data.categories.count

        func cell(_ row: [String], _ col: Column) -> String {
            guard let i = map[col], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for (offset, row) in rows.dropFirst().enumerated() {
            let line = offset + 2
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            var dateText = cell(row, .date)
            let timeText = cell(row, .time)
            if !timeText.isEmpty { dateText += " " + timeText }
            guard let date = parseDate(dateText, timeZone: timeZone) else { plan.errors.append((line, "bad date '\(dateText)'")); continue }

            var kind = parseKind(cell(row, .type))
            var currency = cell(row, .currency).uppercased()
            let walletName = cell(row, .wallet)
            var wallet: Wallet? = walletName.isEmpty ? work.defaultWallet : work.walletNamed(walletName)
            if currency.isEmpty { currency = wallet?.currency ?? base }
            if currency.count != 3 { currency = base }

            var amount: Int64?
            if map[.amount] != nil {
                amount = MoneyMath.parseMinor(cell(row, .amount), currency: currency)
            } else {
                let inc = MoneyMath.parseMinor(cell(row, .income), currency: currency) ?? 0
                let exp = MoneyMath.parseMinor(cell(row, .expense), currency: currency) ?? 0
                if inc != 0 { amount = abs(inc); kind = kind ?? .income } else if exp != 0 { amount = abs(exp); kind = kind ?? .expense }
            }
            guard var minor = amount, minor != 0 else { plan.errors.append((line, "bad amount")); continue }
            if kind == nil { kind = minor < 0 ? .expense : .income }
            minor = abs(minor)
            let k = kind!

            if wallet == nil {
                let w = Wallet(name: walletName, currency: currency, colorHex: Defaults.palette[(work.wallets.count * 5) % Defaults.palette.count])
                plan.newWallets.append(w)
                work.wallets.append(w)
                wallet = w
            }

            let isTransfer = TextNorm.normalize(cell(row, .type)).contains("transfer")
            if isTransfer { plan.transfers += 1 }
            var catName = cell(row, .category)
            if catName.isEmpty && isTransfer { catName = "Transfer" }
            if catName.isEmpty { catName = fallbackCategoryName }
            var category = work.categoryNamed(catName, kind: k)
            if category == nil {
                let c = Category(name: catName, kind: k, icon: .symbol("tag.fill"),
                                 colorHex: Defaults.palette[paletteIndex % Defaults.palette.count],
                                 sortOrder: (work.categories.map { $0.sortOrder }.max() ?? 0) + 1)
                paletteIndex += 1
                plan.newCategories.append(c)
                work.categories.append(c)
                category = c
            }

            var note = cell(row, .note)
            let labels = cell(row, .labels)
            if !labels.isEmpty { note += (note.isEmpty ? "" : " ") + labels.split(whereSeparator: { $0 == "," || $0 == ";" }).map { "#" + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
            let tx = Txn(kind: k, amountMinor: minor, currency: currency, categoryID: category!.id, walletID: wallet!.id,
                         date: date, note: note, source: .imported)
            // Skip rows that already exist (re-importing the same file is safe).
            let exists = data.transactions.contains { e in
                e.kind == tx.kind && e.amountMinor == tx.amountMinor && e.currency == tx.currency &&
                abs(e.date.timeIntervalSince(tx.date)) < 60 &&
                TextNorm.normalize(data.category(e.categoryID)?.name ?? "") == TextNorm.normalize(category!.name) &&
                TextNorm.normalize(e.note) == TextNorm.normalize(note)
            }
            if exists { plan.duplicates += 1; continue }
            plan.transactions.append(tx)
        }
        return plan
    }
}
