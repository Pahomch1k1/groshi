import XCTest
@testable import GroshiCore

/// 0.5: a reply "Добавлено" only after a real save, partial saves, one submission never saved twice,
/// the voice draft that is appended to and survives a restart.
final class V05Tests: XCTestCase {
    let cal = Period.calendar(firstWeekday: 2, timeZone: TimeZone(identifier: "Europe/Kyiv")!)
    var now: Date!
    var t: TestHost!
    var net: MockTransport!
    var engine: AssistantEngine!

    override func setUp() {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        now = f.date(from: "2026-11-21 10:00")!
        t = TestHost(Defaults.makeInitialData(language: .ru))
        net = MockTransport()
        engine = AssistantEngine(transport: net, host: t.host, calendar: cal, now: { [unowned self] in self.now })
    }

    func ymd(_ d: Date) -> String { DateFormatter.ymd(cal).string(from: d) }
    func item(_ kind: String, _ amount: String, _ cat: String, _ date: String?) -> String {
        "{\"kind\":\"\(kind)\",\"amount\":\"\(amount)\",\"category\":\"\(cat)\"" + (date.map { ",\"date\":\"\($0)\"" } ?? "") + "}"
    }
    func add(_ items: [String]) -> ChatMessage { net.call("add_transactions", "{\"items\":[" + items.joined(separator: ",") + "]}") }

    /// «14 ноября ресторан 850, продукты 320, 15 ноября кофе 120, такси 250, вчера доставка 400».
    var fiveItems: [String] {
        [item("expense", "850", "Кафе и рестораны", "2026-11-14"), item("expense", "320", "Продукты", "2026-11-14"),
         item("expense", "120", "Кафе и рестораны", "2026-11-15"), item("expense", "250", "Транспорт", "2026-11-15"),
         item("expense", "400", "Продукты", "2026-11-20")]
    }

    func testFiveOperationsWithDifferentDates() async throws {
        net.queue = [add(fiveItems), .assistant("Добавлено 5 транзакций на 1 940 грн.")]
        let r = try await engine.send("14 ноября ресторан 850, продукты 320, 15 ноября кофе 120, такси 250, вчера доставка 400", requestID: "req-5")
        XCTAssertEqual(t.data.transactions.count, 5)
        XCTAssertEqual(r.savedTransactions.count, 5)
        XCTAssertEqual(t.data.transactions.reduce(0) { $0 + $1.amountMinor }, 194_000)
        XCTAssertEqual(t.data.transactions.filter { ymd($0.date) == "2026-11-14" }.count, 2)
        XCTAssertEqual(t.data.transactions.filter { ymd($0.date) == "2026-11-15" }.count, 2)
        XCTAssertEqual(t.data.transactions.filter { ymd($0.date) == "2026-11-20" }.count, 1)
        XCTAssertTrue(t.data.transactions.allSatisfy { $0.requestID == "req-5" })
        XCTAssertFalse(r.unverifiedClaim)
        XCTAssertEqual(r.reply, "Добавлено 5 транзакций на 1 940 грн.")
    }

    /// The model says «Добавлено» without calling the tool: it is told once, then records for real.
    func testClaimWithoutSavingIsCheckedAndCorrected() async throws {
        net.queue = [.assistant("Всё добавлено!"), add(fiveItems), .assistant("Добавлено 5 транзакций.")]
        let r = try await engine.send("…", requestID: "req-claim")
        XCTAssertEqual(t.data.transactions.count, 5)
        XCTAssertFalse(r.unverifiedClaim)
        XCTAssertTrue(net.requests[1].contains { $0.role == "system" && $0.content!.contains("NOTHING was saved") })
    }

    /// The model insists on a save that did not happen: the reply is dropped, the app shows an error.
    func testRepeatedFalseClaimIsNeverShownAsSuccess() async throws {
        net.queue = [.assistant("Добавлено."), .assistant("Сохранил всё.")]
        let r = try await engine.send("…", requestID: "req-lie")
        XCTAssertTrue(t.data.transactions.isEmpty)
        XCTAssertTrue(r.unverifiedClaim)
        XCTAssertEqual(r.reply, "")
        XCTAssertFalse(r.savedSomething)
    }

