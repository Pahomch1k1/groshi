import XCTest
@testable import GroshiCore

/// Transport that fails on chosen calls, like a dropped mobile connection.
final class FlakyTransport: LLMTransport {
    var queue: [ChatMessage] = []
    var failOnCall: Set<Int> = []
    var calls = 0
    var requests: [[ChatMessage]] = []
    struct Offline: Error {}
    func complete(messages: [ChatMessage], tools: [JSON]) async throws -> ChatMessage {
        calls += 1
        requests.append(messages)
        if failOnCall.contains(calls) { throw Offline() }
        return queue.isEmpty ? .assistant("ok") : queue.removeFirst()
    }
    func call(_ name: String, _ args: String) -> ChatMessage {
        ChatMessage(role: "assistant", content: nil, tool_calls: [ChatToolCall(id: UUID().uuidString, name: name, arguments: args)])
    }
}

/// 0.3: voice dialog — dates are asked for, several operations become one draft, corrections, confirmation, no duplicates.
final class V03Tests: XCTestCase {
    let cal = Period.calendar(firstWeekday: 2, timeZone: TimeZone(identifier: "Europe/Kyiv")!)
    var now: Date!
    var t: TestHost!
    var net: FlakyTransport!
    var engine: AssistantEngine!

    override func setUp() {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        now = f.date(from: "2026-11-20 10:00")!
        t = TestHost(Defaults.makeInitialData(language: .ru))
        net = FlakyTransport()
        engine = AssistantEngine(transport: net, host: t.host, calendar: cal, now: { [unowned self] in self.now })
    }

    func ymd(_ d: Date) -> String { DateFormatter.ymd(cal).string(from: d) }
    func item(_ kind: String, _ amount: String, _ cat: String, _ date: String?) -> String {
        "{\"kind\":\"\(kind)\",\"amount\":\"\(amount)\",\"category\":\"\(cat)\"" + (date.map { ",\"date\":\"\($0)\"" } ?? "") + "}"
    }
    func add(_ items: [String]) -> ChatMessage { net.call("add_transactions", "{\"items\":[" + items.joined(separator: ",") + "]}") }

    func testMissingDateIsNotAssumed() async throws {
        net.queue = [add([item("expense", "1000", "Развлечения", nil)]), .assistant("За какую дату?")]
        let r = try await engine.send("Добавь тысячу гривен на развлечения")
        XCTAssertTrue(t.data.transactions.isEmpty, "nothing is saved without a stated date")
        XCTAssertTrue(engine.history.contains { $0.role == "tool" && $0.content!.contains("did not state the date") })
        XCTAssertEqual(r.reply, "За какую дату?")
        // The follow-up only names the date; the model completes the earlier command.
        net.queue = [add([item("expense", "1000", "Развлечения", "2026-11-11")]), .assistant("Расход 1000 UAH, Развлечения, 11 ноября. Добавлено.")]
        let r2 = try await engine.send("За 11 ноября")
        XCTAssertEqual(t.data.transactions.count, 1)
        XCTAssertEqual(ymd(t.data.transactions[0].date), "2026-11-11")
        XCTAssertTrue(r2.events.contains { if case .saved(let s) = $0 { return s.count == 1 }; return false })
        // The first request already carried the user's earlier message, so the answer has context.
        XCTAssertTrue(net.requests.last!.contains { $0.role == "user" && $0.content == "Добавь тысячу гривен на развлечения" })
    }

    func testSevenOperationsOverTwoDaysAreSavedAtOnce() async throws {
        let items = [
            item("expense", "1000", "Развлечения", "2026-11-11"), item("expense", "450", "Кафе и рестораны", "2026-11-11"),
            item("expense", "300", "Продукты", "2026-11-11"), item("expense", "1500", "Бензин", "2026-11-11"),
            item("expense", "200", "Транспорт", "2026-11-11"), item("expense", "800", "Кафе и рестораны", "2026-11-12"),
            item("income", "15000", "Зарплата", "2026-11-12")
        ]
        net.queue = [add(items), .assistant("Сохранено 7 операций.")]
        let r = try await engine.send("За 11 ноября … За 12 ноября …")
        XCTAssertEqual(t.data.transactions.count, 7, "saved without a confirmation step")
        XCTAssertNil(engine.pending)
        guard case .saved(let saved) = r.events.last else { return XCTFail("expected saved") }
        XCTAssertEqual(saved.count, 7)
        XCTAssertEqual(t.data.transactions.filter { $0.kind == .income }.count, 1)
        XCTAssertEqual(Set(t.data.transactions.map { ymd($0.date) }), ["2026-11-11", "2026-11-12"])
        XCTAssertEqual(t.data.transactions.filter { ymd($0.date) == "2026-11-11" }.count, 5)
        // The tool result gives ids for corrections and tells the model not to ask.
        let tool = engine.history.first { $0.role == "tool" }!.content!
        XCTAssertTrue(tool.contains("\"saved\"") && tool.contains("do not ask to confirm"))
        // One undo removes the whole command.
        XCTAssertNotNil(t.host.undo())
        XCTAssertTrue(t.data.transactions.isEmpty)
    }

