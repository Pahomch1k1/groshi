import Foundation

// MARK: Chat Completions wire types

public struct ChatToolCall: Codable, Hashable {
    public struct Function: Codable, Hashable {
        public var name: String
        public var arguments: String
        public init(name: String, arguments: String) { self.name = name; self.arguments = arguments }
    }
    public var id: String
    public var type: String = "function"
    public var function: Function
    public init(id: String, name: String, arguments: String) {
        self.id = id; self.function = Function(name: name, arguments: arguments)
    }
}

public struct ChatMessage: Codable, Hashable {
    public var role: String
    public var content: String?
    public var tool_calls: [ChatToolCall]?
    public var tool_call_id: String?

    public init(role: String, content: String?, tool_calls: [ChatToolCall]? = nil, tool_call_id: String? = nil) {
        self.role = role; self.content = content; self.tool_calls = tool_calls; self.tool_call_id = tool_call_id
    }
    public static func system(_ s: String) -> ChatMessage { ChatMessage(role: "system", content: s) }
    public static func user(_ s: String) -> ChatMessage { ChatMessage(role: "user", content: s) }
    public static func assistant(_ s: String) -> ChatMessage { ChatMessage(role: "assistant", content: s) }
    public static func tool(_ id: String, _ s: String) -> ChatMessage { ChatMessage(role: "tool", content: s, tool_call_id: id) }
}

public protocol LLMTransport {
    func complete(messages: [ChatMessage], tools: [JSON]) async throws -> ChatMessage
}

// MARK: Engine

/// A change the assistant wants to make that needs an explicit tap from the user.
public struct PendingAction: Identifiable, Hashable {
    public enum Reason: String, Hashable { case massChange, destructive, possibleDuplicate, batch }
    public var id = UUID()
    public var mutation: Mutation
    public var summary: String
    public var reason: Reason
    /// Draft items flagged as possible duplicates of saved operations (indexes into `transactions`).
    public var duplicateIndexes: [Int] = []

    /// Transactions of an add-draft (empty for other actions).
    public var transactions: [Txn] {
        if case .addTransactions(let t) = mutation { return t }
        return []
    }
    public var isDraft: Bool { if case .addTransactions = mutation { return true }; return false }
}

public enum AssistantEvent: Hashable {
    case applied(summary: String)
    /// New operations were saved (single add or a confirmed draft).
    case saved([Txn])
    /// A pending action was created or changed (same id while a draft is being revised).
    case pending(PendingAction)
    /// The pending action with this id was confirmed (true) or discarded (false).
    case resolved(id: UUID, confirmed: Bool)
    case undone(summary: String)

    public var isChange: Bool {
        switch self {
        case .applied, .saved, .undone, .resolved: return true
        case .pending: return true
        }
    }
}

/// Bridge to the app's store (which keeps undo history and persists).
public struct AssistantHost {
    public var data: () -> AppData
    public var apply: (Mutation, String) throws -> Void
    public var undo: () -> String?
    public var isValidSymbol: (String) -> Bool
    public init(data: @escaping () -> AppData, apply: @escaping (Mutation, String) throws -> Void,
                undo: @escaping () -> String?, isValidSymbol: @escaping (String) -> Bool = { _ in true }) {
        self.data = data; self.apply = apply; self.undo = undo; self.isValidSymbol = isValidSymbol
    }
}

public final class AssistantEngine {
    public let transport: LLMTransport
    public let host: AssistantHost
    public var calendar: Calendar
    public var now: () -> Date
    public var replyLanguage: String
    public var maxRounds = 6
    public var massChangeThreshold = 2 // updates/deletes touching this many transactions need confirmation

    /// Conversation history without the system prompt (rebuilt every turn with fresh category lists).
    public private(set) var history: [ChatMessage] = []

    public init(transport: LLMTransport, host: AssistantHost, calendar: Calendar = Period.calendar(),
                now: @escaping () -> Date = Date.init, replyLanguage: String = "Russian") {
        self.transport = transport; self.host = host; self.calendar = calendar; self.now = now; self.replyLanguage = replyLanguage
    }

    /// The action waiting for the user's yes/no (a draft of several operations, a duplicate, a mass change…).
    public private(set) var pending: PendingAction?

    public func reset() { history = []; pending = nil }

    public struct TurnResult {
        public var reply: String
        public var events: [AssistantEvent]
        /// The connection dropped after changes were already made; they are kept and must not be repeated.
        public var interrupted = false
    }

