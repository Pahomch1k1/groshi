import XCTest
@testable import GroshiCore

final class MoneyTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(MoneyMath.parseMinor("850", currency: "UAH"), 85000)
        XCTAssertEqual(MoneyMath.parseMinor("1 200,50", currency: "UAH"), 120050)
        XCTAssertEqual(MoneyMath.parseMinor("1,234.56", currency: "USD"), 123456)
        XCTAssertEqual(MoneyMath.parseMinor("1.234,56", currency: "EUR"), 123456)
        XCTAssertEqual(MoneyMath.parseMinor("-450", currency: "UAH"), -45000)
        XCTAssertEqual(MoneyMath.parseMinor("10000.00000000", currency: "UAH"), 1000000)
        XCTAssertEqual(MoneyMath.parseMinor("0.005", currency: "UAH"), 1) // half-up
        XCTAssertEqual(MoneyMath.parseMinor("₴99", currency: "UAH"), 9900)
        XCTAssertNil(MoneyMath.parseMinor("12abc", currency: "UAH"))
        XCTAssertNil(MoneyMath.parseMinor("", currency: "UAH"))
        XCTAssertEqual(MoneyMath.parseMinor("1500", currency: "JPY"), 1500)
    }

    func testNoFloatingErrors() {
        // 0.1 + 0.2 must be exactly 0.3
        let a = MoneyMath.parseMinor("0.1", currency: "UAH")!, b = MoneyMath.parseMinor("0.2", currency: "UAH")!
        XCTAssertEqual(MoneyMath.plainString(a + b, currency: "UAH"), "0.30")
        var sum: Int64 = 0
        for _ in 0..<1000 { sum += MoneyMath.parseMinor("19.99", currency: "UAH")! }
        XCTAssertEqual(sum, 1_999_000)
    }

    func testFormat() {
        XCTAssertEqual(MoneyMath.format(125050, currency: "UAH"), "₴1\u{202F}250,50")
        XCTAssertEqual(MoneyMath.format(-100000, currency: "UAH"), "−₴1\u{202F}000")
        XCTAssertEqual(MoneyMath.format(500, currency: "PLN"), "5 zł")
        XCTAssertEqual(MoneyMath.plainString(-5, currency: "UAH"), "-0.05")
    }

    func testConverter() {
        let c = CurrencyConverter(base: "UAH", rates: ["USD": Decimal(string: "41.5")!, "EUR": Decimal(string: "48.2")!])
        XCTAssertEqual(c.convert(10000, from: "USD", to: "UAH"), 415000)
        XCTAssertEqual(c.convert(415000, from: "UAH", to: "USD"), 10000)
        let s = c.sum([(100, "USD"), (100, "USD"), (5000, "UAH"), (1, "XXX")], into: "UAH")
        XCTAssertEqual(s.total, 8300 + 5000)
        XCTAssertEqual(s.missing, ["XXX"])
    }
}

final class DataTests: XCTestCase {
    var data: AppData!
    let cal = Period.calendar(firstWeekday: 2, timeZone: TimeZone(identifier: "Europe/Kyiv")!)

    override func setUp() {
        data = Defaults.makeInitialData(language: .ru)
    }

    func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func add(_ kind: TxKind, _ amount: String, _ cat: String, _ d: String, cur: String = "UAH") {
        let c = data.categoryNamed(cat, kind: kind)!
        let t = Txn(kind: kind, amountMinor: MoneyMath.parseMinor(amount, currency: cur)!, currency: cur, categoryID: c.id,
                    walletID: data.defaultWallet!.id, date: date(d))
        try! Mutation.addTransactions([t]).apply(to: &data)
    }

