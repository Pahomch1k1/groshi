import Foundation

/// Static facts about currencies used by the app.
public enum Currencies {
    /// Number of digits after the decimal point for a currency.
    public static func minorDigits(_ code: String) -> Int {
        switch code.uppercased() {
        case "JPY", "KRW", "VND", "CLP", "ISK": return 0
        default: return 2
        }
    }

    public static func symbol(_ code: String) -> String {
        switch code.uppercased() {
        case "UAH": return "₴"
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "PLN": return "zł"
        case "CZK": return "Kč"
        case "CHF": return "CHF"
        case "JPY": return "¥"
        case "CNY": return "¥"
        case "TRY": return "₺"
        case "GEL": return "₾"
        case "KZT": return "₸"
        case "ILS": return "₪"
        case "AED": return "AED"
        case "CAD": return "C$"
        case "AUD": return "A$"
        case "MDL": return "L"
        case "RON": return "lei"
        case "HUF": return "Ft"
        case "BGN": return "лв"
        case "SEK", "NOK", "DKK": return "kr"
        default: return code.uppercased()
        }
    }

    /// Currencies offered in pickers (most relevant first).
    public static let common: [String] = [
        "UAH", "USD", "EUR", "PLN", "GBP", "CZK", "CHF", "HUF", "RON", "BGN", "MDL",
        "GEL", "TRY", "ILS", "AED", "KZT", "CAD", "AUD", "JPY", "CNY", "SEK", "NOK", "DKK"
    ]

    static func scale(_ code: String) -> Decimal {
        var d: Decimal = 1
        for _ in 0..<minorDigits(code) { d *= 10 }
        return d
    }
}

