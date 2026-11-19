import XCTest
@testable import GroshiCore

final class V02Tests: XCTestCase {
    let cal = Period.calendar(firstWeekday: 2, timeZone: TimeZone(identifier: "Europe/Kyiv")!)

    func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    // MARK: Calculator

    func testCalculator() {
        XCTAssertEqual(Calculator.evaluate("1200+450"), 1650)
        XCTAssertEqual(Calculator.evaluate("100+50×2"), 200)
        XCTAssertEqual(Calculator.evaluate("10÷4"), Decimal(string: "2.5"))
        XCTAssertEqual(Calculator.evaluate("0,1+0,2"), Decimal(string: "0.3"))
        XCTAssertEqual(Calculator.evaluate("500−120,5"), Decimal(string: "379.5"))
        XCTAssertEqual(Calculator.evaluate("12+"), 12)
        XCTAssertNil(Calculator.evaluate("5÷0"))
        XCTAssertEqual(Calculator.minor("100÷3", currency: "UAH"), 3333)
        var s = ""
        for k in ["1", "2", "+", "×", "3", ",", "5", "5", "5", "⌫"] { s = Calculator.press(k, to: s) }
        XCTAssertEqual(s, "12×3,5")
        XCTAssertEqual(Calculator.press(",", to: ""), "0,")
        XCTAssertEqual(Calculator.press("+", to: ""), "")
        XCTAssertEqual(Calculator.press("7", to: "0"), "7")
        XCTAssertEqual(Calculator.press(",", to: "1,5"), "1,5")
    }

    // MARK: Recurrence

    func testRecurringCatchUp() throws {
        var data = Defaults.makeInitialData(language: .ru)
        let cat = data.categoryNamed("Подписки")!
        let tpl = Txn(kind: .expense, amountMinor: 29900, currency: "UAH", categoryID: cat.id, walletID: data.defaultWallet!.id,
                      date: date("2026-09-05 10:00"), note: "Netflix")
        let rule = RecurringRule(template: tpl, frequency: .monthly, nextDate: date("2026-09-05 10:00"))
        try Mutation.upsertRecurring(rule).apply(to: &data)
        XCTAssertEqual(Recurrence.catchUp(&data, now: date("2026-11-19 12:00"), calendar: cal), 3) // Sep, Oct, Nov
        XCTAssertEqual(data.transactions.count, 3)
        XCTAssertTrue(data.transactions.allSatisfy { $0.recurringID == rule.id && $0.note == "Netflix" })
        XCTAssertEqual(data.recurring[0].nextDate, date("2026-12-05 10:00"))
        XCTAssertEqual(Recurrence.catchUp(&data, now: date("2026-11-19 12:00"), calendar: cal), 0) // idempotent
        let dec = Period.containing(date("2026-12-10 12:00"), kind: .month, calendar: cal)
        XCTAssertEqual(Recurrence.upcoming(data, in: dec, after: date("2026-11-19 12:00"), calendar: cal).count, 1)
        try Mutation.deleteRecurring(id: rule.id).apply(to: &data)
        XCTAssertTrue(data.recurring.isEmpty)
        XCTAssertEqual(data.transactions.count, 3) // history kept
    }

    // MARK: Labels and exclusion