    /// A tool error (unknown category) followed by «Добавлено» is not a success either.
    func testFailedToolThenClaim() async throws {
        net.queue = [add([item("expense", "850", "Нет такой", "2026-11-14")]), .assistant("Добавлено."), .assistant("Добавлено.")]
        let r = try await engine.send("…")
        XCTAssertTrue(t.data.transactions.isEmpty)
        XCTAssertTrue(r.unverifiedClaim)
        XCTAssertEqual(r.notSaved.count, 1)
    }

    func testClaimWordsAndNegations() {
        for s in ["Добавлено 5 транзакций", "Сохранено 3 операции", "Записал 850 грн", "Додано 2 транзакції", "Збережено.", "Saved 3 transactions"] {
            XCTAssertTrue(AssistantEngine.claimsSaved(s), s)
        }
        for s in ["За какую дату?", "Ничего не сохранено.", "Не додано: немає дати", "Что добавить?", "Сохранить?", "Nothing was saved"] {
            XCTAssertFalse(AssistantEngine.claimsSaved(s), s)
        }
    }

    /// Questions about history may say «добавили» — no false alarm.
    func testSummaryWordingIsNotAClaim() async throws {
        net.queue = [net.call("summarize", #"{"date_from":"2026-11-01","date_to":"2026-11-21"}"#), .assistant("В ноябре вы добавили расходов на 0 UAH.")]
        let r = try await engine.send("Сколько я добавил расходов в ноябре?")
        XCTAssertFalse(r.unverifiedClaim)
        XCTAssertFalse(r.reply.isEmpty)
    }

    /// Seven items, two without a category that exists: five are saved, the two are named.
    func testPartialSaveReportsTheRest() async throws {
        let seven = fiveItems + [item("expense", "90", "Нет такой", "2026-11-20"), item("expense", "60", "Тоже нет", "2026-11-20")]
        net.queue = [add(seven), .assistant("Добавлено 5 из 7. Для 90 и 60 грн — какая категория?")]
        let r = try await engine.send("…", requestID: "req-7")
        XCTAssertEqual(t.data.transactions.count, 5)
        XCTAssertEqual(r.savedTransactions.count, 5)
        XCTAssertEqual(r.notSaved.count, 2)
        let tool = JSON.parse(engine.history.first { $0.role == "tool" }!.content!)!
        XCTAssertEqual(tool["status"], "partially_saved")
        XCTAssertEqual(tool["not_saved"]?.array?.count, 2)
        XCTAssertTrue(tool["not_saved"]!.array![0].text!.hasPrefix("item 6"))
        XCTAssertFalse(r.unverifiedClaim)
    }

    /// Same draft sent again (lost answer, crash, double tap): nothing new is saved, the model is not called.
    func testSameSubmissionIsNeverSavedTwice() async throws {
        net.queue = [add(fiveItems), .assistant("Добавлено 5.")]
        _ = try await engine.send("…", requestID: "req-once")
        let calls = net.requests.count
        let r = try await engine.send("…", requestID: "req-once")
        XCTAssertTrue(r.alreadySaved)
        XCTAssertEqual(r.savedTransactions.count, 5)
        XCTAssertEqual(net.requests.count, calls, "no second request to the model")
        XCTAssertEqual(t.data.transactions.count, 5)
    }

    /// The model repeats the tool with an extra item in the same submission: only the new item is added.
    func testRepeatedCallInSameSubmissionAddsOnlyNew() async throws {
        net.queue = [add(Array(fiveItems.prefix(2))), add(Array(fiveItems.prefix(3))), .assistant("Добавлено 3.")]
        _ = try await engine.send("…", requestID: "req-rep")
        XCTAssertEqual(t.data.transactions.count, 3)
    }

    /// The connection drops before anything is saved: an error, nothing saved, a retry with the same
    /// id saves exactly once.
    func testNetworkFailureThenRetry() async throws {
        let flaky = FlakyTransport()
        let e2 = AssistantEngine(transport: flaky, host: t.host, calendar: cal, now: { [unowned self] in self.now })
        flaky.failOnCall = [1]
        do { _ = try await e2.send("…", requestID: "req-net"); XCTFail("expected an error") } catch {}
        XCTAssertTrue(t.data.transactions.isEmpty)
        flaky.queue = [flaky.call("add_transactions", "{\"items\":[" + fiveItems.joined(separator: ",") + "]}"), .assistant("Добавлено 5.")]
        let r = try await e2.send("…", requestID: "req-net")
        XCTAssertEqual(r.savedTransactions.count, 5)
        XCTAssertEqual(t.data.transactions.count, 5)
    }

    /// Saved, then the connection drops before the reply: kept, reported as saved, a retry adds nothing.
    func testDropAfterSaveThenRetry() async throws {
        let flaky = FlakyTransport()
        let e2 = AssistantEngine(transport: flaky, host: t.host, calendar: cal, now: { [unowned self] in self.now })
        flaky.queue = [flaky.call("add_transactions", "{\"items\":[" + fiveItems.joined(separator: ",") + "]}")]
        flaky.failOnCall = [2]
        let r = try await e2.send("…", requestID: "req-drop")
        XCTAssertTrue(r.interrupted)
        XCTAssertEqual(r.savedTransactions.count, 5)
        let again = try await e2.send("…", requestID: "req-drop")
        XCTAssertTrue(again.alreadySaved)
        XCTAssertEqual(t.data.transactions.count, 5)
    }

    /// A draft made in a turn whose connection then failed does not linger as a hidden pending action.
    func testFailedTurnLeavesNoHiddenDraft() async throws {
        net.queue = [add([item("expense", "850", "Кафе и рестораны", "2026-11-21")]), .assistant("ok")]
        _ = try await engine.send("850 ресторан")
        let flaky = FlakyTransport()
        let e2 = AssistantEngine(transport: flaky, host: t.host, calendar: cal, now: { [unowned self] in self.now })
        flaky.queue = [flaky.call("add_transactions", #"{"items":[{"kind":"expense","amount":"850","category":"Кафе и рестораны","date":"2026-11-21"}]}"#)]
        flaky.failOnCall = [2]
        do { _ = try await e2.send("850 ресторан"); XCTFail("expected an error") } catch {}
        XCTAssertNil(e2.pending)
    }

    // MARK: Voice draft

    func testDraftAppendsAndTidies() {
        var text = VoiceDraft.joined("", "14 ноября ресторан 850 гривен, продукты 320 гривен")
        XCTAssertEqual(text, "14 ноября ресторан 850 грн, продукты 320 грн")
        text = VoiceDraft.joined(text, "15 ноября кофе 120 гривен, такси 250 гривен")
        XCTAssertEqual(text, "14 ноября ресторан 850 грн, продукты 320 грн, 15 ноября кофе 120 грн, такси 250 грн")
        XCTAssertEqual(VoiceDraft.joined("Кофе 120 грн.", "такси 250"), "Кофе 120 грн. такси 250")
        XCTAssertEqual(VoiceDraft.joined("кофе 120", "  "), "кофе 120")
        XCTAssertEqual(VoiceDraft.tidy("тысяча гривен"), "тысяча гривен", "words stay as said")
    }

    func testDraftSurvivesRestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = VoiceDraft(text: "14 ноября ресторан 850 грн", requestID: "req-x")
        try VoiceDraftStore(directory: dir).save(d)
        let loaded = VoiceDraftStore(directory: dir).load()
        XCTAssertEqual(loaded?.text, d.text)
        XCTAssertEqual(loaded?.requestID, "req-x")
        VoiceDraftStore(directory: dir).clear()
        XCTAssertNil(VoiceDraftStore(directory: dir).load())
        try VoiceDraftStore(directory: dir).save(VoiceDraft(text: "   "))
        XCTAssertNil(VoiceDraftStore(directory: dir).load(), "an empty draft is not kept")
    }

    /// Data saved by 0.4 (without requestID) still loads.
    func testOldTransactionsDecode() throws {
        var d = Defaults.makeInitialData(language: .ru)
        let c = d.categories(of: .expense)[0], w = d.wallets[0]
        d.transactions = [Txn(kind: .expense, amountMinor: 100, currency: "UAH", categoryID: c.id, walletID: w.id, date: now)]
        let json = String(decoding: try FileStore.encoder().encode(d), as: UTF8.self)
        XCTAssertFalse(json.contains("requestID"))
        let back = try FileStore.decoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertNil(back.transactions[0].requestID)
    }
}
