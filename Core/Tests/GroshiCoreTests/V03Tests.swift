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

    func testSevenOperationsOverTwoDaysAreOneDraft() async throws {
        let items = [
            item("expense", "1000", "Развлечения", "2026-11-11"), item("expense", "450", "Кафе и рестораны", "2026-11-11"),
            item("expense", "300", "Продукты", "2026-11-11"), item("expense", "1500", "Бензин", "2026-11-11"),
            item("expense", "200", "Транспорт", "2026-11-11"), item("expense", "800", "Кафе и рестораны", "2026-11-12"),
            item("income", "15000", "Зарплата", "2026-11-12")
        ]
        net.queue = [add(items), .assistant("Распознал 7 операций, сохранить?")]
        let r = try await engine.send("За 11 ноября … За 12 ноября …")
        XCTAssertTrue(t.data.transactions.isEmpty, "a draft is not saved before confirmation")
        guard case .pending(let p) = r.events.last else { return XCTFail("expected a draft") }
        XCTAssertEqual(p.reason, .batch)
        XCTAssertEqual(p.transactions.count, 7)
        XCTAssertEqual(engine.pending?.id, p.id)
        // The pending draft is in the system prompt of the next request.
        net.queue = [net.call("confirm_pending", "{}"), .assistant("Сохранено 7 операций.")]
        let r2 = try await engine.send("Да")
        XCTAssertTrue(net.requests.last!.first!.content!.contains("Draft of 7 operation(s)"))
        XCTAssertEqual(t.data.transactions.count, 7)
        XCTAssertEqual(t.data.transactions.filter { $0.kind == .income }.count, 1)
        XCTAssertEqual(Set(t.data.transactions.map { ymd($0.date) }), ["2026-11-11", "2026-11-12"])
        XCTAssertEqual(t.data.transactions.filter { ymd($0.date) == "2026-11-11" }.count, 5)
        XCTAssertTrue(r2.events.contains(.resolved(id: p.id, confirmed: true)))
        XCTAssertNil(engine.pending)
        // A repeated "да" or a late button tap saves nothing more.
        var ev: [AssistantEvent] = []
        XCTAssertEqual(engine.execute("confirm_pending", [:], events: &ev)["status"], "error")
        XCTAssertTrue(try engine.confirmPending().isEmpty)
        XCTAssertEqual(t.data.transactions.count, 7)
        // One undo removes the whole confirmed batch.
        XCTAssertNotNil(t.host.undo())
        XCTAssertTrue(t.data.transactions.isEmpty)
    }

    func testCorrectionsBeforeSaving() async throws {
        net.queue = [add([item("expense", "450", "Кафе и рестораны", "2026-11-11"), item("expense", "300", "Продукты", "2026-11-11"),
                          item("expense", "200", "Транспорт", "2026-11-11")]), .assistant("Сохранить?")]
        let r = try await engine.send("450 пицца, 300 магазин, 200 такси за 11 ноября")
        guard case .pending(let p) = r.events.last else { return XCTFail() }
        let revise = #"{"changes":[{"number":1,"amount":"500"},{"number":3,"remove":true}],"add":[{"kind":"expense","amount":"90","category":"Связь и интернет","date":"2026-11-12"}]}"#
        net.queue = [net.call("revise_draft", revise), .assistant("Исправил. Сохранить?")]
        let r2 = try await engine.send("Пицца не 450, а 500, такси убери и добавь 90 на связь за 12-е")
        guard case .pending(let p2) = r2.events.last else { return XCTFail() }
        XCTAssertEqual(p2.id, p.id, "the same draft card is updated")
        XCTAssertEqual(p2.transactions.map { $0.amountMinor }, [50_000, 30_000, 9_000])
        XCTAssertTrue(t.data.transactions.isEmpty)
        // A button: drop one more item, then confirm.
        _ = try engine.removeDraftItem(at: 1)
        XCTAssertEqual(engine.pending?.transactions.count, 2)
        let ev = try engine.confirmPending()
        XCTAssertTrue(ev.contains(.resolved(id: p.id, confirmed: true)))
        XCTAssertEqual(t.data.transactions.map { $0.amountMinor }.sorted(), [9_000, 50_000])
        // The model learns about the button.
        XCTAssertTrue(engine.history.last!.content!.contains("confirmed with the button"))
    }

    func testCancelAndAppendToDraft() async throws {
        net.queue = [add([item("expense", "100", "Продукты", "2026-11-19"), item("expense", "200", "Продукты", "2026-11-19")]), .assistant("?")]
        _ = try await engine.send("100 и 200 на продукты вчера")
        net.queue = [add([item("expense", "50", "Транспорт", "2026-11-19")]), .assistant("?")]
        _ = try await engine.send("и ещё 50 на транспорт")
        XCTAssertEqual(engine.pending?.transactions.count, 3, "new items are appended to the open draft")
        XCTAssertTrue(t.data.transactions.isEmpty)
        net.queue = [net.call("cancel_pending", "{}"), .assistant("Отменил.")]
        let r = try await engine.send("Нет, не надо")
        XCTAssertNil(engine.pending)
        XCTAssertTrue(t.data.transactions.isEmpty)
        XCTAssertTrue(r.events.contains { if case .resolved(_, false) = $0 { return true }; return false })
    }

    func testThirtyOperationsInOneCommand() async throws {
        let cats = ["Продукты", "Транспорт", "Кафе и рестораны", "Бензин", "Развлечения", "Одежда"]
        let items = (0..<30).map { i in item("expense", "\(100 + i)", cats[i % cats.count], "2026-11-\(String(format: "%02d", 1 + i % 19))") }
        net.queue = [add(items), .assistant("Распознал 30 операций, сохранить?")]
        _ = try await engine.send("тридцать операций")
        XCTAssertEqual(engine.pending?.transactions.count, 30)
        _ = try engine.confirmPending()
        XCTAssertEqual(t.data.transactions.count, 30)
        XCTAssertEqual(t.data.transactions.reduce(0) { $0 + $1.amountMinor }, (0..<30).reduce(Int64(0)) { $0 + Int64(100 + $1) * 100 })
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
        XCTAssertTrue(p.contains("never create a category unless the user explicitly asks"))
        let names = AssistantTools.all.compactMap { $0["function"]?["name"]?.text }
        XCTAssertTrue(Set(names).isSuperset(of: ["add_transactions", "revise_draft", "confirm_pending", "cancel_pending", "undo_last_action", "create_category"]))
    }

    func testOldAISettingsStillDecode() throws {
        let old = #"{"enabled":true,"model":"gpt-4.1-mini","proxyURL":"","voiceLocale":"uk-UA","autoSendVoice":false}"#
        let s = try JSONDecoder().decode(AISettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.voiceLocale, "uk-UA")
        XCTAssertFalse(s.autoSendVoice)
        XCTAssertTrue(s.speakReplies)
        XCTAssertTrue(s.handsFree)
    }
}
