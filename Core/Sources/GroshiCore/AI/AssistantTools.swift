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
            "date": str("YYYY-MM-DD in the user's local time: the date the user stated for this operation (explicitly or relatively: 'сегодня', 'вчера', 'за 11 ноября', 'в пятницу'). Never assume it: if the user stated no date, do not call the tool, ask for the date first."),
            "time": str("HH:mm, optional."),
            "note": str("Short comment, e.g. the place or purpose. Optional."),
            "labels": ["type": "array", "items": ["type": "string"], "description": "Existing label names to attach (optional)."]
        ],
        "required": ["kind", "amount", "category", "date"],
        "additionalProperties": false
    ]

    static let draftChange: JSON = [
        "type": "object",
        "properties": [
            "number": ["type": "integer", "description": "Item number in the draft (1-based)."],
            "remove": ["type": "boolean", "description": "true to drop this item from the draft."],
            "kind": kind,
            "amount": str("New amount"), "currency": str("ISO code"), "category": str("New category name"),
            "wallet": str("Wallet name"), "date": str("YYYY-MM-DD"), "time": str("HH:mm"), "note": str("New note"),
            "labels": ["type": "array", "items": ["type": "string"], "description": "Replace labels"]
        ],
        "required": ["number"],
        "additionalProperties": false
    ]

    public static let all: [JSON] = [
        fn("add_transactions", "Record income/expense transactions. Put ALL operations from the user's message into ONE call (any number of items, each with its own date). One item is saved at once; several items become a draft the user confirms once. While a draft is pending, new items are appended to it.",
           ["items": ["type": "array", "items": txItem]], required: ["items"]),
        fn("revise_draft", "Correct the pending draft before it is saved: change or remove items by number, or add items. Use when the user corrects recognised data ('не 450, а 500', 'убери такси', 'пиццу в Food').",
           ["changes": ["type": "array", "items": draftChange], "add": ["type": "array", "items": txItem]]),
        fn("confirm_pending", "Save the pending draft / perform the pending action, when the user agrees ('да', 'так', 'сохрани', 'подтверждаю', 'yes').", [:]),
        fn("cancel_pending", "Discard the pending draft / action when the user declines ('нет', 'отмена', 'не надо').", [:]),
        fn("add_transfer", "Move money between two of the user's own wallets (withdraw cash from a card, top up savings, move to another account). A transfer is NOT income or expense.",
           ["from_wallet": str("Source wallet name"), "to_wallet": str("Destination wallet name"),
            "amount": str("Amount taken from the source wallet, plain decimal string"),
            "currency": str("ISO code of amount. Omit for the source wallet currency."),
            "to_amount": str("Amount credited to the destination when its currency differs (e.g. bought USD). Omit to convert at the app's rate."),
            "date": str("YYYY-MM-DD. Omit for today."), "time": str("HH:mm, optional."), "note": str("Optional comment")],
           required: ["from_wallet", "to_wallet", "amount"]),
        fn("find_transactions", "Search transactions (including transfers). Returns short ids usable in update/delete. Use for 'last expense', 'yesterday's purchase', etc.",
           ["kind": ["type": "string", "enum": ["expense", "income", "transfer"]], "category": str("Category name"), "wallet": str("Wallet name (matches either side of a transfer)"),
            "date_from": str("YYYY-MM-DD inclusive"), "date_to": str("YYYY-MM-DD inclusive"),
            "text": str("Substring of the note"), "min_amount": str("Minimum amount"), "max_amount": str("Maximum amount"),
            "sort": ["type": "string", "enum": ["newest", "oldest", "largest"]],
            "limit": ["type": "integer", "description": "1-50, default 10"]]),
        fn("update_transactions", "Change fields of transactions found earlier (by id). Only pass fields to change. For transfers: wallet = source, to_wallet = destination.",
           ["ids": ["type": "array", "items": ["type": "string"]], "kind": kind, "amount": str("New amount"),
            "currency": str("ISO code"), "category": str("New category name"), "wallet": str("New wallet name"),
            "to_wallet": str("Transfers only: new destination wallet"),
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

    public static func systemPrompt(data: AppData, now: Date, calendar cal: Calendar, replyLanguage: String, pending: String? = nil) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = cal.timeZone
        df.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        let exp = data.categories(of: .expense).map { $0.name }.joined(separator: ", ")
        let inc = data.categories(of: .income).map { $0.name }.joined(separator: ", ")
        let wallets = data.activeWallets.map { "\($0.name) (\($0.currency))" }.joined(separator: ", ")
        let labelList = data.sortedLabels.map { $0.name }.joined(separator: ", ")
        let ymd = DateFormatter.ymd(cal)
        let yesterday = cal.date(byAdding: .day, value: -1, to: now).map { ymd.string(from: $0) } ?? ""
        let year = cal.component(.year, from: now)
        let nov3 = cal.date(from: DateComponents(year: year, month: 11, day: 3)) ?? now
        let example = ymd.string(from: nov3 > now ? (cal.date(byAdding: .year, value: -1, to: nov3) ?? nov3) : nov3)
        let pendingBlock =pending.map { "\nPENDING (not saved yet, awaiting the user's answer):\n" + $0 } ?? ""
        return """
        You are the assistant inside a personal finance iPhone app. You operate the app through tools; you are not a general chatbot.
        Now: \(df.string(from: now)) (\(cal.timeZone.identifier)). Week starts on Monday.
        Today = \(ymd.string(from: now)), yesterday = \(yesterday). Current year: \(year). A day and month without a year mean the most recent such date that is not after today (e.g. "3 ноября" → \(example)).
        Base currency: \(data.settings.baseCurrency). Default wallet: \(data.defaultWallet?.name ?? "-").
        Expense categories: \(exp).
        Income categories: \(inc).
        Wallets: \(wallets).
        Labels: \(labelList.isEmpty ? "-" : labelList).

        Rules:
        - The user speaks Russian, Ukrainian or English, mostly by voice (transcripts may contain recognition errors and numbers written as words). Reply in \(replyLanguage) unless the user clearly uses another language. Replies are read aloud: keep them to one or two short sentences, no lists, no markdown, no ids.
        - Moving money between the user's own wallets ("снял наличные с карты", "перевёл на копилку", "поменял доллары") is a transfer: use add_transfer, never add_transactions. Transfers do not count as income or expense.
        - To record money use add_transactions with ALL operations of the message in ONE call, however many there are (5, 10, 30…), each item with its own date. A date said once applies to the operations that follow it until another date is said ("За 11 ноября … За 12 ноября …"). "гривен/грн/гривень/₴" = UAH, "баксов/долларов" = USD; "тысяча/тисяча/тыщу" = 1000, "полторы тысячи" = 1500. With one wallet and no currency named, omit wallet and currency.
        - Dates: words like "сегодня/сьогодні/today", "вчера/вчора/yesterday", "позавчера", "в пятницу", "11 ноября", "за 12-е", "за то же число" ARE stated dates — convert them yourself and record without asking. Ask "За какую дату?" only when the message contains no date at all for some operations (e.g. "Добавь тысячу гривен на игры"); then wait and do not assume today. When the user answers with just the date, record the operations from their previous message with it at once — do not ask them to repeat the command and do not ask again.
        - Categories: choose only from the lists above, matching by meaning across languages (the names may be English while the user speaks Russian or Ukrainian: игры/ігри → Games, бензин/пальне/заправка → Gas, такси/таксі → Taxi, аптека → Pharmacy, одежда/одяг → Clothes, пицца/шаурма/ресторан → the restaurant or cafe category, магазин/продукты/супермаркет → the groceries/food category, зарплата/за работу/за роботу → Salary). Never invent category names in add_transactions. Do not create categories on your own initiative; but when the user asks to create, rename or change a category ("создай категорию…", "переименуй…", "поменяй иконку…"), do it right away with create_category / update_category / delete_category. If two categories fit equally well or none fits, ask instead of guessing.
        - Amount and direction are mandatory: if the amount is missing, or it is unclear whether money came in or went out, ask one short clarifying question. Ask only about what is really missing; record nothing invented.
        - Several items become a draft: after add_transactions returns status "draft", reply with one short sentence like "Распознал 7 операций на сумму …, сохранить?" — the app shows the list itself, do not read it out. The user then confirms or corrects by voice: confirmation → confirm_pending; corrections → revise_draft (by item number); refusal → cancel_pending. Never re-send the whole list to correct it.
        - A single item is saved at once. Confirm it in one sentence in this style: "Расход 1000 UAH, Games, 11 ноября. Добавлено."
        - To change or delete already saved operations, first call find_transactions, then use the returned ids. Never guess ids. "Отмени/верни как было" for the last change → undo_last_action.
        - For questions about spending use summarize; compare periods by calling it per period. State the numbers with the currency.
        - Status "awaiting_user_confirmation" or "possible_duplicate": say briefly what needs confirming ("Похоже на дубль, всё равно добавить?"); the user can answer by voice or with the button. Do not repeat the call.
        - Never ask for or reveal API keys. Only request data you need.
        \(pendingBlock)
        """
    }
}