    func testCorrectionRightAfterSavingUsesReturnedIds() async throws {
        net.queue = [add([item("expense", "450", "Кафе и рестораны", "2026-11-11"), item("expense", "200", "Транспорт", "2026-11-11")]),
                     .assistant("Сохранено 2 операции.")]
        _ = try await engine.send("450 пицца и 200 такси за 11 ноября")
        let tool = JSON.parse(engine.history.first { $0.role == "tool" }!.content!)!
        let firstID = String(tool["items"]!.array![0].text!.prefix(8))
        net.queue = [net.call("update_transactions", "{\"ids\":[\"\(firstID)\"],\"amount\":\"500\"}"), .assistant("Исправил.")]
        _ = try await engine.send("Пиццу не 450, а 500")
        XCTAssertEqual(t.data.transactions.map { $0.amountMinor }.sorted(), [20_000, 50_000])
        XCTAssertEqual(t.data.transactions.count, 2, "corrected, not added again")
    }

    func testThirtyOperationsInOneCommand() async throws {
        let cats = ["Продукты", "Транспорт", "Кафе и рестораны", "Бензин", "Развлечения", "Одежда"]
        let items = (0..<30).map { i in item("expense", "\(100 + i)", cats[i % cats.count], "2026-11-\(String(format: "%02d", 1 + i % 19))") }
        net.queue = [add(items), .assistant("Сохранено 30 операций.")]
        _ = try await engine.send("тридцать операций")
        XCTAssertEqual(t.data.transactions.count, 30)
        XCTAssertEqual(t.data.transactions.reduce(0) { $0 + $1.amountMinor }, (0..<30).reduce(Int64(0)) { $0 + Int64(100 + $1) * 100 })
    }

    func testRepeatedCommandWaitsAndCanBeCancelled() async throws {
        let cmd = [item("expense", "100", "Продукты", "2026-11-19"), item("expense", "200", "Транспорт", "2026-11-19")]
        net.queue = [add(cmd), .assistant("Сохранено.")]
        _ = try await engine.send("100 продукты и 200 транспорт вчера")
        net.queue = [add(cmd), .assistant("Похоже на дубль, всё равно добавить?")]
        let r = try await engine.send("100 продукты и 200 транспорт вчера")
        guard case .pending(let p) = r.events.last else { return XCTFail("expected a duplicate question") }
        XCTAssertEqual(p.reason, .possibleDuplicate)
        XCTAssertEqual(t.data.transactions.count, 2)
        net.queue = [net.call("cancel_pending", "{}"), .assistant("Не добавляю.")]
        _ = try await engine.send("Нет")
        XCTAssertNil(engine.pending)
        XCTAssertEqual(t.data.transactions.count, 2)
    }

    // MARK: Category order

    func names(_ kind: TxKind = .expense) -> [String] { t.data.categories(of: kind).map { $0.name } }

    func testMoveCategoryByPositionRowColumnAfterAndSwap() throws {
        var ev: [AssistantEvent] = []
        let start = names()
        XCTAssertEqual(engine.execute("move_category", ["name": "Одежда", "position": 1], events: &ev)["status"], "done")
        XCTAssertEqual(names().first, "Одежда")
        XCTAssertEqual(Array(names().dropFirst()), start.filter { $0 != "Одежда" }, "the others shift")
        // Row 2, place 3 = position 7.
        XCTAssertEqual(engine.execute("move_category", ["name": "Транспорт", "row": 2, "column": 3], events: &ev)["status"], "done")
        XCTAssertEqual(names()[6], "Транспорт")
        XCTAssertEqual(engine.execute("move_category", ["name": "Бензин", "after": "Одежда"], events: &ev)["status"], "done")
        XCTAssertEqual(Array(names().prefix(2)), ["Одежда", "Бензин"])
        let before = names()
        XCTAssertEqual(engine.execute("move_category", ["name": "Одежда", "swap_with": "Продукты"], events: &ev)["status"], "done")
        let i = before.firstIndex(of: "Продукты")!
        XCTAssertEqual(names()[0], "Продукты")
        XCTAssertEqual(names()[i], "Одежда")
        // Income order is separate and untouched.
        let income = names(.income)
        XCTAssertEqual(engine.execute("move_category", ["name": "Зарплата", "kind": "income", "position": 3], events: &ev)["status"], "done")
        XCTAssertEqual(names(.income)[2], "Зарплата")
        XCTAssertEqual(names().prefix(1).first, "Продукты")
        XCTAssertNotEqual(names(.income), income)
        // Each move is one undo step.
        XCTAssertNotNil(t.host.undo())
        XCTAssertEqual(names(.income), income)
    }

