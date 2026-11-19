import XCTest
@testable import GroshiCore

/// Scripted stand-in for OpenAI: returns queued responses and records requests.
final class MockTransport: LLMTransport {
    var queue: [ChatMessage] = []
    var requests: [[ChatMessage]] = []
    func complete(messages: [ChatMessage], tools: [JSON]) async throws -> ChatMessage {
        requests.append(messages)
        return queue.isEmpty ? .assistant("ok") : queue.removeFirst()
    }
    func call(_ name: String, _ args: String, id: String = UUID().uuidString) -> ChatMessage {
        ChatMessage(role: "assistant", content: nil, tool_calls: [ChatToolCall(id: id, name: name, arguments: args)])
    }
}

/// Minimal store with undo, like the app's.
final class TestHost {
    var data: AppData
    var undoStack: [(String, AppData)] = []
    init(_ d: AppData) { data = d }
    var host: AssistantHost {
        AssistantHost(data: { self.data }, apply: { m, label in
            var copy = self.data
            try m.apply(to: &copy)
            self.undoStack.append((label, self.data))
            self.data = copy
        }, undo: {
            guard let (label, prev) = self.undoStack.popLast() else { return nil }
            self.data = prev
            return label
        })
    }
}

final class AssistantTests: XCTestCase {
    let cal = Period.calendar(firstWeekday: 2, timeZone: TimeZone(identifier: "Europe/Kyiv")!)
    var now: Date!
    var t: TestHost!
    var mock: MockTransport!
    var engine: AssistantEngine!

    override func setUp() {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        now = f.date(from: "2026-11-19 15:30")!
        t = TestHost(Defaults.makeInitialData(language: .ru))
        mock = MockTransport()
        engine = AssistantEngine(transport: mock, host: t.host, calendar: cal, now: { [unowned self] in self.now })
    }

