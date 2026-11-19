import Foundation

public struct TxFilter: Hashable {
    public var kind: TxKind? = nil
    public var categoryIDs: Set<UUID> = []
    public var walletIDs: Set<UUID> = []
    public var text: String = ""
    public var minMinor: Int64? = nil // in base currency
    public var maxMinor: Int64? = nil
    public var labels: Set<String> = []
    public init(kind: TxKind? = nil, categoryIDs: Set<UUID> = [], walletIDs: Set<UUID> = [], text: String = "") {
        self.kind = kind; self.categoryIDs = categoryIDs; self.walletIDs = walletIDs; self.text = text
    }
    public var isActive: Bool {
        kind != nil || !categoryIDs.isEmpty || !walletIDs.isEmpty || !text.isEmpty || minMinor != nil || maxMinor != nil || !labels.isEmpty
    }
}

public struct Totals: Hashable {
    public var income: Int64
    public var expense: Int64
    public var net: Int64 { income - expense }
    public var missingRates: Set<String>
}

public struct CategoryShare: Hashable, Identifiable {
    public var id: UUID { categoryID }
    public var categoryID: UUID
    public var amountMinor: Int64 // base currency
    public var count: Int
    /// Share in basis points (1/100 of a percent), exact integer math.
    public var basisPoints: Int
    public var percentText: String {
        let whole = basisPoints / 100, frac = (basisPoints % 100) / 10
        return frac == 0 ? "\(whole)%" : "\(whole),\(frac)%"
    }
}

public struct DayGroup: Hashable, Identifiable {
    public var id: Date { day }
    public var day: Date
    public var items: [Txn]
    public var net: Int64 // base currency
}

public enum Analytics {
    public static func filter(_ data: AppData, period: Period, filter f: TxFilter = TxFilter()) -> [Txn] {
        let conv = data.settings.converter
        let base = data.settings.baseCurrency
        let needle = TextNorm.normalize(f.text)
        return data.transactions.filter { t in
            guard period.contains(t.date) else { return false }
            if let k = f.kind, t.kind != k { return false }
            if !f.categoryIDs.isEmpty && !f.categoryIDs.contains(t.categoryID) { return false }
            if !f.walletIDs.isEmpty && !f.walletIDs.contains(t.walletID) && !(t.toWalletID.map { f.walletIDs.contains($0) } ?? false) { return false }
            if !f.labels.isEmpty && f.labels.isDisjoint(with: t.tags) { return false }
            if !needle.isEmpty {
                let cat = data.category(t.categoryID)?.name ?? ""
                let wal = (data.wallet(t.walletID)?.name ?? "") + " " + (t.toWalletID.flatMap { data.wallet($0)?.name } ?? "")
                let hay = TextNorm.normalize(t.note + " " + t.tags.joined(separator: " ") + " " + cat + " " + wal + " " + MoneyMath.plainString(t.amountMinor, currency: t.currency))
                if !hay.contains(needle) { return false }
            }
            if f.minMinor != nil || f.maxMinor != nil {
                let v = conv.convert(t.amountMinor, from: t.currency, to: base) ?? t.amountMinor
                if let mn = f.minMinor, v < mn { return false }
                if let mx = f.maxMinor, v > mx { return false }
            }
            return true
        }
        .sorted { $0.date == $1.date ? $0.createdAt > $1.createdAt : $0.date > $1.date }
    }

    public static func totals(_ txs: [Txn], data: AppData) -> Totals {
        let conv = data.settings.converter
        let base = data.settings.baseCurrency
        let inc = conv.sum(txs.filter { $0.kind == .income && !$0.isExcluded }.map { ($0.amountMinor, $0.currency) }, into: base)
        let exp = conv.sum(txs.filter { $0.kind == .expense && !$0.isExcluded }.map { ($0.amountMinor, $0.currency) }, into: base)
        return Totals(income: inc.total, expense: exp.total, missingRates: inc.missing.union(exp.missing))
    }

