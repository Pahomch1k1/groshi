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

    /// Two buttons; one tap on AI starts recording; pauses don't stop it; "Готово" sends; the seven
    /// operations are saved at once; "Исправить" opens them for editing; "Отменить" removes the whole command.
    func testVoiceCommandSavesAtOnceFixAndUndo() {
        app.launchArguments += ["-uiTestAI"]
        app.launch()
        let add = app.buttons["add-button"], aiButton = app.buttons["ai-button"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(aiButton.exists, "two separate floating buttons")
        XCTAssertGreaterThan(aiButton.frame.minY, add.frame.maxY, "AI button is below +")
        shot("12-two-buttons")

        // Cancel: nothing is sent.
        aiButton.tap()
        XCTAssertTrue(app.buttons["voice-cancel"].waitForExistence(timeout: 5))
        app.buttons["voice-cancel"].tap()
        XCTAssertTrue(waitFor { !self.app.buttons["voice-stop"].exists })
        XCTAssertTrue(aiButton.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 0)

        // Record with a long pause: still recording after 5 s.
        aiButton.tap()
        let stop = app.buttons["voice-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["voice-timer"].exists)
        sleep(5)
        XCTAssertTrue(stop.exists, "a pause does not end the recording")
        shot("13-voice-recording")
        stop.tap()
        let title = app.staticTexts["saved-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(title.label.contains("7"), title.label)
        XCTAssertFalse(app.buttons["pending-confirm"].exists, "no confirmation step")
        XCTAssertTrue(waitFor { self.rows.count >= 7 }, "rows: \(rows.count)")
        sleep(1)
        shot("14-voice-saved")

        // Fix: rows become editable.
        app.buttons["saved-fix"].tap()
        let savedRows = app.buttons.matching(identifier: "saved-row")
        XCTAssertTrue(waitFor { savedRows.count == 7 }, "saved rows: \(savedRows.count)")
        shot("15-voice-fix")
        savedRows.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["save-button"].waitForExistence(timeout: 5), "manual edit opens")
        app.buttons["add-close"].tap()

        // Undo removes the whole command.
        XCTAssertTrue(app.buttons["saved-undo"].waitForExistence(timeout: 5))
        app.buttons["saved-undo"].tap()
        XCTAssertTrue(waitFor { self.rows.count == 0 }, "rows after undo: \(rows.count)")
    }

    /// Press and hold a category, drag it to another place; the order is shared and survives a restart.
    func testCategoryDragReorderPersists() {
        app.launch()
        let add = app.buttons["add-button"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let food = app.buttons["category-Продукты"], transport = app.buttons["category-Транспорт"]
        XCTAssertTrue(food.waitForExistence(timeout: 5))
        XCTAssertLessThan(food.frame.minX, transport.frame.minX)
        food.press(forDuration: 0.8, thenDragTo: transport)
        sleep(1)
        XCTAssertGreaterThan(food.frame.minX, transport.frame.minX, "Продукты moved after Транспорт")
        shot("16-category-dragged")
        app.buttons["add-close"].tap()

        // Same order in More → Categories.
        app.descendants(matching: .any)["tab-more"].tap()
        app.buttons["more-categories"].tap()
        let food2 = app.buttons["category-Продукты"], transport2 = app.buttons["category-Транспорт"]
        XCTAssertTrue(food2.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(food2.frame.minX, transport2.frame.minX)
        shot("17-categories-order")

        // Restart without resetting the data.
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_UA"]
        app.launch()
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(food.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(food.frame.minX, transport.frame.minX, "order survives a restart")
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
