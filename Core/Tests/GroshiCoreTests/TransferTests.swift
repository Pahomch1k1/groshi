import XCTest
@testable import GroshiCore

final class TransferTests: XCTestCase {
    let cal = Period.calendar(firstWeekday: 2, timeZone: TimeZone(identifier: "Europe/Kyiv")!)
    var data: AppData!
    var card: Wallet!, cash: Wallet!, usd: Wallet!

    override func setUp() {
        data = Defaults.makeInitialData(language: .ru)
        card = data.walletNamed("Карта")!
        cash = data.walletNamed("Наличные")!
        usd = Wallet(name: "Доллары", currency: "USD")
        try! Mutation.upsertWallet(usd).apply(to: &data)
        data.settings.rates = ["USD": "41.50"]
    }

    func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func testTransferMovesMoneyButNotCashFlow() throws {
        let salary = Txn(kind: .income, amountMinor: 1_000_000, currency: "UAH", categoryID: data.categoryNamed("Зарплата")!.id,
                         walletID: card.id, date: date("2026-11-01 10:00"))
        let atm = Txn.transfer(from: card.id, to: cash.id, amountMinor: 200_000, currency: "UAH", date: date("2026-11-02 10:00"))
        // Buy 100 USD for 4 200 UAH (bank rate differs from the app rate).
        let fx = Txn.transfer(from: card.id, to: usd.id, amountMinor: 420_000, currency: "UAH", toAmountMinor: 10_000,
                              toCurrency: "USD", date: date("2026-11-03 10:00"))
        try Mutation.addTransactions([salary, atm, fx]).apply(to: &data)

        XCTAssertEqual(data.balance(of: card), 1_000_000 - 200_000 - 420_000)
        XCTAssertEqual(data.balance(of: cash), 200_000)
        XCTAssertEqual(data.balance(of: usd), 10_000)

        let p = Period.containing(date("2026-11-15 12:00"), kind: .month, calendar: cal)
        let txs = Analytics.filter(data, period: p)
        XCTAssertEqual(txs.count, 3)
        let t = Analytics.totals(txs, data: data)
        XCTAssertEqual(t.income, 1_000_000)
        XCTAssertEqual(t.expense, 0)
        XCTAssertEqual(Analytics.breakdown(txs, kind: .expense, data: data).count, 0)
        XCTAssertEqual(Analytics.dayGroups(txs, data: data, calendar: cal).first { cal.component(.day, from: $0.day) == 2 }?.net, 0)
        XCTAssertTrue(Analytics.buckets(txs, period: p, data: data, calendar: cal).allSatisfy { $0.expense == 0 })
        // Wallet filter finds a transfer from either side.
        XCTAssertEqual(Analytics.filter(data, period: p, filter: TxFilter(walletIDs: [cash.id])).count, 1)
        // Same-currency transfer stores a single amount.
        XCTAssertNil(data.transactions.first { $0.toWalletID == cash.id }!.toAmountMinor)
    }

    func testTransferValidation() {
        XCTAssertThrowsError(try Mutation.addTransactions([Txn.transfer(from: card.id, to: card.id, amountMinor: 100, currency: "UAH", date: Date())]).apply(to: &data))
        XCTAssertThrowsError(try Mutation.addTransactions([Txn.transfer(from: card.id, to: UUID(), amountMinor: 100, currency: "UAH", date: Date())]).apply(to: &data))
        var t = Txn(kind: .transfer, amountMinor: 100, currency: "UAH", categoryID: Txn.noCategory, walletID: card.id, date: Date())
        XCTAssertThrowsError(try Mutation.addTransactions([t]).apply(to: &data)) // no destination
        t.toWalletID = cash.id
        XCTAssertNoThrow(try Mutation.addTransactions([t]).apply(to: &data))
    }

    func testDeleteWalletMovesTransferSides() throws {
        let atm = Txn.transfer(from: card.id, to: cash.id, amountMinor: 50_000, currency: "UAH", date: Date())
        try Mutation.addTransactions([atm]).apply(to: &data)
        // Moving cash into card would make a card→card transfer: it is dropped.
        try Mutation.deleteWallet(id: cash.id, moveTo: card.id).apply(to: &data)
        XCTAssertTrue(data.transactions.isEmpty)
        XCTAssertNil(data.wallet(cash.id))
    }

    func testOldDataDecodes() throws {
        // A transaction as saved by version 0.1.0 (no transfer fields).
        let json = """
        {"amountMinor":85000,"categoryID":"\(data.categoryNamed("Продукты")!.id.uuidString)","createdAt":"1763550000.5","currency":"UAH",
         "date":"1763550000","id":"\(UUID().uuidString)","kind":"expense","note":"","source":"manual","walletID":"\(card.id.uuidString)"}
        """
        let t = try FileStore.decoder().decode(Txn.self, from: Data(json.utf8))
        XCTAssertEqual(t.kind, .expense)
        XCTAssertNil(t.toWalletID)
        XCTAssertEqual(t.amountMinor, 85000)
    }

