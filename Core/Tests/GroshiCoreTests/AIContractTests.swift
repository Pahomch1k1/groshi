import XCTest
@testable import GroshiCore

/// Synthetic data shaped like the owner's real setup after the Spendee import:
/// the Spendee category names (public catalog), one UAH wallet "Mono", a few labels. No real history.
enum SpendeeFixture {
    static let calendar = Period.calendar(firstWeekday: 2, timeZone: TimeZone(identifier: "Europe/Kyiv")!)

    static var now: Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "2026-11-20 10:00")!
    }

    static func make() -> AppData {
        var d = AppData()
        let entries = SpendeeCatalog.expense + SpendeeCatalog.income
        d.categories = entries.enumerated().map { i, e in
            Category(name: e.name, kind: e.kind, icon: .symbol(e.symbol), colorHex: e.color, sortOrder: i)
        }
        let mono = Wallet(name: "Mono", currency: "UAH")
        d.wallets = [mono]
        d.settings.defaultWalletID = mono.id
        d.labels = ["Work", "Family", "Trip"].enumerated().map { TxLabel(name: $0.element, sortOrder: $0.offset) }
        return d
    }
}

final class AIContractTests: XCTestCase {
    /// Writes the exact tools and system prompt the app sends, so the live OpenAI harness
    /// (scripts/ai-live) talks to the model with the same contract. Runs only when asked.
    func testExportContract() throws {
        let data = SpendeeFixture.make()
        let prompt = AssistantTools.systemPrompt(data: data, now: SpendeeFixture.now, calendar: SpendeeFixture.calendar, replyLanguage: "Russian")
        XCTAssertTrue(prompt.contains("Games"))
        guard let out = ProcessInfo.processInfo.environment["AI_CONTRACT_OUT"], !out.isEmpty else { return }
        let contract: JSON = ["tools": .array(AssistantTools.all), "system": .string(prompt)]
        try contract.serialized().write(toFile: out, atomically: true, encoding: .utf8)
    }
}
