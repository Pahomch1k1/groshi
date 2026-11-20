import XCTest

final class GroshiUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_UA"]
    }

    /// Screenshots go to the host filesystem (the simulator shares it) so CI can upload them.
    func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] ?? "/tmp/groshi-shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    func type(_ digits: String) { for ch in digits { app.buttons["key-\(ch)"].tap() } }

    func addExpense(_ digits: String, category: String, shotName: String? = nil) {
        app.buttons["add-button"].tap()
        XCTAssertTrue(app.buttons["category-\(category)"].waitForExistence(timeout: 5))
        app.buttons["category-\(category)"].tap()
        XCTAssertTrue(app.buttons["save-button"].waitForExistence(timeout: 5))
        type(digits)
        if let shotName { shot(shotName) }
        app.buttons["save-button"].tap()
        XCTAssertTrue(waitFor { !self.app.buttons["save-button"].exists })
    }

    var rows: XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "tx-row") }

    func label(_ id: String) -> String { app.staticTexts[id].label.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ") }

    func testEntryFlowCalculatorTransferAndPersistence() {
        app.launch()
        XCTAssertTrue(app.buttons["add-button"].waitForExistence(timeout: 10))
        shot("01-home-empty")

        // Step 1: category grid.
        app.buttons["add-button"].tap()
        XCTAssertTrue(app.buttons["category-Кафе и рестораны"].waitForExistence(timeout: 5))
        sleep(1)
        shot("02-select-category")
        app.buttons["category-Кафе и рестораны"].tap()
        // Step 2: calculator — 1000 − 150 = 850.
        // The sheet may still be settling: tap again if the calculator did not open.
        if !app.buttons["save-button"].waitForExistence(timeout: 3) { app.buttons["category-Кафе и рестораны"].tap() }
        XCTAssertTrue(app.buttons["save-button"].waitForExistence(timeout: 5))
        type("1000"); app.buttons["key-−"].tap(); type("150")
        sleep(1)
        shot("03-calculator")
        XCTAssertTrue(app.staticTexts["amount-display"].label.replacingOccurrences(of: "\u{202F}", with: "").contains("850"))
        // Category menu keeps the amount.
        app.buttons["category-switch"].tap()
        sleep(1)
        shot("04-category-menu")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Бензин")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["amount-display"].label.replacingOccurrences(of: "\u{202F}", with: "").contains("850"))
        app.buttons["save-button"].tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))

        addExpense("1200", category: "Кафе и рестораны")
        // Income.
        app.buttons["add-button"].tap()
        XCTAssertTrue(app.buttons["kind-income"].waitForExistence(timeout: 5))
        app.buttons["kind-income"].tap()
        app.buttons["category-Бизнес"].tap()
        type("15000")
        app.buttons["save-button"].tap()
        // Transfer: listed, Cash Flow unchanged.
        app.buttons["add-button"].tap()
        XCTAssertTrue(app.buttons["kind-transfer"].waitForExistence(timeout: 5))
        app.buttons["kind-transfer"].tap()
        type("500")
        shot("05-transfer")
        app.buttons["save-button"].tap()

        XCTAssertTrue(waitFor { self.rows.count == 4 })
        XCTAssertTrue(label("cashflow-expense").contains("2 050"), label("cashflow-expense"))
        XCTAssertTrue(label("cashflow-net").contains("12 950"), label("cashflow-net"))
        sleep(1)
        shot("06-home-with-data")

        // Detail card.
        rows.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["detail-delete"].waitForExistence(timeout: 5))
        sleep(1)
        shot("07-transaction-detail")
        app.buttons["detail-delete"].tap()
        app.sheets.buttons["Удалить"].firstMatch.tap()
        XCTAssertTrue(waitFor { self.rows.count == 3 })
        if app.buttons["toast-undo"].waitForExistence(timeout: 3) {
            app.buttons["toast-undo"].tap()
            XCTAssertTrue(waitFor { self.rows.count == 4 })
        }

        // Relaunch without reset: data survives.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_UA"]
        again.launch()
        let rows2 = again.descendants(matching: .any).matching(identifier: "tx-row")
        XCTAssertTrue(rows2.element(boundBy: 3).waitForExistence(timeout: 10))
        XCTAssertEqual(rows2.count, 4)
    }

    /// The tab bar and the content must not move vertically while switching tabs, even rapidly.
    func testTabSwitchingDoesNotJump() {
        app.launch()
        XCTAssertTrue(app.buttons["add-button"].waitForExistence(timeout: 10))
        addExpense("300", category: "Продукты")
        let any = app.descendants(matching: .any)
        let home = any["tab-home"], overview = any["tab-overview"], more = any["tab-more"]
        let search = app.textFields["search-field"]
        let bar0 = home.frame, search0 = search.frame
        var maxBarShift: CGFloat = 0, maxSearchShift: CGFloat = 0
        for i in 0..<6 {
            (i % 2 == 0 ? overview : more).tap()
            maxBarShift = max(maxBarShift, abs(home.frame.minY - bar0.minY))
            if i == 0 { shot("08-overview") }
            if i == 1 { shot("09-more") }
            home.tap()
            // Sample during the cross-fade and after it.
            maxBarShift = max(maxBarShift, abs(home.frame.minY - bar0.minY))
            maxSearchShift = max(maxSearchShift, abs(search.frame.minY - search0.minY))
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            maxBarShift = max(maxBarShift, abs(home.frame.minY - bar0.minY))
            maxSearchShift = max(maxSearchShift, abs(search.frame.minY - search0.minY))
        }
        XCTAssertLessThan(maxBarShift, 0.5, "tab bar moved by \(maxBarShift) pt")
        XCTAssertLessThan(maxSearchShift, 0.5, "home content moved by \(maxSearchShift) pt")

        // Overview total and More screens.
        overview.tap()
        XCTAssertTrue(app.staticTexts["overview-total"].waitForExistence(timeout: 5))
        XCTAssertTrue(label("overview-total").contains("300"), label("overview-total"))

        more.tap()
        app.buttons["more-categories"].tap()
        sleep(1)
        shot("10-categories")
        app.buttons["add-category"].tap()
        let name = app.textFields["category-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Кальян")
        sleep(1)
        shot("11-create-category")
        app.buttons["category-save"].tap()
        let hookah = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Кальян")).firstMatch
        XCTAssertTrue(hookah.waitForExistence(timeout: 5))
    }

    /// Assistant UI with a scripted model reply: seven recognised operations → one draft card → one tap saves all → undo.
    func testAssistantDraftSavesAllAtOnce() {
        app.launchArguments += ["-uiTestAI"]
        app.launch()
        let add = app.buttons["add-button"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.press(forDuration: 1.0) // long press opens the assistant
        let input = app.textViews["assistant-input"].exists ? app.textViews["assistant-input"] : app.textFields["assistant-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("За вчера тысяча на развлечения, 450 на пиццу, 300 продукты, 1500 бензин, 200 такси, сегодня 800 ресторан и зарплата 15 тысяч")
        app.buttons["assistant-send"].tap()
        let save = app.buttons["pending-confirm"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "draft-row").count, 7)
        XCTAssertTrue(save.label.contains("7"), save.label)
        sleep(1)
        shot("12-assistant-draft")
        save.tap()
        let undo = app.buttons["assistant-undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["pending-confirm"].exists, "the draft card disappears after saving")
        sleep(1)
        shot("13-assistant-saved")
        // All seven are in the app: Home lists them.
        app.buttons["Закрыть"].tap()
        let rows = app.descendants(matching: .any).matching(identifier: "tx-row")
        XCTAssertTrue(waitFor { rows.count >= 7 }, "rows: \(rows.count)")
        shot("14-home-after-voice")
        // One undo removes the whole batch.
        add.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["assistant-undo"].waitForExistence(timeout: 5))
        app.buttons["assistant-undo"].tap()
        app.buttons["Закрыть"].tap()
        XCTAssertTrue(waitFor { rows.count == 0 }, "rows after undo: \(rows.count)")
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