    func testCSVRoundTripWithTransfers() throws {
        try Mutation.addTransactions([
            Txn.transfer(from: card.id, to: cash.id, amountMinor: 200_000, currency: "UAH", date: date("2026-11-02 10:00"), note: "банкомат"),
            Txn.transfer(from: card.id, to: usd.id, amountMinor: 420_000, currency: "UAH", toAmountMinor: 10_000, toCurrency: "USD", date: date("2026-11-03 10:00"))
        ]).apply(to: &data)
        let csv = CSVExchange.export(data, timeZone: cal.timeZone)
        var fresh = Defaults.makeInitialData(language: .ru)
        let plan = CSVExchange.plan(csv: csv, into: fresh, timeZone: cal.timeZone)
        XCTAssertTrue(plan.errors.isEmpty, "\(plan.errors)")
        XCTAssertEqual(plan.pairedTransfers, 2)
        XCTAssertEqual(plan.newWallets.map { $0.name }, ["Доллары"])
        try plan.mutation.apply(to: &fresh)
        XCTAssertEqual(fresh.balance(of: fresh.walletNamed("Доллары")!), 10_000)
        XCTAssertEqual(fresh.balance(of: fresh.walletNamed("Наличные")!), 200_000)
        XCTAssertEqual(CSVExchange.plan(csv: csv, into: fresh, timeZone: cal.timeZone).duplicates, 2)
    }

    func testSpendeeTransferPairs() throws {
        let csv = """
        Date,Wallet,Type,"Category name",Amount,Currency,Note,Labels,Author
        2026-10-06 10:00:00,Main Wallet,Outgoing Transfer,,-500.00000000,UAH,ATM,,T
        2026-10-06 10:00:00,Cash,Incoming Transfer,,500.00000000,UAH,ATM,,T
        2026-10-07 11:00:00,Main Wallet,Outgoing Transfer,,-4150.00000000,UAH,,,T
        2026-10-07 11:00:00,Dollars,Incoming Transfer,,100.00000000,USD,,,T
        2026-10-08 12:00:00,Main Wallet,Outgoing Transfer,,-300.00000000,UAH,to mom,,T
        2026-10-09 09:00:00,Main Wallet,Expense,Food & Drink,-125.50000000,UAH,,,T
        2026-10-09 09:30:00,Main Wallet,Income,Salary,30000.00000000,UAH,,,T
        """
        let plan = CSVExchange.plan(csv: csv, into: data, timeZone: cal.timeZone)
        XCTAssertTrue(plan.errors.isEmpty)
        XCTAssertEqual(plan.rowCount, 7)
        XCTAssertEqual(plan.pairedTransfers, 2)
        XCTAssertEqual(plan.unpairedTransfers, 1)
        // 2 merged transfers + 1 unpaired half + expense + income
        XCTAssertEqual(plan.transactions.count, 5)
        let fx = plan.transactions.first { $0.isTransfer && $0.creditedCurrency == "USD" }!
        XCTAssertEqual(fx.amountMinor, 415_000)
        XCTAssertEqual(fx.creditedMinor, 10_000)
        // Reconciliation: income/expense in the plan equals the file (transfers excluded).
        XCTAssertEqual(plan.sourceTotals, plan.plannedTotals)
        XCTAssertEqual(plan.sourceTotals.expense["UAH"], 12_550)
        XCTAssertEqual(plan.sourceTotals.income["UAH"], 3_000_000)
        var d = data!
        try plan.mutation.apply(to: &d)
        let all = Analytics.totals(d.transactions, data: d)
        XCTAssertEqual(all.income, 3_000_000)
        XCTAssertEqual(all.expense, 12_550 + 30_000) // the unpaired outgoing half stays an expense
    }

    func testAssistantTransfer() {
        let host = TestHost(data)
        let engine = AssistantEngine(transport: MockTransport(), host: host.host, calendar: cal)
        var ev: [AssistantEvent] = []
        let r = engine.execute("add_transfer", JSON.parse(#"{"from_wallet":"Карта","to_wallet":"Наличные","amount":"2000"}"#)!, events: &ev)
        XCTAssertEqual(r["status"], "done")
        XCTAssertEqual(host.data.balance(of: cash), 200_000)
        XCTAssertEqual(Analytics.totals(host.data.transactions, data: host.data).expense, 0)
        // Cross-currency without to_amount converts at the app rate.
        let r2 = engine.execute("add_transfer", JSON.parse(#"{"from_wallet":"Карта","to_wallet":"Доллары","amount":"4150"}"#)!, events: &ev)
        XCTAssertEqual(r2["status"], "done")
        XCTAssertEqual(host.data.balance(of: usd), 10_000)
        // find by wallet sees the transfer; kind filter works.
        let found = engine.execute("find_transactions", JSON.parse(#"{"kind":"transfer","wallet":"Наличные"}"#)!, events: &ev)
        XCTAssertEqual(found["items"]?.array?.count, 1)
        XCTAssertEqual(found["items"]?.array?.first?["to_wallet"], "Наличные")
        // Redirect the transfer to another wallet.
        let id = found["items"]!.array![0]["id"]!.string!
        let upd = engine.execute("update_transactions", .object(["ids": .array([.string(id)]), "to_wallet": "Доллары"]), events: &ev)
        XCTAssertEqual(upd["status"], "done")
        XCTAssertEqual(host.data.balance(of: cash), 0)
        XCTAssertEqual(engine.execute("add_transfer", JSON.parse(#"{"from_wallet":"Карта","to_wallet":"Карта","amount":"1"}"#)!, events: &ev)["status"], "error")
    }
}
