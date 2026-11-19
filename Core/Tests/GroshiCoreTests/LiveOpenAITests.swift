import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GroshiCore

/// Real OpenAI transport for tests (Linux-compatible). The key comes from the environment only.
final class LiveTransport: LLMTransport {
    let key: String
    let model: String
    var calls = 0
    var promptTokens = 0
    var completionTokens = 0

    init(key: String, model: String) { self.key = key; self.model = model }

    struct Body: Encodable { var model: String; var messages: [ChatMessage]; var tools: [JSON]?; var tool_choice: String? }
    struct Usage: Decodable { var prompt_tokens: Int; var completion_tokens: Int }
    struct Response: Decodable { struct Choice: Decodable { var message: ChatMessage }; var choices: [Choice]; var usage: Usage? }

    func complete(messages: [ChatMessage], tools: [JSON]) async throws -> ChatMessage {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!, timeoutInterval: 90)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(Body(model: model, messages: messages, tools: tools.isEmpty ? nil : tools,
                                                     tool_choice: tools.isEmpty ? nil : "auto"))
        let (data, code): (Data, Int) = try await withCheckedThrowingContinuation { c in
            URLSession.shared.dataTask(with: req) { d, r, e in
                if let e { c.resume(throwing: e); return }
                c.resume(returning: (d ?? Data(), (r as? HTTPURLResponse)?.statusCode ?? 0))
            }.resume()
        }
        guard code == 200 else { throw NSError(domain: "openai", code: code, userInfo: [NSLocalizedDescriptionKey: String(decoding: data.prefix(300), as: UTF8.self)]) }
        let resp = try JSONDecoder().decode(Response.self, from: data)
        calls += 1
        promptTokens += resp.usage?.prompt_tokens ?? 0
        completionTokens += resp.usage?.completion_tokens ?? 0
        return resp.choices[0].message
    }
}

/// End-to-end scenarios against the real OpenAI API. Skipped unless OPENAI_API_KEY is set.
final class LiveOpenAITests: XCTestCase {
    func testRealAssistantScenarios() async throws {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
            throw XCTSkip("OPENAI_API_KEY not set")
        }
        let model = ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? "gpt-4.1-mini"
        let cal = Period.calendar(firstWeekday: 2, timeZone: TimeZone(identifier: "Europe/Kyiv")!)
        let host = TestHost(Defaults.makeInitialData(language: .ru))
        let transport = LiveTransport(key: key, model: model)
        let engine = AssistantEngine(transport: transport, host: host.host, calendar: cal)
        let monthStart = Period.containing(Date(), kind: .month, calendar: cal).start
        var log: [String] = []

        func say(_ text: String) async throws -> AssistantEngine.TurnResult {
            let r = try await engine.send(text)
            log.append("👤 \(text)\n🤖 \(r.reply)\n   events: \(r.events.map { "\($0)" }.joined(separator: " | "))")
            return r
        }
        func expenses() -> [Txn] { host.data.transactions.filter { $0.kind == .expense } }
        func cat(_ t: Txn) -> String { host.data.category(t.categoryID)?.name ?? "?" }
        defer {
            print("\n===== LIVE OPENAI TRANSCRIPT (\(model)) =====\n" + log.joined(separator: "\n\n"))
            print("===== calls: \(transport.calls), prompt tokens: \(transport.promptTokens), completion tokens: \(transport.completionTokens) =====")
        }

        // 1. Several operations in one command.
        _ = try await say("Запиши 1200 гривен на бензин и 450 на мойку")
        XCTAssertEqual(expenses().count, 2, "two expenses expected")
        XCTAssertEqual(Set(expenses().map { $0.amountMinor }), [120_000, 45_000])
        XCTAssertEqual(expenses().first { $0.amountMinor == 120_000 }.map(cat), "Бензин")

        // 2. Single expense with category inference.
        _ = try await say("Сегодня потратил 850 гривен в ресторане")
        XCTAssertEqual(expenses().first { $0.amountMinor == 85_000 }.map(cat), "Кафе и рестораны")

        // 3. Income with relative date and "тысяч".
        _ = try await say("Вчера получил 15 тысяч гривен за управление отелем")
        let inc = host.data.transactions.first { $0.kind == .income }
        XCTAssertEqual(inc?.amountMinor, 1_500_000)
        if let d = inc?.date { XCTAssertTrue(cal.isDateInYesterday(d), "income should be dated yesterday") }

        // 4. Edit an existing operation.
        _ = try await say("Исправь сумму мойки на 500 гривен")
        XCTAssertNotNil(expenses().first { $0.amountMinor == 50_000 }, "car wash should become 500")
        XCTAssertNil(expenses().first { $0.amountMinor == 45_000 })

        // 5. Move to another category.
        _ = try await say("Перенеси расход 850 из ресторанов в категорию Развлечения")
        XCTAssertEqual(expenses().first { $0.amountMinor == 85_000 }.map(cat), "Развлечения")

        // 6. Category management.
        _ = try await say("Создай категорию расходов Кальян с эмодзи 💨")
        XCTAssertNotNil(host.data.categoryNamed("Кальян", kind: .expense))
        _ = try await say("Поменяй иконку категории Автомобиль на эмодзи 🚗")
        XCTAssertEqual(host.data.categoryNamed("Автомобиль")?.icon, .emoji("🚗"))

        // 7. Transfer between own wallets: no effect on income/expense.
        let before = Analytics.totals(host.data.transactions, data: host.data)
        _ = try await say("Снял с карты 2000 наличными")
        let tr = host.data.transactions.first { $0.isTransfer }
        XCTAssertNotNil(tr, "should be recorded as a transfer")
        XCTAssertEqual(tr?.amountMinor, 200_000)
        XCTAssertEqual(tr.flatMap { host.data.wallet($0.walletID)?.name }, "Карта")
        XCTAssertEqual(tr?.toWalletID.flatMap { host.data.wallet($0)?.name }, "Наличные")
        XCTAssertEqual(Analytics.totals(host.data.transactions, data: host.data), before)

        // 8. Analytics question: expenses this month = 1200 + 500 + 850 = 2550 (yesterday's income may be last month).
        let monthExpense = Analytics.totals(Analytics.filter(host.data, period: Period(kind: .custom, start: monthStart, end: .distantFuture)), data: host.data).expense
        let r8 = try await say("Сколько я потратил в этом месяце?")
        let plain = r8.reply.replacingOccurrences(of: "\u{202F}", with: "").replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: " ", with: "")
        let expected = MoneyMath.plainString(monthExpense, currency: "UAH").replacingOccurrences(of: ".00", with: "")
        XCTAssertTrue(plain.contains(expected), "reply should mention \(expected)")

        // 9. Delete the last expense (single → applied directly, undoable).
        let countBefore = expenses().count
        _ = try await say("Удали последний расход")
        XCTAssertEqual(expenses().count, countBefore - 1)

        // 10. Undo through the assistant.
        _ = try await say("Отмени последнее действие")
        XCTAssertEqual(expenses().count, countBefore)

        // 11. Missing amount → clarifying question, nothing recorded.
        let n = host.data.transactions.count
        let r11 = try await say("Запиши расход на такси")
        XCTAssertEqual(host.data.transactions.count, n, "nothing should be added without an amount")
        XCTAssertTrue(r11.reply.contains("?"), "should ask a clarifying question")
    }
}