    func testCreateCategoryAtTheStartAndOrderSurvivesSaving() throws {
        var ev: [AssistantEvent] = []
        let r = engine.execute("create_category", ["name": "Кальян", "kind": "expense", "icon": "💨", "position": 1], events: &ev)
        XCTAssertEqual(r["status"], "done")
        XCTAssertEqual(names().first, "Кальян")
        XCTAssertEqual(engine.execute("create_category", ["name": "Кальян", "kind": "expense"], events: &ev)["status"], "error", "no duplicate categories")
        // One undo removes the category together with its placement.
        XCTAssertNotNil(t.host.undo())
        XCTAssertNil(t.data.categoryNamed("Кальян"))
        _ = engine.execute("create_category", ["name": "Кальян", "kind": "expense", "position": 2], events: &ev)
        // The order is stored in the data (sortOrder), so it survives encoding and a restart.
        let reloaded = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(t.data))
        XCTAssertEqual(reloaded.categories(of: .expense).map { $0.name }, names())
        XCTAssertEqual(names()[1], "Кальян")
    }

    func testReorderMutationFromDragAndDrop() throws {
        var d = t.data
        let ids = CategoryOrder.ids(d, .expense)
        let moved = CategoryOrder.moving(ids[5], to: 0, kind: .expense, in: d)
        try Mutation.reorderCategories(kind: .expense, order: moved).apply(to: &d)
        XCTAssertEqual(CategoryOrder.ids(d, .expense), moved)
        XCTAssertEqual(CategoryOrder.position(row: 2, column: 3), 7)
    }

    func testDropAfterSavingDoesNotDuplicateOnRetry() async throws {
        // Call 1 → the model adds; call 2 (its final words) fails: the operation stays saved exactly once.
        net.queue = [add([item("expense", "1000", "Развлечения", "2026-11-11")])]
        net.failOnCall = [2]
        let r = try await engine.send("Тысяча на развлечения за 11 ноября")
        XCTAssertTrue(r.interrupted)
        XCTAssertEqual(t.data.transactions.count, 1)
        // History stays well-formed (no tool calls without results) and records what was done.
        XCTAssertFalse(engine.history.contains { $0.role == "tool" || $0.tool_calls != nil })
        XCTAssertTrue(engine.history.last!.content!.contains("Do not repeat"))
        // The retry reaches the model with that note; the model answers without adding again.
        net.queue = [.assistant("Уже добавлено.")]
        _ = try await engine.send("Тысяча на развлечения за 11 ноября")
        XCTAssertTrue(net.requests.last!.contains { $0.content?.contains("Done before the connection dropped") == true })
        XCTAssertEqual(t.data.transactions.count, 1)
    }

    func testDropBeforeAnythingKeepsHistoryClean() async throws {
        net.failOnCall = [1]
        do { _ = try await engine.send("Тысяча на развлечения"); XCTFail("should throw") } catch {}
        XCTAssertTrue(engine.history.isEmpty, "a failed turn leaves nothing behind, so resending is safe")
        XCTAssertTrue(t.data.transactions.isEmpty)
    }

    func testSingleItemIsSavedAtOnceAndDuplicateAsks() async throws {
        net.queue = [add([item("expense", "250", "Транспорт", "2026-11-20")]), .assistant("Добавлено.")]
        _ = try await engine.send("250 на транспорт сегодня")
        XCTAssertEqual(t.data.transactions.count, 1)
        XCTAssertEqual(t.data.transactions[0].date, now, "today keeps the current time")
        net.queue = [add([item("expense", "250", "Транспорт", "2026-11-20")]), .assistant("Похоже на дубль, всё равно добавить?")]
        let r = try await engine.send("250 на транспорт сегодня")
        guard case .pending(let p) = r.events.last else { return XCTFail() }
        XCTAssertEqual(p.reason, .possibleDuplicate)
        XCTAssertEqual(p.duplicateIndexes, [0])
        XCTAssertEqual(t.data.transactions.count, 1)
    }

    func testPromptRules() {
        let p = AssistantTools.systemPrompt(data: t.data, now: now, calendar: cal, replyLanguage: "Russian")
        XCTAssertTrue(p.contains("За какую дату?"))
        XCTAssertTrue(p.contains("Do not create categories on your own initiative"))
        XCTAssertTrue(p.contains("yesterday = 2026-11-19"))
        XCTAssertTrue(p.contains("→ 2026-11-03"))
        let names = AssistantTools.all.compactMap { $0["function"]?["name"]?.text }
        XCTAssertTrue(Set(names).isSuperset(of: ["add_transactions", "move_category", "confirm_pending", "cancel_pending", "undo_last_action", "create_category"]))
    }

    func testOldAISettingsStillDecode() throws {
        let old = #"{"enabled":true,"model":"gpt-4.1-mini","proxyURL":"","voiceLocale":"uk-UA","autoSendVoice":false}"#
        let s = try JSONDecoder().decode(AISettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.voiceLocale, "uk-UA")
        XCTAssertFalse(s.autoSendVoice)
        XCTAssertTrue(s.speakReplies)
        XCTAssertTrue(s.handsFree)
        XCTAssertEqual(s.model, "gpt-4.1", "the old default model is upgraded")
        let chosen = try JSONDecoder().decode(AISettings.self, from: Data(#"{"model":"gpt-4.1-mini","speakReplies":false}"#.utf8))
        XCTAssertEqual(chosen.model, "gpt-4.1-mini", "a model chosen in 0.3 settings is kept")
    }
}