    func testLabelsAndExclusion() throws {
        var data = Defaults.makeInitialData(language: .ru)
        let tea = TxLabel(name: "Чай")
        try Mutation.upsertLabel(tea).apply(to: &data)
        XCTAssertThrowsError(try Mutation.upsertLabel(TxLabel(name: "чай")).apply(to: &data))
        let cat = data.categoryNamed("Кафе и рестораны")!
        let w = data.defaultWallet!.id
        let t1 = Txn(kind: .expense, amountMinor: 10000, currency: "UAH", categoryID: cat.id, walletID: w, date: date("2026-11-10 10:00"), labels: ["Чай"])
        let t2 = Txn(kind: .expense, amountMinor: 50000, currency: "UAH", categoryID: cat.id, walletID: w, date: date("2026-11-10 11:00"), excluded: true)
        try Mutation.addTransactions([t1, t2]).apply(to: &data)
        let p = Period.containing(date("2026-11-15 12:00"), kind: .month, calendar: cal)
        let all = Analytics.filter(data, period: p)
        XCTAssertEqual(Analytics.totals(all, data: data).expense, 10000) // excluded one left out
        XCTAssertEqual(Analytics.breakdown(all, kind: .expense, data: data).first?.amountMinor, 10000)
        var f = TxFilter(); f.labels = ["Чай"]
        XCTAssertEqual(Analytics.filter(data, period: p, filter: f).count, 1)
        // Rename propagates; delete removes from transactions.
        var renamed = tea; renamed.name = "Tea"
        try Mutation.upsertLabel(renamed).apply(to: &data)
        XCTAssertEqual(data.transactions.first { $0.id == t1.id }?.tags, ["Tea"])
        try Mutation.deleteLabel(id: tea.id).apply(to: &data)
        XCTAssertEqual(data.transactions.first { $0.id == t1.id }?.tags, [])
        try Mutation.updateTransactions(ids: [t2.id], changes: TxChanges(excluded: false)).apply(to: &data)
        XCTAssertEqual(Analytics.totals(Analytics.filter(data, period: p), data: data).expense, 60000)
    }

    func testV01FileStillLoads() throws {
        var data = Defaults.makeInitialData(language: .ru)
        let cat = data.categoryNamed("Продукты")!
        try Mutation.addTransactions([Txn(kind: .expense, amountMinor: 100, currency: "UAH", categoryID: cat.id, walletID: data.defaultWallet!.id, date: Date())]).apply(to: &data)
        var obj = try JSONSerialization.jsonObject(with: FileStore.encoder().encode(data)) as! [String: Any]
        obj.removeValue(forKey: "labels"); obj.removeValue(forKey: "recurring"); obj["version"] = 1
        let old = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try FileStore.decoder().decode(AppData.self, from: old)
        XCTAssertEqual(decoded.transactions, data.transactions)
        XCTAssertTrue(decoded.labels.isEmpty)
    }

    // MARK: Anonymised copy of the real Spendee export format

