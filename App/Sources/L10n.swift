import Foundation
import GroshiCore

/// In-app language switching. Strings are keyed by their Russian text; Ukrainian and English come from `Translations`.
enum Lang {
    static var current: AppLanguage = .system

    static var deviceLanguage: AppLanguage {
        let code = Locale.preferredLanguages.first?.prefix(2) ?? "ru"
        switch code {
        case "uk": return .uk
        case "en": return .en
        default: return .ru
        }
    }

    static var effective: AppLanguage { current == .system ? deviceLanguage : current }

    static var locale: Locale {
        switch effective {
        case .uk: return Locale(identifier: "uk_UA")
        case .en: return Locale(identifier: "en_US")
        default: return Locale(identifier: "ru_RU")
        }
    }

    /// Name of the reply language for the AI system prompt.
    static var aiReplyLanguage: String {
        switch effective {
        case .uk: return "Ukrainian"
        case .en: return "English"
        default: return "Russian"
        }
    }

    static func name(_ l: AppLanguage) -> String {
        switch l {
        case .system: return L("Как в системе")
        case .uk: return "Українська"
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}

func L(_ ru: String) -> String {
    switch Lang.effective {
    case .uk: return Translations.table[ru]?.0 ?? ru
    case .en: return Translations.table[ru]?.1 ?? ru
    default: return ru
    }
}
