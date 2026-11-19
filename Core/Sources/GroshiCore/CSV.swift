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