    func testTotalsAndBreakdown() {
        add(.expense, "850", "Кафе и рестораны", "2026-11-10 13:00")
        add(.expense, "1200", "Бензин", "2026-11-11 09:00")
        add(.expense, "450", "Автомобиль", "2026-11-11 09:10")
        add(.income, "15000", "Бизнес", "2026-11-12 10:00")
        add(.expense, "10", "Другое", "2026-10-31 23:59") // previous month
        add(.expense, "100", "Другое", "2026-11-05 10:00", cur: "USD") // 100 USD * 41.50
        let p = Period.containing(date("2026-11-15 12:00"), kind: .month, calendar: cal)
        let txs = Analytics.filter(data, period: p)
        XCTAssertEqual(txs.count, 5)
        let t = Analytics.totals(txs, data: data)
        XCTAssertEqual(t.income, 1_500_000)
        XCTAssertEqual(t.expense, 85000 + 120000 + 45000 + 415000)
        XCTAssertEqual(t.net, 1_500_000 - 665000)
        let b = Analytics.breakdown(txs, kind: .expense, data: data)
        XCTAssertEqual(b.first?.categoryID, data.categoryNamed("Другое")!.id)
        XCTAssertLessThanOrEqual(abs(b.map { $0.basisPoints }.reduce(0, +) - 10000), 2)
        let groups = Analytics.dayGroups(txs, data: data, calendar: cal)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups[1].net, -165000) // Nov 11
        let buckets = Analytics.buckets(txs, period: p, data: data, calendar: cal)
        XCTAssertEqual(buckets.count, 30)
    }

    func testPeriods() {
        let d = date("2026-11-19 10:00") // Thursday
        let w = Period.containing(d, kind: .week, calendar: cal)
        XCTAssertEqual(w.start, date("2026-11-16 00:00"))
        let prev = Period.containing(d, kind: .month, calendar: cal).shifted(by: -1, calendar: cal)
        XCTAssertEqual(prev.start, date("2026-10-01 00:00"))
        XCTAssertEqual(prev.end, date("2026-11-01 00:00"))
    }

    func testCategoryAndWalletMutations() throws {
        let hookah = Category(name: "Кальян", kind: .expense, icon: .emoji("💨"), colorHex: "#A55EEA")
        try Mutation.upsertCategory(hookah).apply(to: &data)
        XCTAssertNotNil(data.categoryNamed("кальян"))
        XCTAssertThrowsError(try Mutation.upsertCategory(Category(name: "КАЛЬЯН", kind: .expense, icon: .symbol("x"), colorHex: "#000000")).apply(to: &data))
        add(.expense, "300", "Кальян", "2026-11-10 22:00")
        // Deleting a used category without target archives it (history kept).
        try Mutation.deleteCategory(id: hookah.id, moveTo: nil).apply(to: &data)
        XCTAssertTrue(data.category(hookah.id)!.isArchived)
        XCTAssertEqual(data.transactions.count, 1)
        // Moving transactions to another category deletes it for real.
        let other = data.categoryNamed("Другое", kind: .expense)!
        try Mutation.deleteCategory(id: hookah.id, moveTo: other.id).apply(to: &data)
        XCTAssertNil(data.category(hookah.id))
        XCTAssertEqual(data.transactions[0].categoryID, other.id)

        let usd = Wallet(name: "Доллары", currency: "USD", initialBalanceMinor: 50000)
        try Mutation.upsertWallet(usd).apply(to: &data)
        XCTAssertEqual(data.balance(of: data.walletNamed("доллары")!), 50000)
    }

    func testBatchIsAtomic() {
        let before = data!
        let bad = Mutation.batch([
            .upsertCategory(Category(name: "Новая", kind: .expense, icon: .symbol("tag"), colorHex: "#111111")),
            .deleteTransactions([UUID()])
        ])
        XCTAssertThrowsError(try bad.apply(to: &data))
        XCTAssertEqual(data, before)
    }

    func testCSVRoundTrip() {
        add(.expense, "850.5", "Кафе и рестораны", "2026-11-10 13:00")
        data.transactions[0].note = "Обед, \"Пузата хата\"\nвторая строка"
        add(.income, "15000", "Бизнес", "2026-11-12 10:00")
        let csv = CSVExchange.export(data, timeZone: cal.timeZone)
        var fresh = Defaults.makeInitialData(language: .ru)
        let plan = CSVExchange.plan(csv: csv, into: fresh, timeZone: cal.timeZone)
        XCTAssertTrue(plan.errors.isEmpty, "\(plan.errors)")
        XCTAssertEqual(plan.transactions.count, 2)
        XCTAssertTrue(plan.newCategories.isEmpty)
        try! plan.mutation.apply(to: &fresh)
        let e = fresh.transactions.first { $0.kind == .expense }!
        XCTAssertEqual(e.amountMinor, 85050)
        XCTAssertEqual(e.note, "Обед, \"Пузата хата\"\nвторая строка")
        XCTAssertEqual(e.date, date("2026-11-10 13:00"))
        // Re-import is idempotent.
        let again = CSVExchange.plan(csv: csv, into: fresh, timeZone: cal.timeZone)
        XCTAssertEqual(again.transactions.count, 0)
        XCTAssertEqual(again.duplicates, 2)
    }

    func testSpendeeCSV() {
        let csv = """
        Date,Wallet,Type,"Category name",Amount,Currency,Note,Labels,Author
        "2026-10-03 12:30:00",Main Wallet,Expense,Food & Drink,-125.50000000,UAH,Coffee,"work, trip",Tester
        "2026-10-04 09:00:00+03:00",Main Wallet,Income,Salary,30000.00000000,UAH,,,Tester
        "2026-10-05 10:00:00",USD Cash,expense,Shopping,-20,USD,Shoes,,Tester
        "2026-10-06 10:00:00",Main Wallet,Outgoing Transfer,,-500,UAH,,,Tester
        "bad date",Main Wallet,Expense,Food,-1,UAH,,,Tester
        """
        let plan = CSVExchange.plan(csv: csv, into: data, timeZone: cal.timeZone)
        XCTAssertEqual(plan.transactions.count, 4)
        XCTAssertEqual(plan.errors.count, 1)
        XCTAssertEqual(plan.errors.first?.line, 6)
        XCTAssertEqual(plan.transfers, 1)
        XCTAssertEqual(Set(plan.newWallets.map { $0.name }), ["Main Wallet", "USD Cash"])
        XCTAssertEqual(plan.newWallets.first { $0.name == "USD Cash" }?.currency, "USD")
        let coffee = plan.transactions[0]
        XCTAssertEqual(coffee.kind, .expense)
        XCTAssertEqual(coffee.amountMinor, 12550)
        XCTAssertEqual(coffee.note, "Coffee")
        XCTAssertEqual(coffee.tags, ["work", "trip"])
        XCTAssertEqual(Set(plan.newLabels.map { $0.name }), ["work", "trip"])
        XCTAssertTrue(plan.isSpendee)
        XCTAssertEqual(plan.transactions[1].kind, .income)
        XCTAssertEqual(plan.transactions[1].amountMinor, 3_000_000)
        var d = data!
        XCTAssertNoThrow(try plan.mutation.apply(to: &d))
        XCTAssertEqual(d.transactions.count, 4)
    }

    func testSemicolonCSV() {
        let csv = "Дата;Тип;Сумма;Категория;Комментарий\n10.11.2026 13:00;Расход;1 200,50;Бензин;Окко\n"
        let plan = CSVExchange.plan(csv: csv, into: data, timeZone: cal.timeZone)
        XCTAssertEqual(plan.transactions.count, 1)
        XCTAssertEqual(plan.transactions[0].amountMinor, 120050)
        XCTAssertEqual(plan.transactions[0].categoryID, data.categoryNamed("Бензин")!.id)
    }

    func testPersistenceAndRecovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("groshi-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        add(.expense, "99.99", "Продукты", "2026-11-10 13:00")
        let store = FileStore(directory: dir)
        try store.save(data)
        // "Restart": a brand new store instance reads the same data.
        guard case .loaded(let loaded) = FileStore(directory: dir).load() else { return XCTFail("not loaded") }
        XCTAssertEqual(loaded, data)
        // Corrupt main file → falls back to the snapshot.
        try Data("garbage".utf8).write(to: store.dataURL)
        guard case .recoveredFromSnapshot(let rec, _) = FileStore(directory: dir).load() else { return XCTFail("not recovered") }
        XCTAssertEqual(rec, data)
        // Backup file round trip.
        let backup = BackupFile(data: data, icons: ["a.png": "AAAA"])
        let decoded = try BackupFile.decode(backup.encoded())
        XCTAssertEqual(decoded.data, data)
        XCTAssertEqual(decoded.icons["a.png"], "AAAA")
    }

    func testDuplicateCheck() {
        add(.expense, "850", "Кафе и рестораны", "2026-11-10 13:00")
        let existing = data.transactions[0]
        let again = Txn(kind: .expense, amountMinor: 85000, currency: "UAH", categoryID: existing.categoryID,
                        walletID: existing.walletID, date: date("2026-11-10 13:05"))
        XCTAssertEqual(DuplicateCheck.suspects(for: again, in: data, calendar: cal, now: existing.createdAt.addingTimeInterval(60)).count, 1)
        XCTAssertEqual(DuplicateCheck.suspects(for: again, in: data, calendar: cal, now: existing.createdAt.addingTimeInterval(3600)).count, 0)
    }
}
