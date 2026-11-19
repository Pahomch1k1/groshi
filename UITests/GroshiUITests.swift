import XCTest

final class GroshiUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_UA"]
    }

    /// Screenshots go to the host filesystem (simulator shares it) so CI can upload them.
    func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] ?? "/tmp/groshi-shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    func addExpense(_ digits: String, category: String, note: String? = nil) {
        app.buttons["add-button"].tap()
        XCTAssertTrue(app.buttons["save-button"].waitForExistence(timeout: 5))
        for ch in digits { app.buttons["key-\(ch)"].tap() }
        app.buttons["category-\(category)"].tap()
        if let note {
            let f = app.textFields["note-field"]
            f.tap(); f.typeText(note)
            app.toolbars.buttons["Готово"].firstMatch.tap()
        }
        app.buttons["save-button"].tap()
    }

    func testManualAddEditDeleteAndPersistence() {
        app.launch()
        XCTAssertTrue(app.buttons["add-button"].waitForExistence(timeout: 10))
        shot("01-home-empty")

        addExpense("850", category: "Кафе и рестораны")
        XCTAssertTrue(app.descendants(matching: .any)["tx-row"].firstMatch.waitForExistence(timeout: 5))
        addExpense("1200", category: "Бензин", note: "Окко")
        // Income via the type switch
        app.buttons["add-button"].tap()
        XCTAssertTrue(app.buttons["save-button"].waitForExistence(timeout: 5))
        app.segmentedControls["kind-picker"].buttons["Доход"].tap()
        for ch in "15000" { app.buttons["key-\(ch)"].tap() }
        app.buttons["category-Бизнес"].tap()
        shot("02-add-form")
        app.buttons["save-button"].tap()

        let rows = app.descendants(matching: .any).matching(identifier: "tx-row")
        XCTAssertTrue(rows.element(boundBy: 2).waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 3)
        // Totals: income 15 000, expense 2 050, net +12 950
        let expense = app.staticTexts["cashflow-expense"].label
        XCTAssertTrue(expense.replacingOccurrences(of: "\u{202F}", with: " ").contains("2 050"), expense)
        let net = app.staticTexts["cashflow-net"].label
        XCTAssertTrue(net.replacingOccurrences(of: "\u{202F}", with: " ").contains("12 950"), net)
        shot("03-home-with-data")

        // Relaunch without reset: data must survive.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_UA"]
        again.launch()
        let rows2 = again.descendants(matching: .any).matching(identifier: "tx-row")
        XCTAssertTrue(rows2.element(boundBy: 2).waitForExistence(timeout: 10))
        XCTAssertEqual(rows2.count, 3)

        // Open detail → delete
        rows2.element(boundBy: 0).tap()
        XCTAssertTrue(again.buttons["detail-delete"].waitForExistence(timeout: 5))
        shot("04-detail")
        again.buttons["detail-delete"].tap()
        again.sheets.buttons["Удалить"].firstMatch.tap()
        XCTAssertTrue(waitFor { rows2.count == 2 })
        // Undo from toast
        if again.buttons["toast-undo"].waitForExistence(timeout: 3) {
            again.buttons["toast-undo"].tap()
            XCTAssertTrue(waitFor { rows2.count == 3 })
        }
    }

    func testOverviewCategoriesWalletsAndAssistant() {
        app.launch()
        XCTAssertTrue(app.buttons["add-button"].waitForExistence(timeout: 10))
        addExpense("300", category: "Продукты")
        addExpense("700", category: "Одежда")

        app.buttons["tab-overview"].tap()
        XCTAssertTrue(app.staticTexts["overview-total"].waitForExistence(timeout: 5))
        let totalLabel = app.staticTexts["overview-total"].label.replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertTrue(totalLabel.contains("1 000"), totalLabel)
        sleep(1)
        shot("05-overview")
        app.descendants(matching: .any).matching(identifier: "share-row").firstMatch.tap()
        sleep(1)
        shot("06-category-transactions")
        app.navigationBars.buttons.firstMatch.tap()

        // Create a category
        app.buttons["tab-more"].tap()
        shot("07-more")
        app.buttons["more-categories"].tap()
        app.buttons["add-category"].tap()
        let name = app.textFields["category-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Кальян")
        shot("08-category-editor")
        app.buttons["category-save"].tap()
        XCTAssertTrue(app.buttons["Кальян"].waitForExistence(timeout: 5) || app.staticTexts["Кальян"].waitForExistence(timeout: 2))
        app.navigationBars.buttons.firstMatch.tap()

        // Create a wallet
        app.buttons["more-wallets"].tap()
        app.buttons["add-wallet"].tap()
        let wname = app.textFields["wallet-name"]
        XCTAssertTrue(wname.waitForExistence(timeout: 5))
        wname.tap(); wname.typeText("Сейф")
        app.buttons["wallet-save"].tap()
        XCTAssertTrue(app.staticTexts["Сейф"].waitForExistence(timeout: 5))
        shot("09-wallets")
        app.navigationBars.buttons.firstMatch.tap()

        // Assistant tab renders (no key in CI → banner)
        app.buttons["tab-assistant"].tap()
        XCTAssertTrue(app.textFields["assistant-input"].waitForExistence(timeout: 5) || app.textViews["assistant-input"].waitForExistence(timeout: 2))
        shot("10-assistant")

        // Dark theme screenshot of home
        app.buttons["tab-home"].tap()
        sleep(1)
        shot("11-home-final")
    }

    func waitFor(timeout: TimeInterval = 5, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return cond()
    }
}
