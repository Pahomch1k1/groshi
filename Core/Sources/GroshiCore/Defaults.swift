import Foundation

public enum Defaults {
    public static let palette: [String] = [
        "#FF6B6B", "#FF9F43", "#FECA57", "#1DD1A1", "#10AC84", "#48DBFB", "#2E86DE",
        "#5F27CD", "#A55EEA", "#FF6FB5", "#EE5253", "#576574", "#00B894", "#E17055",
        "#6C5CE7", "#0984E3", "#FD79A8", "#B8860B", "#2D3436", "#8395A7"
    ]

    struct Seed { let key: String; let uk: String; let ru: String; let en: String; let symbol: String; let color: String }

    static let expenseSeeds: [Seed] = [
        Seed(key: "food", uk: "Продукти", ru: "Продукты", en: "Groceries", symbol: "cart.fill", color: "#1DD1A1"),
        Seed(key: "cafe", uk: "Кафе і ресторани", ru: "Кафе и рестораны", en: "Restaurants", symbol: "fork.knife", color: "#FF9F43"),
        Seed(key: "transport", uk: "Транспорт", ru: "Транспорт", en: "Transport", symbol: "bus.fill", color: "#48DBFB"),
        Seed(key: "car", uk: "Автомобіль", ru: "Автомобиль", en: "Car", symbol: "car.fill", color: "#2E86DE"),
        Seed(key: "fuel", uk: "Пальне", ru: "Бензин", en: "Fuel", symbol: "fuelpump.fill", color: "#576574"),
        Seed(key: "home", uk: "Житло", ru: "Жильё", en: "Housing", symbol: "house.fill", color: "#E17055"),
        Seed(key: "utilities", uk: "Комунальні", ru: "Коммунальные", en: "Utilities", symbol: "bolt.fill", color: "#FECA57"),
        Seed(key: "phone", uk: "Зв'язок та інтернет", ru: "Связь и интернет", en: "Phone & Internet", symbol: "wifi", color: "#0984E3"),
        Seed(key: "shopping", uk: "Покупки", ru: "Покупки", en: "Shopping", symbol: "bag.fill", color: "#FF6FB5"),
        Seed(key: "clothes", uk: "Одяг", ru: "Одежда", en: "Clothes", symbol: "tshirt.fill", color: "#A55EEA"),
        Seed(key: "health", uk: "Здоров'я", ru: "Здоровье", en: "Health", symbol: "cross.case.fill", color: "#EE5253"),
        Seed(key: "beauty", uk: "Краса", ru: "Красота", en: "Beauty", symbol: "sparkles", color: "#FD79A8"),
        Seed(key: "fun", uk: "Розваги", ru: "Развлечения", en: "Entertainment", symbol: "gamecontroller.fill", color: "#6C5CE7"),
        Seed(key: "subs", uk: "Підписки", ru: "Подписки", en: "Subscriptions", symbol: "repeat", color: "#5F27CD"),
        Seed(key: "travel", uk: "Подорожі", ru: "Путешествия", en: "Travel", symbol: "airplane", color: "#00B894"),
        Seed(key: "edu", uk: "Освіта", ru: "Образование", en: "Education", symbol: "book.fill", color: "#10AC84"),
        Seed(key: "gifts", uk: "Подарунки", ru: "Подарки", en: "Gifts", symbol: "gift.fill", color: "#FF6B6B"),
        Seed(key: "pets", uk: "Тварини", ru: "Животные", en: "Pets", symbol: "pawprint.fill", color: "#B8860B"),
        Seed(key: "other", uk: "Інше", ru: "Другое", en: "Other", symbol: "ellipsis.circle.fill", color: "#8395A7")
    ]

    static let incomeSeeds: [Seed] = [
        Seed(key: "salary", uk: "Зарплата", ru: "Зарплата", en: "Salary", symbol: "banknote.fill", color: "#10AC84"),
        Seed(key: "business", uk: "Бізнес", ru: "Бизнес", en: "Business", symbol: "briefcase.fill", color: "#2E86DE"),
        Seed(key: "freelance", uk: "Підробіток", ru: "Подработка", en: "Side job", symbol: "hammer.fill", color: "#FF9F43"),
        Seed(key: "gifts_in", uk: "Подарунки", ru: "Подарки", en: "Gifts", symbol: "gift.fill", color: "#FF6B6B"),
        Seed(key: "interest", uk: "Відсотки", ru: "Проценты", en: "Interest", symbol: "percent", color: "#5F27CD"),
        Seed(key: "other_in", uk: "Інше", ru: "Другое", en: "Other", symbol: "ellipsis.circle.fill", color: "#8395A7")
    ]

    static func name(_ seed: Seed, _ lang: AppLanguage) -> String {
        switch lang {
        case .uk: return seed.uk
        case .en: return seed.en
        case .ru, .system: return seed.ru
        }
    }

    /// Fresh data for the first launch.
    public static func makeInitialData(language: AppLanguage, baseCurrency: String = "UAH") -> AppData {
        var data = AppData()
        data.settings.baseCurrency = baseCurrency
        data.settings.language = .system
        for (i, s) in expenseSeeds.enumerated() {
            data.categories.append(Category(name: name(s, language), kind: .expense, icon: .symbol(s.symbol), colorHex: s.color, sortOrder: i))
        }
        for (i, s) in incomeSeeds.enumerated() {
            data.categories.append(Category(name: name(s, language), kind: .income, icon: .symbol(s.symbol), colorHex: s.color, sortOrder: i))
        }
        let cash = Wallet(name: language == .en ? "Cash" : (language == .uk ? "Готівка" : "Наличные"),
                          currency: baseCurrency, colorHex: "#10AC84", symbol: "banknote.fill", sortOrder: 0)
        let card = Wallet(name: language == .en ? "Card" : (language == .uk ? "Картка" : "Карта"),
                          currency: baseCurrency, colorHex: "#2E86DE", symbol: "creditcard.fill", sortOrder: 1)
        data.wallets = [card, cash]
        data.settings.defaultWalletID = card.id
        return data
    }
}