    public func send(_ text: String) async throws -> TurnResult {
        trimHistory()
        let turnStart = history.count
        history.append(.user(text))
        var events: [AssistantEvent] = []
        var executedSignatures = Set<String>()
        for _ in 0..<maxRounds {
            let system = ChatMessage.system(AssistantTools.systemPrompt(data: host.data(), now: now(), calendar: calendar,
                                                                        replyLanguage: replyLanguage, pending: pendingDescription()))
            let msg: ChatMessage
            do {
                msg = try await transport.complete(messages: [system] + history, tools: AssistantTools.all)
            } catch {
                // Never leave a half-finished turn (tool calls without answers) in the history.
                history.removeSubrange(turnStart...)
                guard events.contains(where: { $0.isChange }) else { throw error }
                // Changes were already made: keep them and record that in the history, so a retry
                // of the same command is recognised instead of being executed twice.
                history.append(.user(text))
                history.append(.assistant("[Done before the connection dropped: " + changeLog(events) + ". Do not repeat these changes.]"))
                return TurnResult(reply: "", events: events, interrupted: true)
            }
            history.append(msg)
            guard let calls = msg.tool_calls, !calls.isEmpty else {
                return TurnResult(reply: msg.content ?? "", events: events)
            }
            for call in calls {
                let signature = call.function.name + "|" + call.function.arguments
                let result: JSON
                if executedSignatures.contains(signature) && call.function.name != "find_transactions" && call.function.name != "summarize" {
                    result = ["status": "already_done", "message": "This exact call was already executed in this turn."]
                } else {
                    executedSignatures.insert(signature)
                    let args = JSON.parse(call.function.arguments) ?? [:]
                    result = execute(call.function.name, args, events: &events)
                }
                history.append(.tool(call.id, result.serialized()))
            }
        }
        return TurnResult(reply: "…", events: events)
    }

    /// Keep the last ~24 messages, cutting only at a user message so tool call/result pairs stay intact.
    func trimHistory() {
        guard history.count > 24 else { return }
        var cut = history.count - 24
        while cut < history.count && history[cut].role != "user" { cut += 1 }
        history = Array(history[cut...])
    }

    // MARK: Tool execution

    func error(_ message: String) -> JSON { ["status": "error", "message": .string(message)] }

    public func execute(_ name: String, _ a: JSON, events: inout [AssistantEvent]) -> JSON {
        let data = host.data()
        do {
            switch name {
            case "add_transactions": return try addTransactions(a, data, &events)
            case "confirm_pending":
                guard pending != nil else { return error("nothing is pending") }
                let summary = try applyPending(&events)
                return ["status": "done", "summary": .string(summary)]
            case "cancel_pending":
                guard let p = pending else { return error("nothing is pending") }
                pending = nil
                events.append(.resolved(id: p.id, confirmed: false))
                return ["status": "cancelled"]
            case "add_transfer": return try addTransfer(a, data, &events)
            case "find_transactions": return findTransactions(a, data)
            case "update_transactions": return try updateTransactions(a, data, &events)
            case "delete_transactions":
                let txs = try resolveIDs(a["ids"], data)
                let summary = "Delete \(txs.count) transaction(s): " + txs.prefix(5).map { describe($0, data) }.joined(separator: "; ")
                return commit(.deleteTransactions(txs.map { $0.id }), summary: summary,
                              needsConfirmation: txs.count >= massChangeThreshold ? .massChange : nil, &events)
            case "summarize": return try summarize(a, data)
            case "wallet_balances":
                let items: [JSON] = data.activeWallets.map { w in
                    ["wallet": .string(w.name), "currency": .string(w.currency),
                     "balance": .string(MoneyMath.plainString(data.balance(of: w), currency: w.currency))]
                }
                return ["status": "ok", "wallets": .array(items)]
            case "create_category":
                guard let n = a["name"]?.text else { return error("name required") }
                let kind = TxKind(rawValue: a["kind"]?.text ?? "expense") ?? .expense
                if let existing = data.categoryNamed(n, kind: kind), !existing.isArchived {
                    return error("Category '\(existing.name)' already exists; use it (or move_category to place it)")
                }
                var c = Category(name: n, kind: kind, icon: icon(a["icon"]?.text) ?? .symbol("tag.fill"),
                                 colorHex: color(a["color"]?.text) ?? Defaults.palette[data.categories.count % Defaults.palette.count])
                c.sortOrder = (data.categories.filter { $0.kind == kind }.map { $0.sortOrder }.max() ?? 0) + 1
                var after = data
                try Mutation.upsertCategory(c).apply(to: &after)
                if let target = try placement(a, for: c, in: after) {
                    let order = CategoryOrder.moving(c.id, to: target, kind: kind, in: after)
                    return commit(.batch([.upsertCategory(c), .reorderCategories(kind: kind, order: order)]),
                                  summary: "Created category \(n) at position \(target + 1)", needsConfirmation: nil, &events)
                }
                return commit(.upsertCategory(c), summary: "Created category \(n)", needsConfirmation: nil, &events)
            case "move_category": return try moveCategory(a, data, &events)
            case "update_category":
                guard let n = a["name"]?.text else { return error("name required") }
                let kind = a["kind"]?.text.flatMap(TxKind.init(rawValue:))
                guard var c = data.categoryNamed(n, kind: kind) else { return notFoundCategory(n, data) }
                if let nn = a["new_name"]?.text { c.name = nn }
                if let i = a["icon"]?.text {
                    guard let ic = icon(i) else { return error("Unknown icon '\(i)'. Use another SF Symbols name or an emoji.") }
                    c.icon = ic
                }
                if let col = a["color"]?.text { guard let cc = color(col) else { return error("bad color") }; c.colorHex = cc }
                if c.isArchived { c.isArchived = false }
                return commit(.upsertCategory(c), summary: "Updated category \(c.name)", needsConfirmation: nil, &events)
            case "delete_category":
                guard let n = a["name"]?.text else { return error("name required") }
                let kind = a["kind"]?.text.flatMap(TxKind.init(rawValue:))
                guard let c = data.categoryNamed(n, kind: kind) else { return notFoundCategory(n, data) }
                var target: UUID?
                if let m = a["move_to"]?.text {
                    guard let t = data.categoryNamed(m, kind: c.kind) else { return notFoundCategory(m, data) }
                    target = t.id
                }
                let used = data.transactions.filter { $0.categoryID == c.id }.count
                return commit(.deleteCategory(id: c.id, moveTo: target),
                              summary: "Delete category \(c.name)" + (used > 0 ? " (\(used) transactions " + (target != nil ? "move to \(a["move_to"]!.text!))" : "kept, category archived)") : ""),
                              needsConfirmation: .destructive, &events)
            case "create_wallet":
                guard let n = a["name"]?.text else { return error("name required") }
                let cur = (a["currency"]?.text ?? data.settings.baseCurrency).uppercased()
                let initial = a["initial_balance"]?.text.flatMap { MoneyMath.parseMinor($0, currency: cur) } ?? 0
                let w = Wallet(name: n, currency: cur, colorHex: Defaults.palette[(data.wallets.count * 3 + 6) % Defaults.palette.count], initialBalanceMinor: initial)
                return commit(.upsertWallet(w), summary: "Created wallet \(n) (\(cur))", needsConfirmation: nil, &events)
            case "update_wallet":
                guard let n = a["name"]?.text, var w = data.walletNamed(n) else { return error("wallet not found; wallets: " + data.activeWallets.map { $0.name }.joined(separator: ", ")) }
                if let nn = a["new_name"]?.text { w.name = nn }
                if let c = a["currency"]?.text { w.currency = c.uppercased() }
                if let ib = a["initial_balance"]?.text {
                    guard let v = MoneyMath.parseMinor(ib, currency: w.currency) else { return error("bad initial_balance") }
                    w.initialBalanceMinor = v
                }
                w.isArchived = false
                return commit(.upsertWallet(w), summary: "Updated wallet \(w.name)", needsConfirmation: nil, &events)
            case "delete_wallet":
                guard let n = a["name"]?.text, let w = data.walletNamed(n) else { return error("wallet not found") }
                var target: UUID?
                if let m = a["move_to"]?.text {
                    guard let t = data.walletNamed(m) else { return error("target wallet not found") }
                    target = t.id
                }
                return commit(.deleteWallet(id: w.id, moveTo: target), summary: "Delete wallet \(w.name)", needsConfirmation: .destructive, &events)
            case "undo_last_action":
                if let s = host.undo() {
                    events.append(.undone(summary: s))
                    return ["status": "done", "undone": .string(s)]
                }
                return error("nothing to undo")
            default:
                return error("unknown tool \(name)")
            }
        } catch let e as MutationError {
            return error(e.description)
        } catch let e as ToolError {
            return error(e.message)
        } catch {
            return self.error("\(error)")
        }
    }