    public static func breakdown(_ txs: [Txn], kind: TxKind, data: AppData) -> [CategoryShare] {
        let conv = data.settings.converter
        let base = data.settings.baseCurrency
        var byCat: [UUID: [Txn]] = [:]
        for t in txs where t.kind == kind && !t.isExcluded { byCat[t.categoryID, default: []].append(t) }
        var shares: [CategoryShare] = byCat.map { (cid, list) in
            let s = conv.sum(list.map { ($0.amountMinor, $0.currency) }, into: base).total
            return CategoryShare(categoryID: cid, amountMinor: s, count: list.count, basisPoints: 0)
        }
        let total = shares.reduce(Int64(0)) { $0 + $1.amountMinor }
        if total > 0 {
            for i in shares.indices {
                // Round half-up to basis points using integer math.
                shares[i].basisPoints = Int((shares[i].amountMinor * 10_000 * 2 + total) / (total * 2))
            }
        }
        return shares.sorted { $0.amountMinor == $1.amountMinor ? $0.count > $1.count : $0.amountMinor > $1.amountMinor }
    }

    public static func dayGroups(_ txs: [Txn], data: AppData, calendar cal: Calendar) -> [DayGroup] {
        let conv = data.settings.converter
        let base = data.settings.baseCurrency
        var groups: [Date: [Txn]] = [:]
        for t in txs { groups[cal.startOfDay(for: t.date), default: []].append(t) }
        return groups.map { (day, items) in
            let sorted = items.sorted { $0.date == $1.date ? $0.createdAt > $1.createdAt : $0.date > $1.date }
            let net = conv.sum(sorted.map { ($0.signedMinor, $0.currency) }, into: base).total
            return DayGroup(day: day, items: sorted, net: net)
        }.sorted { $0.day > $1.day }
    }

    /// Daily (or monthly for long periods) expense/income series for the bar chart.
    public struct Bucket: Hashable, Identifiable {
        public var id: Date { start }
        public var start: Date
        public var income: Int64
        public var expense: Int64
    }

    public static func buckets(_ txs: [Txn], period: Period, data: AppData, calendar cal: Calendar) -> [Bucket] {
        let conv = data.settings.converter
        let base = data.settings.baseCurrency
        let comp: Calendar.Component
        switch period.kind {
        case .day, .week, .month: comp = .day
        case .year: comp = .month
        case .all, .custom:
            let span = (txs.map { $0.date }.max() ?? Date()).timeIntervalSince(txs.map { $0.date }.min() ?? Date())
            comp = span > 86400 * 62 ? .month : .day
        }
        var map: [Date: (inc: [(Int64, String)], exp: [(Int64, String)])] = [:]
        for t in txs {
            if t.isExcluded { continue }
            let key = cal.dateInterval(of: comp, for: t.date)!.start
            var e = map[key] ?? ([], [])
            switch t.kind {
            case .income: e.inc.append((t.amountMinor, t.currency))
            case .expense: e.exp.append((t.amountMinor, t.currency))
            case .transfer: break
            }
            map[key] = e
        }
        // Fill empty buckets for bounded periods so the chart has a stable x-axis.
        if period.kind != .all && period.kind != .custom || (period.kind == .custom && period.end.timeIntervalSince(period.start) < 86400 * 400) {
            if period.kind != .all {
                var d = cal.dateInterval(of: comp, for: period.start)!.start
                while d < period.end {
                    if map[d] == nil { map[d] = ([], []) }
                    d = cal.date(byAdding: comp, value: 1, to: d)!
                }
            }
        }
        return map.map { (k, v) in
            Bucket(start: k,
                   income: conv.sum(v.inc.map { (minor: $0.0, currency: $0.1) }, into: base).total,
                   expense: conv.sum(v.exp.map { (minor: $0.0, currency: $0.1) }, into: base).total)
        }.sorted { $0.start < $1.start }
    }
}
