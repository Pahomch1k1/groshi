import Foundation

/// Amount keypad with + − × ÷, evaluated exactly in Decimal (operator precedence respected).
public enum Calculator {
    public static let operators: Set<Character> = ["+", "−", "×", "÷"]

    /// Appends a key press to the expression text, keeping it well-formed.
    public static func press(_ key: String, to text: String, maxFractionDigits: Int = 2) -> String {
        var s = text
        switch key {
        case "⌫":
            if !s.isEmpty { s.removeLast() }
            return s
        case "+", "−", "×", "÷":
            guard let last = s.last else { return key == "−" ? "" : s }
            if operators.contains(last) { s.removeLast() }
            if s.last == "," { s.removeLast() }
            return s.isEmpty ? s : s + key
        case ",":
            let current = currentNumber(s)
            if current.contains(",") { return s }
            return s + (current.isEmpty ? "0," : ",")
        default: // digit
            let current = currentNumber(s)
            if let comma = current.firstIndex(of: ","), current.distance(from: comma, to: current.endIndex) > maxFractionDigits { return s }
            if current == "0" { s.removeLast(); return s + key }
            if current.filter({ $0.isNumber }).count >= 12 { return s }
            return s + key
        }
    }

    static func currentNumber(_ s: String) -> String {
        var out = ""
        for ch in s.reversed() {
            if operators.contains(ch) { break }
            out.insert(ch, at: out.startIndex)
        }
        return out
    }

    public static func hasOperator(_ s: String) -> Bool { s.contains { operators.contains($0) } }

    /// Evaluates "1 200,5+300×2" → Decimal. Trailing operator is ignored. Division by zero → nil.
    public static func evaluate(_ text: String) -> Decimal? {
        var s = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{202F}", with: "")
        while let last = s.last, operators.contains(last) || last == "," { s.removeLast() }
        guard !s.isEmpty else { return nil }
        var numbers: [Decimal] = []
        var ops: [Character] = []
        var current = ""
        func flush() -> Bool {
            guard let d = Decimal(string: current.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")) else { return false }
            numbers.append(d); current = ""
            return true
        }
        for ch in s {
            if operators.contains(ch) {
                guard flush() else { return nil }
                ops.append(ch)
            } else if ch.isNumber || ch == "," || ch == "." {
                current.append(ch)
            } else { return nil }
        }
        guard flush() else { return nil }
        // × and ÷ first.
        var i = 0
        while i < ops.count {
            if ops[i] == "×" || ops[i] == "÷" {
                let a = numbers[i], b = numbers[i + 1]
                let r: Decimal
                if ops[i] == "×" { r = a * b } else { if b == 0 { return nil }; r = a / b }
                numbers.replaceSubrange(i...i + 1, with: [r])
                ops.remove(at: i)
            } else { i += 1 }
        }
        var result = numbers[0]
        for (k, op) in ops.enumerated() { result = op == "+" ? result + numbers[k + 1] : result - numbers[k + 1] }
        return result
    }

    /// Result in minor units (half-up), or nil for invalid/non-positive results.
    public static func minor(_ text: String, currency: String) -> Int64? {
        guard let d = evaluate(text), let m = MoneyMath.toMinor(d, currency: currency) else { return nil }
        return m
    }
}