    func testAddSingleAndMultiple() async throws {
        mock.queue = [
            mock.call("add_transactions", #"{"items":[{"kind":"expense","amount":"850","category":"Кафе и рестораны","note":"ресторан"}]}"#),
            .assistant("Записал 850 ₴ в Кафе.")
        ]
        let r = try await engine.send("Сегодня потратил 850 гривен в ресторане")
        XCTAssertEqual(r.reply, "Записал 850 ₴ в Кафе.")
        XCTAssertEqual(t.data.transactions.count, 1)
        XCTAssertEqual(t.data.transactions[0].amountMinor, 85000)
        XCTAssertEqual(t.data.transactions[0].date, now)
        XCTAssertEqual(t.data.transactions[0].source, .ai)
        // System prompt carries categories but no amounts/history.
        let sys = mock.requests[0][0].content!
        XCTAssertTrue(sys.contains("Кафе и рестораны"))
        XCTAssertFalse(sys.contains("850"))

        mock.queue = [
            mock.call("add_transactions", #"{"items":[{"kind":"expense","amount":"1200","category":"Бензин"},{"kind":"expense","amount":"450","category":"Автомобиль","note":"мойка"}]}"#),
            .assistant("Готово")
        ]
        _ = try await engine.send("Запиши 1200 гривен на бензин и 450 на мойку")
        XCTAssertEqual(t.data.transactions.count, 3)

        mock.queue = [
            mock.call("add_transactions", #"{"items":[{"kind":"income","amount":"15000","category":"Бизнес","date":"2026-11-18","note":"управление отелем"}]}"#),
            .assistant("Готово")
        ]
        _ = try await engine.send("Вчера получил 15 тысяч гривен за управление отелем")
        let inc = t.data.transactions.first { $0.kind == .income }!
        XCTAssertEqual(inc.amountMinor, 1_500_000)
        XCTAssertEqual(cal.component(.day, from: inc.date), 18)
        XCTAssertEqual(cal.component(.hour, from: inc.date), 12)
    }

    func testDuplicateNeedsConfirmation() async throws {
        let add = #"{"items":[{"kind":"expense","amount":"850","category":"Кафе и рестораны"}]}"#
        mock.queue = [mock.call("add_transactions", add), .assistant("ok")]
        _ = try await engine.send("850 ресторан")
        mock.queue = [mock.call("add_transactions", add), .assistant("Похоже на дубль")]
        let r = try await engine.send("850 ресторан")
        XCTAssertEqual(t.data.transactions.count, 1)
        guard case .pending(let p) = r.events.first else { return XCTFail("expected pending") }
        XCTAssertEqual(p.reason, .possibleDuplicate)
        // The tool result told the model it is a possible duplicate.
        XCTAssertTrue(engine.history.contains { $0.role == "tool" && $0.content!.contains("possible_duplicate") })
    }

    func testSameCallTwiceInOneTurnIsIgnored() async throws {
        let add = #"{"items":[{"kind":"expense","amount":"99","category":"Продукты"}]}"#
        mock.queue = [mock.call("add_transactions", add), mock.call("add_transactions", add), .assistant("ok")]
        _ = try await engine.send("99 продукты")
        XCTAssertEqual(t.data.transactions.count, 1)
    }

    func testFindDeleteUndo() async throws {
        mock.queue = [mock.call("add_transactions", #"{"items":[{"kind":"expense","amount":"100","category":"Продукты"},{"kind":"expense","amount":"200","category":"Одежда"}]}"#), .assistant("ok")]
        _ = try await engine.send("add")
        // Find the last expense and delete it.
        var events: [AssistantEvent] = []
        let found = engine.execute("find_transactions", JSON.parse(#"{"kind":"expense","limit":1}"#)!, events: &events)
        let id = found["items"]!.array![0]["id"]!.string!
        let del = engine.execute("delete_transactions", .object(["ids": .array([.string(id)])]), events: &events)
        XCTAssertEqual(del["status"], "done")
        XCTAssertEqual(t.data.transactions.count, 1)
        let undo = engine.execute("undo_last_action", [:], events: &events)
        XCTAssertEqual(undo["status"], "done")
        XCTAssertEqual(t.data.transactions.count, 2)
    }

    func testMassDeleteNeedsConfirmation() async throws {
        mock.queue = [mock.call("add_transactions", #"{"items":[{"kind":"expense","amount":"100","category":"Продукты"},{"kind":"expense","amount":"200","category":"Одежда"}]}"#), .assistant("ok")]
        _ = try await engine.send("add")
        var events: [AssistantEvent] = []
        let ids = t.data.transactions.map { JSON.string(String($0.id.uuidString.prefix(8))) }
        let r = engine.execute("delete_transactions", .object(["ids": .array(ids)]), events: &events)
        XCTAssertEqual(r["status"], "awaiting_user_confirmation")
        XCTAssertEqual(t.data.transactions.count, 2)
        guard case .pending(let p) = events.last else { return XCTFail() }
        try t.host.apply(p.mutation, p.summary) // user taps Confirm
        XCTAssertEqual(t.data.transactions.count, 0)
    }

    func testMoveToOtherCategoryAndSummaries() async throws {
        var events: [AssistantEvent] = []
        _ = engine.execute("add_transactions", JSON.parse(#"{"items":[{"kind":"expense","amount":"1500","category":"Покупки","date":"2026-11-18","note":"куртка"},{"kind":"expense","amount":"500","category":"Одежда","date":"2026-10-10"},{"kind":"expense","amount":"700","category":"Одежда","date":"2026-11-02"}]}"#)!, events: &events)
        let found = engine.execute("find_transactions", JSON.parse(#"{"date_from":"2026-11-18","date_to":"2026-11-18"}"#)!, events: &events)
        let id = found["items"]!.array![0]["id"]!.string!
        let upd = engine.execute("update_transactions", .object(["ids": .array([.string(id)]), "category": "Одежда"]), events: &events)
        XCTAssertEqual(upd["status"], "done")
        let nov = engine.execute("summarize", JSON.parse(#"{"date_from":"2026-11-01","date_to":"2026-11-30","category":"Одежда"}"#)!, events: &events)
        XCTAssertEqual(nov["total_expense"], "2200.00")
        let oct = engine.execute("summarize", JSON.parse(#"{"date_from":"2026-10-01","date_to":"2026-10-31","group_by":"category"}"#)!, events: &events)
        XCTAssertEqual(oct["total_expense"], "500.00")
        XCTAssertEqual(oct["groups"]!.array!.count, 1)
    }

    func testCategoryTools() async throws {
        var events: [AssistantEvent] = []
        XCTAssertEqual(engine.execute("create_category", JSON.parse(#"{"name":"Кальян","kind":"expense","icon":"💨"}"#)!, events: &events)["status"], "done")
        XCTAssertEqual(t.data.categoryNamed("Кальян")?.icon, .emoji("💨"))
        XCTAssertEqual(engine.execute("update_category", JSON.parse(#"{"name":"Автомобиль","icon":"car.side.fill"}"#)!, events: &events)["status"], "done")
        XCTAssertEqual(t.data.categoryNamed("Автомобиль")?.icon, .symbol("car.side.fill"))
        let del = engine.execute("delete_category", JSON.parse(#"{"name":"Кальян"}"#)!, events: &events)
        XCTAssertEqual(del["status"], "awaiting_user_confirmation")
        XCTAssertNotNil(t.data.categoryNamed("Кальян"))
        let unknown = engine.execute("add_transactions", JSON.parse(#"{"items":[{"kind":"expense","amount":"1","category":"Несуществующая"}]}"#)!, events: &events)
        XCTAssertEqual(unknown["status"], "error")
        XCTAssertEqual(engine.execute("create_wallet", JSON.parse(#"{"name":"Доллары","currency":"usd","initial_balance":"300"}"#)!, events: &events)["status"], "done")
        XCTAssertEqual(t.data.walletNamed("Доллары")?.initialBalanceMinor, 30000)
    }

    func testMissingAmountIsError() {
        var events: [AssistantEvent] = []
        let r = engine.execute("add_transactions", JSON.parse(#"{"items":[{"kind":"expense","amount":"","category":"Продукты"}]}"#)!, events: &events)
        XCTAssertEqual(r["status"], "error")
        XCTAssertTrue(t.data.transactions.isEmpty)
    }
}