/// Exact money arithmetic helpers. Amounts are always stored as integer minor units (kopecks, cents).
public enum MoneyMath {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Parses a human amount such as "1 200,50", "1200.5", "15000", "-450" into minor units.
    /// Returns nil for anything that is not a clean number. Rounds half-up to the currency precision.
    public static func parseMinor(_ text: String, currency: String) -> Int64? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "'", with: "")
        // Strip a trailing/leading currency symbol or code.
        for sym in ["₴", "$", "€", "£", "грн.", "грн", "uah", "UAH", "usd", "USD", "eur", "EUR"] {
            if s.hasSuffix(sym) { s = String(s.dropLast(sym.count)) }
            if s.hasPrefix(sym) { s = String(s.dropFirst(sym.count)) }
        }
        guard !s.isEmpty else { return nil }
        let hasComma = s.contains(","), hasDot = s.contains(".")
        if hasComma && hasDot {
            // The last separator is the decimal one; the other is grouping.
            let lastComma = s.lastIndex(of: ",")!, lastDot = s.lastIndex(of: ".")!
            if lastComma > lastDot {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if hasComma {
            // A single comma is the decimal separator (uk/ru convention); several commas are grouping.
            let count = s.filter { $0 == "," }.count
            s = count == 1 ? s.replacingOccurrences(of: ",", with: ".") : s.replacingOccurrences(of: ",", with: "")
        } else if s.filter({ $0 == "." }).count > 1 {
            s = s.replacingOccurrences(of: ".", with: "")
        }
        // Validate: optional sign, digits, optional single dot with digits.
        var seenDot = false, seenDigit = false
        for (i, ch) in s.enumerated() {
            if ch == "-" || ch == "+" { if i != 0 { return nil }; continue }
            if ch == "." { if seenDot { return nil }; seenDot = true; continue }
            if ch.isASCII && ch.isNumber { seenDigit = true; continue }
            return nil
        }
        guard seenDigit, let value = Decimal(string: s, locale: posix) else { return nil }
        return toMinor(value, currency: currency)
    }

    /// Converts a decimal major-unit value to minor units with half-up rounding.
    public static func toMinor(_ value: Decimal, currency: String) -> Int64? {
        var scaled = value * Currencies.scale(currency)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let n = NSDecimalNumber(decimal: rounded)
        // Guard against overflow (more than ~92 quadrillion minor units).
        if rounded > Decimal(Int64.max) || rounded < Decimal(Int64.min) { return nil }
        return n.int64Value
    }

    public static func toDecimal(_ minor: Int64, currency: String) -> Decimal {
        Decimal(minor) / Currencies.scale(currency)
    }

    /// Plain machine string, e.g. "1250.50" (used in CSV and for the AI).
    public static func plainString(_ minor: Int64, currency: String) -> String {
        let digits = Currencies.minorDigits(currency)
        let negative = minor < 0
        let absValue = minor.magnitude
        if digits == 0 { return (negative ? "-" : "") + String(absValue) }
        var div: UInt64 = 1
        for _ in 0..<digits { div *= 10 }
        let major = absValue / div, frac = absValue % div
        var fracStr = String(frac)
        while fracStr.count < digits { fracStr = "0" + fracStr }
        return (negative ? "-" : "") + "\(major).\(fracStr)"
    }

    /// Human string with grouping and symbol, e.g. "₴ 1 250,50" (fraction hidden when zero unless forced).
    public static func format(_ minor: Int64, currency: String, showSign: Bool = false,
                              alwaysShowFraction: Bool = false, symbol: Bool = true) -> String {
        let digits = Currencies.minorDigits(currency)
        let negative = minor < 0
        let absValue = minor.magnitude
        var div: UInt64 = 1
        for _ in 0..<digits { div *= 10 }
        let major = absValue / div, frac = absValue % div
        // Group thousands with a thin no-break space.
        let raw = String(major)
        var grouped = ""
        for (i, ch) in raw.enumerated() {
            if i > 0 && (raw.count - i) % 3 == 0 { grouped.append("\u{202F}") }
            grouped.append(ch)
        }
        var body = grouped
        if digits > 0 && (frac != 0 || alwaysShowFraction) {
            var f = String(frac)
            while f.count < digits { f = "0" + f }
            body += "," + f
        }
        var sign = ""
        if negative { sign = "−" } else if showSign && minor > 0 { sign = "+" }
        guard symbol else { return sign + body }
        let sym = Currencies.symbol(currency)
        if sym.count == 1 { return sign + sym + body }
        return sign + body + " " + sym
    }
}

/// Converts between currencies using rates expressed as "units of base currency for 1 unit of X".
public struct CurrencyConverter: Equatable {
    public var base: String
    public var rates: [String: Decimal]

    public init(base: String, rates: [String: Decimal]) {
        self.base = base.uppercased()
        self.rates = rates
    }

    public func rate(_ code: String) -> Decimal? {
        let c = code.uppercased()
        if c == base { return 1 }
        return rates[c]
    }

    /// Converts minor units. Returns nil when a rate is missing.
    public func convert(_ minor: Int64, from: String, to: String) -> Int64? {
        let f = from.uppercased(), t = to.uppercased()
        if f == t { return minor }
        guard let rf = rate(f), let rt = rate(t), rt != 0 else { return nil }
        let major = MoneyMath.toDecimal(minor, currency: f)
        let inBase = major * rf
        return MoneyMath.toMinor(inBase / rt, currency: t)
    }

    /// Sums amounts in mixed currencies exactly: first per currency (integers), then converts each group once.
    /// Amounts with unknown rates are reported in `missing`.
    public func sum(_ items: [(minor: Int64, currency: String)], into target: String) -> (total: Int64, missing: Set<String>) {
        var perCurrency: [String: Int64] = [:]
        for item in items { perCurrency[item.currency.uppercased(), default: 0] += item.minor }
        var total: Int64 = 0
        var missing = Set<String>()
        for (code, minor) in perCurrency.sorted(by: { $0.key < $1.key }) {
            if let v = convert(minor, from: code, to: target) { total += v } else { missing.insert(code) }
        }
        return (total, missing)
    }
}