    struct ToolError: Error { var message: String }

    func commit(_ m: Mutation, summary: String, needsConfirmation: PendingAction.Reason?, _ events: inout [AssistantEvent]) -> JSON {
        if let reason = needsConfirmation {
            // Validate on a copy first so we never ask the user to confirm something that would fail.
            var copy = host.data()
            do { try m.apply(to: &copy) } catch { return self.error("\(error)") }
            if let old = pending { events.append(.resolved(id: old.id, confirmed: false)) }
            let p = PendingAction(mutation: m, summary: summary, reason: reason)
            pending = p
            events.append(.pending(p))
            return ["status": reason == .possibleDuplicate ? "possible_duplicate" : "awaiting_user_confirmation", "summary": .string(summary)]
        }
        do {
            try host.apply(m, summary)
            events.append(.applied(summary: summary))
            return ["status": "done", "summary": .string(summary)]
        } catch {
            return self.error("\(error)")
        }
    }

    // MARK: Helpers

    func icon(_ s: String?) -> CategoryIcon? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }) && s.count <= 2 {
            return .emoji(s)
        }
        return host.isValidSymbol(s) ? .symbol(s) : nil
    }

    func color(_ s: String?) -> String? {
        guard var h = s?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if !h.hasPrefix("#") { h = "#" + h }
        let hex = h.dropFirst()
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return h.uppercased()
    }

    func notFoundCategory(_ n: String, _ data: AppData) -> JSON {
        error("Category '\(n)' not found. Expense: " + data.categories(of: .expense).map { $0.name }.joined(separator: ", ")
              + ". Income: " + data.categories(of: .income).map { $0.name }.joined(separator: ", "))
    }

    func day(_ s: String?, timeText: String? = nil) -> Date? {
        guard let s = s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = calendar.timeZone; f.calendar = calendar
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: s) else { return nil }
        if let t = timeText {
            let parts = t.split(separator: ":").compactMap { Int($0) }
            if parts.count >= 2 { return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: d) }
        }
        return d
    }

    /// Date for a new transaction: today → now; other days → that day at the given time or 12:00.
    func txDate(_ dateText: String?, _ timeText: String?) throws -> Date {
        let n = now()
        guard let dt = dateText else {
            if let t = timeText, let d = day(DateFormatter.ymd(calendar).string(from: n), timeText: t) { return d }
            return n
        }
        guard let d = day(dt) else { throw ToolError(message: "bad date '\(dt)', use YYYY-MM-DD") }
        if let t = timeText, let withTime = day(dt, timeText: t) { return withTime }
        if calendar.isDate(d, inSameDayAs: n) { return n }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: d) ?? d
    }

    func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    func resolveIDs(_ v: JSON?, _ data: AppData) throws -> [Txn] {
        guard let arr = v?.array, !arr.isEmpty else { throw ToolError(message: "ids required; call find_transactions first") }
        var out: [Txn] = []
        for item in arr {
            guard let s = item.text?.lowercased() else { continue }
            let matches = data.transactions.filter { $0.id.uuidString.lowercased().hasPrefix(s) }
            guard matches.count == 1 else { throw ToolError(message: "unknown id \(s); call find_transactions first") }
            if !out.contains(matches[0]) { out.append(matches[0]) }
        }
        return out
    }

    func describe(_ t: Txn, _ data: AppData) -> String {
        let f = DateFormatter.ymd(calendar)
        let note = t.note.isEmpty ? "" : " (\(t.note))"
        if t.isTransfer {
            let to = t.toWalletID.flatMap { data.wallet($0)?.name } ?? "?"
            var s = "\(f.string(from: t.date)) transfer \(MoneyMath.plainString(t.amountMinor, currency: t.currency)) \(t.currency) \(data.wallet(t.walletID)?.name ?? "?") → \(to)"
            if t.creditedCurrency != t.currency { s += " (+\(MoneyMath.plainString(t.creditedMinor, currency: t.creditedCurrency)) \(t.creditedCurrency))" }
            return s + note
        }
        return "\(f.string(from: t.date)) \(t.kind == .expense ? "-" : "+")\(MoneyMath.plainString(t.amountMinor, currency: t.currency)) \(t.currency) \(data.category(t.categoryID)?.name ?? "?")" + note
    }

    func json(_ t: Txn, _ data: AppData) -> JSON {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
        var o: [String: JSON] = [
            "id": .string(shortID(t.id)), "date": .string(f.string(from: t.date)), "kind": .string(t.kind.rawValue),
            "amount": .string(MoneyMath.plainString(t.amountMinor, currency: t.currency)), "currency": .string(t.currency),
            "wallet": .string(data.wallet(t.walletID)?.name ?? ""), "note": .string(t.note)
        ]
        if t.isTransfer {
            o["to_wallet"] = .string(t.toWalletID.flatMap { data.wallet($0)?.name } ?? "")
            if t.creditedCurrency != t.currency {
                o["to_amount"] = .string(MoneyMath.plainString(t.creditedMinor, currency: t.creditedCurrency))
                o["to_currency"] = .string(t.creditedCurrency)
            }
        } else {
            o["category"] = .string(data.category(t.categoryID)?.name ?? "")
        }
        return .object(o)
    }

    func addTransfer(_ a: JSON, _ data: AppData, _ events: inout [AssistantEvent]) throws -> JSON {
        let names = data.activeWallets.map { $0.name }.joined(separator: ", ")
        guard let fn = a["from_wallet"]?.text, let from = data.walletNamed(fn) else { return error("source wallet not found; wallets: \(names)") }
        guard let tn = a["to_wallet"]?.text, let to = data.walletNamed(tn) else { return error("destination wallet not found; wallets: \(names). Offer to create it with create_wallet.") }
        guard from.id != to.id else { return error("source and destination are the same wallet") }
        let cur = (a["currency"]?.text ?? from.currency).uppercased()
        guard let amountText = a["amount"]?.text, let minor = MoneyMath.parseMinor(amountText, currency: cur), minor != 0 else {
            return error("amount missing or invalid; ask the user")
        }
        var toMinor: Int64? = nil
        if to.currency != cur {
            if let t = a["to_amount"]?.text {
                guard let v = MoneyMath.parseMinor(t, currency: to.currency), v != 0 else { return error("bad to_amount") }
                toMinor = abs(v)
            } else if let v = data.settings.converter.convert(abs(minor), from: cur, to: to.currency) {
                toMinor = v
            } else {
                return error("no exchange rate \(cur)→\(to.currency); ask the user how much arrived (to_amount)")
            }
        }
        let date = try txDate(a["date"]?.text, a["time"]?.text)
        let tx = Txn.transfer(from: from.id, to: to.id, amountMinor: abs(minor), currency: cur, toAmountMinor: toMinor,
                              toCurrency: to.currency, date: date, note: a["note"]?.text ?? "", createdAt: now(), source: .ai)
        let dupes = DuplicateCheck.suspects(for: tx, in: data, calendar: calendar, now: now())
        return commit(.addTransactions([tx]), summary: "Transfer: " + describe(tx, data),
                      needsConfirmation: dupes.isEmpty ? nil : .possibleDuplicate, &events)
    }

    // MARK: Tools

    func notFoundCategoryText(_ n: String, _ data: AppData) -> String {
        "Category '\(n)' not found. Expense: " + data.categories(of: .expense).map { $0.name }.joined(separator: ", ")
            + ". Income: " + data.categories(of: .income).map { $0.name }.joined(separator: ", ")
    }

    /// Parses add_transactions items. Errors name the item, so the model asks about exactly that one.
    func parseItems(_ items: [JSON], _ data: AppData, numberOffset: Int = 0) throws -> [Txn] {
        var txs: [Txn] = []
        for (i, item) in items.enumerated() {
            let n = i + 1 + numberOffset
            guard let kind = item["kind"]?.text.flatMap(TxKind.init(rawValue:)) else { throw ToolError(message: "item \(n): kind must be expense or income") }
            guard let catName = item["category"]?.text else { throw ToolError(message: "item \(n): category required") }
            guard let cat = data.categoryNamed(catName, kind: kind) else { throw ToolError(message: "item \(n): " + notFoundCategoryText(catName, data)) }
            var wallet = data.defaultWallet
            if let wn = item["wallet"]?.text {
                guard let w = data.walletNamed(wn) else { throw ToolError(message: "item \(n): wallet '\(wn)' not found; wallets: " + data.activeWallets.map { $0.name }.joined(separator: ", ")) }
                wallet = w
            }
            guard let w = wallet else { throw ToolError(message: "no wallet exists; create one first") }
            let cur = (item["currency"]?.text ?? w.currency).uppercased()
            guard let amountText = item["amount"]?.text, let minor = MoneyMath.parseMinor(amountText, currency: cur), minor != 0 else {
                throw ToolError(message: "item \(n): amount missing or invalid; ask the user")
            }
            guard let dateText = item["date"]?.text, !dateText.isEmpty else {
                throw ToolError(message: "item \(n): the user did not state the date. Ask the user for which date (do not assume today); nothing was recorded.")
            }
            let date = try txDate(dateText, item["time"]?.text)
            txs.append(Txn(kind: kind, amountMinor: abs(minor), currency: cur, categoryID: cat.id, walletID: w.id,
                           date: date, note: item["note"]?.text ?? "", createdAt: now(), source: .ai,
                           labels: (item["labels"]?.array ?? []).compactMap { $0.text.flatMap { data.labelNamed($0)?.name } }))
        }
        return txs
    }

    /// Operations with all required data are saved at once, however many there are (one undo removes
    /// the whole command). Only a likely duplicate of something just saved waits for a "да".
    func addTransactions(_ a: JSON, _ data: AppData, _ events: inout [AssistantEvent]) throws -> JSON {
        guard let items = a["items"]?.array, !items.isEmpty else { return error("items required") }
        let txs = try parseItems(items, data)
        let dupes = txs.contains { !DuplicateCheck.suspects(for: $0, in: data, calendar: calendar, now: now()).isEmpty }
        if dupes { return try setDraft(txs, data, &events) }
        try host.apply(.addTransactions(txs), txs.count == 1 ? "Added: " + describe(txs[0], data) : "Added \(txs.count)")
        events.append(.saved(txs))
        let base = data.settings.baseCurrency
        let tot = Analytics.totals(txs, data: data)
        return [
            "status": "saved",
            "count": .number(Double(txs.count)),
            "total_expense": .string(MoneyMath.plainString(tot.expense, currency: base) + " " + base),
            "total_income": .string(MoneyMath.plainString(tot.income, currency: base) + " " + base),
            // ids let the model correct a saved operation right away ("пиццу не 450, а 500").
            "items": .array(txs.map { .string(shortID($0.id) + " " + describe($0, data)) }),
            "next": "Already saved and shown on screen; reply with one short sentence, do not ask to confirm."
        ]
    }

    /// Target index (0-based) from position / row+column / after / before, or nil if none was given.
    func placement(_ a: JSON, for c: Category, in data: AppData) throws -> Int? {
        let others = data.categories(of: c.kind).filter { $0.id != c.id }
        if let r = a["row"]?.int, let col = a["column"]?.int {
            guard r >= 1, (1...CategoryOrder.columns).contains(col) else { throw ToolError(message: "row ≥ 1, column 1…\(CategoryOrder.columns)") }
            return CategoryOrder.position(row: r, column: col) - 1
        }
        if let p = a["position"]?.int {
            guard p >= 1 else { throw ToolError(message: "position starts at 1") }
            return p - 1
        }
        if let n = a["after"]?.text {
            guard let t = data.categoryNamed(n, kind: c.kind) else { throw ToolError(message: notFoundCategoryText(n, data)) }
            guard let i = others.firstIndex(where: { $0.id == t.id }) else { return nil }
            return i + 1
        }
        if let n = a["before"]?.text {
            guard let t = data.categoryNamed(n, kind: c.kind) else { throw ToolError(message: notFoundCategoryText(n, data)) }
            return others.firstIndex(where: { $0.id == t.id })
        }
        return nil
    }

    func moveCategory(_ a: JSON, _ data: AppData, _ events: inout [AssistantEvent]) throws -> JSON {
        guard let n = a["name"]?.text else { return error("name required") }
        let kind = a["kind"]?.text.flatMap(TxKind.init(rawValue:))
        guard let c = data.categoryNamed(n, kind: kind ?? .expense) ?? data.categoryNamed(n, kind: kind) else { return notFoundCategory(n, data) }
        let order: [UUID]
        let what: String
        if let s = a["swap_with"]?.text {
            guard let o = data.categoryNamed(s, kind: c.kind) else { return notFoundCategory(s, data) }
            order = CategoryOrder.swapping(c.id, o.id, kind: c.kind, in: data)
            what = "Swapped \(c.name) and \(o.name)"
        } else if let target = try placement(a, for: c, in: data) {
            order = CategoryOrder.moving(c.id, to: target, kind: c.kind, in: data)
            what = "Moved \(c.name) to position \((order.firstIndex(of: c.id) ?? target) + 1)"
        } else {
            return error("give position, row+column, after, before or swap_with")
        }
        let names = order.prefix(12).compactMap { data.category($0)?.name }
        let r = commit(.reorderCategories(kind: c.kind, order: order), summary: what, needsConfirmation: nil, &events)
        guard r["status"] == "done" else { return r }
        return ["status": "done", "summary": .string(what), "first_positions": .array(names.map { .string($0) })]
    }

    func numbered(_ txs: [Txn], _ data: AppData) -> [String] {
        txs.enumerated().map { "\($0.offset + 1). " + describe($0.element, data) }
    }

    /// Stores (or replaces, keeping its id) the pending draft and describes it for the model.
    func setDraft(_ txs: [Txn], _ data: AppData, _ events: inout [AssistantEvent]) throws -> JSON {
        guard !txs.isEmpty else {
            if let p = pending { pending = nil; events.append(.resolved(id: p.id, confirmed: false)) }
            return ["status": "draft_empty", "message": "All items were removed; nothing will be saved."]
        }
        // Validate now, so the user's confirmation cannot fail later.
        var copy = data
        try Mutation.addTransactions(txs).apply(to: &copy)
        let dupIdx = txs.indices.filter { !DuplicateCheck.suspects(for: txs[$0], in: data, calendar: calendar, now: now()).isEmpty }
        var p = PendingAction(mutation: .addTransactions(txs), summary: "Draft: " + numbered(txs, data).joined(separator: "; "),
                              reason: .possibleDuplicate, duplicateIndexes: dupIdx)
        if let old = pending {
            if old.isDraft { p.id = old.id } else { events.append(.resolved(id: old.id, confirmed: false)) }
        }
        pending = p
        events.append(.pending(p))
        let base = data.settings.baseCurrency
        let tot = Analytics.totals(txs, data: data)
        var r: [String: JSON] = [
            "status": "possible_duplicate",
            "count": .number(Double(txs.count)),
            "total_expense": .string(MoneyMath.plainString(tot.expense, currency: base) + " " + base),
            "total_income": .string(MoneyMath.plainString(tot.income, currency: base) + " " + base),
            "items": .array(numbered(txs, data).map { .string($0) }),
            "next": "Nothing saved yet: it looks like a repeat of operations just saved. Ask in one short sentence whether to add them anyway."
        ]
        if !dupIdx.isEmpty { r["possible_duplicates_of_saved"] = .array(dupIdx.map { .number(Double($0 + 1)) }) }
        return .object(r)
    }

    /// Saves the pending draft or performs the pending action. A second call finds nothing pending,
    /// so a double tap or a repeated "да" can never save twice.
    @discardableResult
    func applyPending(_ events: inout [AssistantEvent]) throws -> String {
        guard let p = pending else { return "" }
        let label = p.isDraft ? "Added \(p.transactions.count)" : p.summary
        try host.apply(p.mutation, label)
        pending = nil
        events.append(.resolved(id: p.id, confirmed: true))
        if p.isDraft { events.append(.saved(p.transactions)) } else { events.append(.applied(summary: p.summary)) }
        return p.isDraft ? "saved \(p.transactions.count) operation(s)" : p.summary
    }

    // MARK: Buttons in the app (the conversation learns about them too)

    public func confirmPending() throws -> [AssistantEvent] {
        var ev: [AssistantEvent] = []
        guard pending != nil else { return ev }
        let s = try applyPending(&ev)
        history.append(.assistant("[The user confirmed with the button: \(s).]"))
        return ev
    }

    public func cancelPending() -> [AssistantEvent] {
        guard let p = pending else { return [] }
        pending = nil
        history.append(.assistant("[The user discarded the pending action with the button; nothing was saved.]"))
        return [.resolved(id: p.id, confirmed: false)]
    }

    func pendingDescription() -> String? {
        guard let p = pending else { return nil }
        if p.isDraft {
            return "Draft of \(p.transactions.count) operation(s), numbered:\n" + numbered(p.transactions, host.data()).joined(separator: "\n")
        }
        return "Action needing confirmation (\(p.reason.rawValue)): \(p.summary)"
    }

    func changeLog(_ events: [AssistantEvent]) -> String {
        let data = host.data()
        return events.compactMap { e -> String? in
            switch e {
            case .saved(let t): return "saved \(t.count) operation(s): " + t.map { describe($0, data) }.joined(separator: "; ")
            case .applied(let s): return s
            case .undone(let s): return "undone: " + s
            case .pending(let p): return "created a pending " + (p.isDraft ? "draft of \(p.transactions.count) operation(s)" : "action")
            case .resolved(_, let ok): return ok ? "confirmed the pending action" : "discarded the pending action"
            }
        }.joined(separator: "; ")
    }

    func findTransactions(_ a: JSON, _ data: AppData) -> JSON {
        var list = data.transactions
        if let k = a["kind"]?.text.flatMap(TxKind.init(rawValue:)) { list = list.filter { $0.kind == k } }
        if let c = a["category"]?.text {
            let key = TextNorm.normalize(c)
            let ids = Set(data.categories.filter { TextNorm.normalize($0.name).contains(key) }.map { $0.id })
            list = list.filter { ids.contains($0.categoryID) }
        }
        if let w = a["wallet"]?.text, let wal = data.walletNamed(w) { list = list.filter { $0.involves(wallet: wal.id) } }
        if let from = day(a["date_from"]?.text) { list = list.filter { $0.date >= from } }
        if let to = day(a["date_to"]?.text), let end = calendar.date(byAdding: .day, value: 1, to: to) { list = list.filter { $0.date < end } }
        if let t = a["text"]?.text {
            let key = TextNorm.normalize(t)
            list = list.filter { TextNorm.normalize($0.note).contains(key) }
        }
        let conv = data.settings.converter, base = data.settings.baseCurrency
        func inBase(_ t: Txn) -> Int64 { conv.convert(t.amountMinor, from: t.currency, to: base) ?? t.amountMinor }
        if let mn = a["min_amount"]?.text.flatMap({ MoneyMath.parseMinor($0, currency: base) }) { list = list.filter { inBase($0) >= mn } }
        if let mx = a["max_amount"]?.text.flatMap({ MoneyMath.parseMinor($0, currency: base) }) { list = list.filter { inBase($0) <= mx } }
        switch a["sort"]?.text ?? "newest" {
        case "oldest": list.sort { $0.date < $1.date }
        case "largest": list.sort { inBase($0) > inBase($1) }
        default: list.sort { $0.date == $1.date ? $0.createdAt > $1.createdAt : $0.date > $1.date }
        }
        let limit = max(1, min(50, a["limit"]?.int ?? 10))
        return ["status": "ok", "total_matches": .number(Double(list.count)),
                "items": .array(list.prefix(limit).map { json($0, data) })]
    }

    func updateTransactions(_ a: JSON, _ data: AppData, _ events: inout [AssistantEvent]) throws -> JSON {
        let txs = try resolveIDs(a["ids"], data)
        var ch = TxChanges()
        var parts: [String] = []
        if let k = a["kind"]?.text.flatMap(TxKind.init(rawValue:)) { ch.kind = k; parts.append("type → \(k.rawValue)") }
        let targetKind = ch.kind ?? txs.first?.kind ?? .expense
        if let c = a["currency"]?.text { ch.currency = c.uppercased(); parts.append("currency → \(c.uppercased())") }
        if let am = a["amount"]?.text {
            let cur = ch.currency ?? txs.first?.currency ?? data.settings.baseCurrency
            guard let v = MoneyMath.parseMinor(am, currency: cur), v != 0 else { return error("bad amount") }
            ch.amountMinor = abs(v); parts.append("amount → \(am)")
        }
        if let cn = a["category"]?.text {
            guard let c = data.categoryNamed(cn, kind: targetKind) else { return notFoundCategory(cn, data) }
            ch.categoryID = c.id; parts.append("category → \(c.name)")
        }
        if let wn = a["wallet"]?.text {
            guard let w = data.walletNamed(wn) else { return error("wallet not found") }
            ch.walletID = w.id; parts.append("wallet → \(w.name)")
        }
        if let tn = a["to_wallet"]?.text {
            guard let first = txs.first, first.isTransfer, txs.allSatisfy({ $0.isTransfer }) else { return error("to_wallet applies to transfers only") }
            guard let w = data.walletNamed(tn) else { return error("destination wallet not found") }
            let srcCur = ch.currency ?? first.currency
            var toMinor: Int64? = nil
            if w.currency != srcCur {
                if w.currency == first.creditedCurrency { toMinor = first.creditedMinor }
                else { toMinor = data.settings.converter.convert(ch.amountMinor ?? first.amountMinor, from: srcCur, to: w.currency) }
                guard toMinor != nil else { return error("no exchange rate \(srcCur)→\(w.currency)") }
            }
            ch.transfer = TransferTarget(toWalletID: w.id, toAmountMinor: toMinor, toCurrency: w.currency)
            parts.append("to wallet → \(w.name)")
        }
        if let d = a["date"]?.text {
            guard let dd = day(d, timeText: a["time"]?.text) else { return error("bad date") }
            if a["time"]?.text == nil, let first = txs.first {
                // Keep the original time of day.
                let comps = calendar.dateComponents([.hour, .minute], from: first.date)
                ch.date = calendar.date(bySettingHour: comps.hour ?? 12, minute: comps.minute ?? 0, second: 0, of: dd)
            } else { ch.date = dd }
            parts.append("date → \(d)")
        }
        if let n = a["note"]?.string { ch.note = n; parts.append("note → \(n)") }
        guard !parts.isEmpty else { return error("nothing to change") }
        let summary = "Update \(txs.count): " + txs.prefix(5).map { describe($0, data) }.joined(separator: "; ") + " — " + parts.joined(separator: ", ")
        return commit(.updateTransactions(ids: txs.map { $0.id }, changes: ch), summary: summary,
                      needsConfirmation: txs.count >= massChangeThreshold ? .massChange : nil, &events)
    }

    func summarize(_ a: JSON, _ data: AppData) throws -> JSON {
        guard let from = day(a["date_from"]?.text), let toDay = day(a["date_to"]?.text),
              let to = calendar.date(byAdding: .day, value: 1, to: toDay) else { throw ToolError(message: "date_from/date_to required as YYYY-MM-DD") }
        var f = TxFilter()
        if let k = a["kind"]?.text.flatMap(TxKind.init(rawValue:)) { f.kind = k }
        if let c = a["category"]?.text {
            let key = TextNorm.normalize(c)
            let ids = data.categories.filter { TextNorm.normalize($0.name) == key }.map { $0.id }
            let fuzzy = data.categories.filter { TextNorm.normalize($0.name).contains(key) }.map { $0.id }
            let chosen = ids.isEmpty ? fuzzy : ids
            if chosen.isEmpty { return notFoundCategory(c, data) }
            f.categoryIDs = Set(chosen)
        }
        if let w = a["wallet"]?.text {
            guard let wal = data.walletNamed(w) else { throw ToolError(message: "wallet not found") }
            f.walletIDs = [wal.id]
        }
        let period = Period(kind: .custom, start: from, end: to)
        let txs = Analytics.filter(data, period: period, filter: f)
        let base = data.settings.baseCurrency
        let tot = Analytics.totals(txs, data: data)
        var result: [String: JSON] = [
            "status": "ok", "currency": .string(base), "count": .number(Double(txs.filter { !$0.isTransfer }.count)),
            "total_expense": .string(MoneyMath.plainString(tot.expense, currency: base)),
            "total_income": .string(MoneyMath.plainString(tot.income, currency: base)),
            "net": .string(MoneyMath.plainString(tot.net, currency: base))
        ]
        if !tot.missingRates.isEmpty { result["warning"] = .string("No exchange rate for: " + tot.missingRates.sorted().joined(separator: ", ")) }
        let group = a["group_by"]?.text ?? "none"
        if group != "none" {
            var keyed: [String: [Txn]] = [:]
            let mf = DateFormatter(); mf.locale = Locale(identifier: "en_US_POSIX"); mf.timeZone = calendar.timeZone
            mf.dateFormat = group == "month" ? "yyyy-MM" : "yyyy-MM-dd"
            for t in txs {
                let key: String
                switch group {
                case "category": key = data.category(t.categoryID)?.name ?? "?"
                case "wallet": key = data.wallet(t.walletID)?.name ?? "?"
                default: key = mf.string(from: t.date)
                }
                keyed[key, default: []].append(t)
            }
            struct Row { var key: String; var totals: Totals; var count: Int }
            var rows: [Row] = []
            for (k, list) in keyed { rows.append(Row(key: k, totals: Analytics.totals(list, data: data), count: list.count)) }
            if group == "month" || group == "day" {
                rows.sort { $0.key < $1.key }
            } else {
                rows.sort { ($0.totals.expense + $0.totals.income) > ($1.totals.expense + $1.totals.income) }
            }
            var groups: [JSON] = []
            for r in rows.prefix(40) {
                var o: [String: JSON] = [:]
                o["key"] = .string(r.key)
                o["expense"] = .string(MoneyMath.plainString(r.totals.expense, currency: base))
                o["income"] = .string(MoneyMath.plainString(r.totals.income, currency: base))
                o["count"] = .number(Double(r.count))
                groups.append(.object(o))
            }
            result["groups"] = .array(groups)
        }
        return .object(result)
    }
}

extension DateFormatter {
    static func ymd(_ cal: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone; f.calendar = cal
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
}
