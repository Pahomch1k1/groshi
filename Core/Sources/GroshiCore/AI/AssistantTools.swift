import Foundation

/// OpenAI function-calling tool definitions.
public enum AssistantTools {
    static func fn(_ name: String, _ description: String, _ properties: [String: JSON], required: [String] = []) -> JSON {
        [
            "type": "function",
            "function": [
                "name": .string(name),
                "description": .string(description),
                "parameters": [
                    "type": "object",
                    "properties": .object(properties),
                    "required": .array(required.map { .string($0) }),
                    "additionalProperties": false
                ]
            ]
        ]
    }

    static func str(_ d: String) -> JSON { ["type": "string", "description": .string(d)] }
    static let kind: JSON = ["type": "string", "enum": ["expense", "income"]]

    static let txItem: JSON = [
        "type": "object",
        "properties": [
            "kind": kind,
            "amount": str("Positive amount as a plain decimal string, e.g. \"850\" or \"15000\" or \"12.50\". Convert words like 'тысяч/тис./k' to digits."),
            "currency": str("ISO code (UAH, USD, EUR...). Omit to use the wallet currency."),
            "category": str("Exact name of an existing category of the same kind."),
            "wallet": str("Exact wallet name. Omit for the default wallet."),
            "date": str("YYYY-MM-DD in the user's local time. Omit for today."),
            "time": str("HH:mm, optional."),
            "note": str("Short comment, e.g. the place or purpose. Optional.")
        ],
        "required": ["kind", "amount", "category"],
        "additionalProperties": false
    ]

    public static let all: [JSON] = [
        fn("add_transactions", "Record one or more income/expense transactions. Use one call with several items for several operations.",
           ["items": ["type": "array", "items": txItem]], required: ["items"]),
        fn("find_transactions", "Search transactions. Returns short ids usable in update/delete. Use for 'last expense', 'yesterday's purchase', etc.",
           ["kind": kind, "category": str("Category name"), "wallet": str("Wallet name"),
            "date_from": str("YYYY-MM-DD inclusive"), "date_to": str("YYYY-MM-DD inclusive"),
            "text": str("Substring of the note"), "min_amount": str("Minimum amount"), "max_amount": str("Maximum amount"),
            "sort": ["type": "string", "enum": ["newest", "oldest", "largest"]],
            "limit": ["type": "integer", "description": "1-50, default 10"]]),
        fn("update_transactions", "Change fields of transactions found earlier (by id). Only pass fields to change.",
           ["ids": ["type": "array", "items": ["type": "string"]], "kind": kind, "amount": str("New amount"),
            "currency": str("ISO code"), "category": str("New category name"), "wallet": str("New wallet name"),
            "date": str("YYYY-MM-DD"), "time": str("HH:mm"), "note": str("New note")], required: ["ids"]),
        fn("delete_transactions", "Delete transactions by id.", ["ids": ["type": "array", "items": ["type": "string"]]], required: ["ids"]),
        fn("summarize", "Totals for a date range in the base currency, optionally grouped. Use for questions like 'how much did I spend on X' and for comparisons (call once per period).",
           ["date_from": str("YYYY-MM-DD inclusive"), "date_to": str("YYYY-MM-DD inclusive"), "kind": kind,
            "category": str("Limit to one category"), "wallet": str("Limit to one wallet"),
            "group_by": ["type": "string", "enum": ["none", "category", "wallet", "month", "day"]]],
           required: ["date_from", "date_to"]),
        fn("wallet_balances", "Current balance of every wallet.", [:]),
        fn("create_category", "Create a category.",
           ["name": str("Name"), "kind": kind,
            "icon": str("An SF Symbols name (e.g. 'car.fill', 'cup.and.saucer.fill', 'smoke.fill') or a single emoji."),
            "color": str("Hex color like #FF9F43")], required: ["name", "kind"]),
        fn("update_category", "Rename a category or change its icon/color.",
           ["name": str("Current name"), "kind": kind, "new_name": str("New name"),
            "icon": str("SF Symbols name or a single emoji"), "color": str("Hex color")], required: ["name"]),
        fn("delete_category", "Delete a category. Its transactions move to move_to, or the category is archived if move_to is omitted.",
           ["name": str("Category name"), "kind": kind, "move_to": str("Category that receives its transactions")], required: ["name"]),
        fn("create_wallet", "Create a wallet/account.",
           ["name": str("Name"), "currency": str("ISO code, default base currency"), "initial_balance": str("Starting balance")], required: ["name"]),
        fn("update_wallet", "Rename a wallet or change its starting balance/currency.",
           ["name": str("Current name"), "new_name": str("New name"), "currency": str("ISO code"), "initial_balance": str("Starting balance")], required: ["name"]),
        fn("delete_wallet", "Delete a wallet. Its transactions move to move_to, or the wallet is archived if move_to is omitted.",
           ["name": str("Wallet name"), "move_to": str("Wallet that receives its transactions")], required: ["name"]),
        fn("undo_last_action", "Undo the most recent change made in the app (by the user or by you).", [:])
    ]

    public static func systemPrompt(data: AppData, now: Date, calendar cal: Calendar, replyLanguage: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = cal.timeZone
        df.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        let exp = data.categories(of: .expense).map { $0.name }.joined(separator: ", ")
        let inc = data.categories(of: .income).map { $0.name }.joined(separator: ", ")
        let wallets = data.activeWallets.map { "\($0.name) (\($0.currency))" }.joined(separator: ", ")
        return """
        You are the assistant inside a personal finance iPhone app. You operate the app through tools; you are not a general chatbot.
        Now: \(df.string(from: now)) (\(cal.timeZone.identifier)). Week starts on Monday.
        Base currency: \(data.settings.baseCurrency). Default wallet: \(data.defaultWallet?.name ?? "-").
        Expense categories: \(exp).
        Income categories: \(inc).
        Wallets: \(wallets).

        Rules:
        - The user speaks Russian, Ukrainian or English, often by voice (transcripts may contain errors). Reply briefly in \(replyLanguage) unless the user clearly uses another language.
        - To record money use add_transactions; put all operations from one message into a single call. "гривен/грн/₴" = UAH, "баксов/долларов" = USD.
        - Pick the best matching existing category (e.g. restaurant → cafe/restaurants category, petrol → fuel or car). Never invent category names in add_transactions; if nothing fits, use the "other" category of that kind, or ask.
        - If the amount or the direction (income vs expense) is missing or ambiguous, ask one short clarifying question instead of guessing.
        - Resolve relative dates ("вчера", "в пятницу", "позавчора") to YYYY-MM-DD yourself.
        - To change or delete existing operations, first call find_transactions, then use the returned ids. Never guess ids.
        - For questions about spending use summarize; compare periods by calling it per period. State the numbers with the currency.
        - When a tool returns status "awaiting_user_confirmation", tell the user to confirm with the button shown and do not repeat the call.
        - When a tool returns status "possible_duplicate", tell the user it looks like a duplicate and that they can confirm with the button.
        - After changes, confirm what was done in one short sentence. Do not mention ids.
        - Never ask for or reveal API keys. Only request data you need.
        """
    }
}