    /// Same columns, quoting, date style, 8-decimal amounts, padded category names and labels as the real file,
    /// with made-up amounts (the real history never leaves the owner's computer).
    func spendeeFixture() -> (csv: String, income: Int64, expense: Int64, rows: Int) {
        var lines = [#"Date,Wallet,Type,"Category name",Amount,Currency,Note,Labels,Author"#]
        let cats = ["Gifts", "Girls", "Restaurant ", "Cafe", "Food", "Programs ", "Games", " Cigarettes", "Post", "Zoo", "Gas", "Car", "Travle", "Bus/Train/Plane"]
        var inc: Int64 = 0, exp: Int64 = 0, n = 0
        for month in 0..<24 {
            let y = 2024 + (10 + month) / 12, m = (10 + month) % 12 + 1
            for d in stride(from: 1, through: 27, by: 2) {
                let cat = cats[(d + month) % cats.count]
                let amount = Int64(37 + d * 13 + month * 7) * 100 + Int64(d % 3) * 50
                let label = d % 5 == 0 ? "Чай" : (d % 7 == 0 ? "JHG" : "")
                let note = d % 9 == 0 ? #""Кофе, ""Аромакава""""# : ""
                lines.append(String(format: "%04d-%02d-%02dT%02d:%02d:11+00:00", y, m, d, 9 + d % 12, d) + ",Mono,Expense,\(cat),-\(amount / 100).\(String(format: "%02d", amount % 100))000000,UAH,\(note),\(label),\"Test User\"")
                exp += amount; n += 1
            }
            let salary = Int64(13387 + month * 101) * 100
            lines.append(String(format: "%04d-%02d-01T13:43:11+00:00", y, m) + ",Mono,Income,Salary,\(salary / 100).00000000,UAH,,JHG,\"Test User\"")
            inc += salary; n += 1
            lines.append(String(format: "%04d-%02d-15T08:00:00+00:00", y, m) + ",Mono,Income,Business,500.00000000,UAH,,,\"Test User\"")
            inc += 50000; n += 1
        }
        return (lines.joined(separator: "\n") + "\n", inc, exp, n)
    }

    func testSpendeeRealFormatImport() throws {
        let fx = spendeeFixture()
        var data = Defaults.makeInitialData(language: .ru) // starter categories in Russian, no transactions
        let plan = CSVExchange.plan(csv: fx.csv, into: data, timeZone: cal.timeZone)
        XCTAssertTrue(plan.errors.isEmpty, "\(plan.errors.prefix(3))")
        XCTAssertTrue(plan.isSpendee)
        XCTAssertEqual(plan.rowCount, fx.rows)
        XCTAssertEqual(plan.transactions.count, fx.rows)
        XCTAssertEqual(plan.sourceTotals.income["UAH"], fx.income)
        XCTAssertEqual(plan.sourceTotals.expense["UAH"], fx.expense)
        XCTAssertEqual(plan.plannedTotals, plan.sourceTotals)
        XCTAssertEqual(plan.sourceByMonth.count, 24)
        XCTAssertEqual(plan.mismatchedMonths, [])
        XCTAssertEqual(plan.newWallets.map { $0.name }, ["Mono"])
        XCTAssertEqual(plan.newLabels.map { $0.name }, ["JHG", "Чай"].sorted { a, b in
            plan.transactions.filter { $0.tags.contains(a) }.count > plan.transactions.filter { $0.tags.contains(b) }.count })
        // Padded names are trimmed; Spendee order and icons applied; unused screenshot categories added.
        let names = Set(plan.newCategories.map { $0.name })
        XCTAssertTrue(names.contains("Restaurant") && names.contains("Cigarettes") && names.contains("Programs"))
        XCTAssertTrue(names.contains("Education") && names.contains("Hospital"))
        XCTAssertEqual(plan.newCategories.first { $0.name == "Food" }?.sortOrder, 1)
        XCTAssertEqual(plan.newCategories.first { $0.name == "Hotel" }?.sortOrder, 46)
        XCTAssertEqual(plan.newCategories.first { $0.name == "Cafe" }?.icon, .symbol("cup.and.saucer.fill"))
        // Note with comma and quotes survives.
        XCTAssertTrue(plan.transactions.contains { $0.note == #"Кофе, "Аромакава""# })
        // The starter categories are offered for removal.
        XCTAssertEqual(plan.unusedCategoryIDs.count, data.categories.count)
        try plan.mutation(removingUnused: true).apply(to: &data)
        XCTAssertEqual(data.activeWallets.map { $0.name }, ["Mono"])
        XCTAssertEqual(data.defaultWallet?.name, "Mono")
        XCTAssertEqual(data.categories(of: .expense).count, 46)
        XCTAssertEqual(data.categories(of: .income).count, 6)
        XCTAssertEqual(data.labels.count, 2)
        // Monthly totals in the app equal the file.
        for (month, src) in plan.sourceByMonth {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM"
            let start = f.date(from: month)!
            let p = Period.containing(start, kind: .month, calendar: cal)
            let t = Analytics.totals(Analytics.filter(data, period: p), data: data)
            XCTAssertEqual(t.income, src.income["UAH"] ?? 0, month)
            XCTAssertEqual(t.expense, src.expense["UAH"] ?? 0, month)
        }
        // Re-import creates nothing.
        let again = CSVExchange.plan(csv: fx.csv, into: data, timeZone: cal.timeZone)
        XCTAssertEqual(again.transactions.count, 0)
        XCTAssertEqual(again.duplicates, fx.rows)
        XCTAssertTrue(again.newCategories.isEmpty)
    }
}
