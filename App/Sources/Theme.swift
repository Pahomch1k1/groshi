import SwiftUI
import UIKit
import GroshiCore

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b: Double
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
        } else { r = 0.5; g = 0.5; b = 0.5 }
        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
    }
}

enum Palette {
    static let accent = Color(hex: "#1EC28B")
    static let income = Color(hex: "#1EC28B")
    static let expense = Color(hex: "#F0645F")
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let bubble = Color(uiColor: .tertiarySystemFill)
    static func amount(_ kind: TxKind) -> Color { kind == .income ? income : .primary }
}

enum Haptics {
    static func tap(enabled: Bool = true) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func select(enabled: Bool = true) {
        guard enabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func success(enabled: Bool = true) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func error(enabled: Bool = true) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

/// Card container used across screens.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Scale-down press effect for buttons.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension AppTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: Formatting helpers

enum Fmt {
    static func money(_ minor: Int64, _ currency: String, sign: Bool = false) -> String {
        MoneyMath.format(minor, currency: currency, showSign: sign)
    }

    static func signed(_ t: Txn) -> String {
        MoneyMath.format(t.signedMinor, currency: t.currency, showSign: true)
    }

    static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return L("Сегодня") }
        if calendar.isDateInYesterday(day) { return L("Вчера") }
        let f = DateFormatter()
        f.locale = Lang.locale
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: Date())
        f.setLocalizedDateFormatFromTemplate(sameYear ? "EEEE d MMMM" : "d MMMM yyyy")
        return f.string(from: day).capitalizedFirst
    }

    static func periodTitle(_ p: Period, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Lang.locale
        switch p.kind {
        case .day:
            return dayTitle(p.start, calendar: calendar)
        case .week:
            f.setLocalizedDateFormatFromTemplate("d MMM")
            let end = calendar.date(byAdding: .day, value: -1, to: p.end)!
            return "\(f.string(from: p.start)) – \(f.string(from: end))"
        case .month:
            f.setLocalizedDateFormatFromTemplate("LLLL yyyy")
            return f.string(from: p.start).capitalizedFirst
        case .year:
            f.setLocalizedDateFormatFromTemplate("yyyy")
            return f.string(from: p.start)
        case .all:
            return L("Всё время")
        case .custom:
            f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
            let end = calendar.date(byAdding: .day, value: -1, to: p.end)!
            return "\(f.string(from: p.start)) – \(f.string(from: end))"
        }
    }

    static func shortPeriodLabel(_ p: Period, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Lang.locale
        switch p.kind {
        case .week: f.setLocalizedDateFormatFromTemplate("d.MM")
        case .month: f.setLocalizedDateFormatFromTemplate("LLL")
        case .year: f.setLocalizedDateFormatFromTemplate("yyyy")
        default: f.setLocalizedDateFormatFromTemplate("d MMM")
        }
        return f.string(from: p.start).capitalizedFirst
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Lang.locale; f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: d)
    }

    static func fullDate(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Lang.locale; f.dateStyle = .long; f.timeStyle = .short
        return f.string(from: d)
    }

    static func kindName(_ k: PeriodKind) -> String {
        switch k {
        case .day: return L("День")
        case .week: return L("Неделя")
        case .month: return L("Месяц")
        case .year: return L("Год")
        case .all: return L("Всё время")
        case .custom: return L("Свой период")
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
