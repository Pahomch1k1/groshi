import Foundation

public enum TxKind: String, Codable, CaseIterable, Hashable {
    case expense
    case income
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

    public init(id: UUID = UUID(), kind: TxKind, amountMinor: Int64, currency: String, categoryID: UUID,
                walletID: UUID, date: Date, note: String = "", createdAt: Date = Date(), source: TxSource = .manual) {
        self.id = id; self.kind = kind; self.amountMinor = abs(amountMinor); self.currency = currency.uppercased()
        self.categoryID = categoryID; self.walletID = walletID; self.date = date; self.note = note
        self.createdAt = createdAt; self.source = source
    }

    /// Signed amount: income positive, expense negative.
    public var signedMinor: Int64 { kind == .income ? amountMinor : -amountMinor }
}

public enum AppLanguage: String, Codable, CaseIterable {
    case system, uk, ru, en
}

public enum AppTheme: String, Codable, CaseIterable {
    case system, light, dark
}

public struct AISettings: Codable, Hashable {
    public var enabled: Bool = true
    public var model: String = "gpt-4.1-mini"
    /// Optional proxy endpoint (e.g. a Cloudflare Worker that holds the key). Empty = call OpenAI directly with the Keychain key.
    public var proxyURL: String = ""
    /// BCP-47 locale for speech recognition.
    public var voiceLocale: String = "ru-RU"
    /// Automatically send a voice command when recording stops.
    public var autoSendVoice: Bool = true
    public init() {}
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
public struct AppData: Codable, Hashable {
    public static let currentVersion = 1
    public var version: Int = AppData.currentVersion
    public var categories: [Category] = []
    public var wallets: [Wallet] = []
    public var transactions: [Txn] = []
    public var settings = AppSettings()

    public init(categories: [Category] = [], wallets: [Wallet] = [], transactions: [Txn] = [], settings: AppSettings = AppSettings()) {
        self.categories = categories; self.wallets = wallets; self.transactions = transactions; self.settings = settings
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
        let items = transactions.filter { $0.walletID == wallet.id }.map { (minor: $0.signedMinor, currency: $0.currency) }
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
