import XCTest
@testable import GroshiCore

/// Replays real OpenAI replies (recorded by scripts/ai-live/harness.mjs against the app's exact
/// tools and prompt) through the Swift engine and checks the same expectations as the live run:
/// dates asked for, 5/10/20/30 operations in one command, voice corrections, confirmation, undo.
final class LiveReplayTests: XCTestCase {
    final class ReplayTransport: LLMTransport {
        var queue: [ChatMessage] = []
        var used = 0
        func complete(messages: [ChatMessage], tools: [JSON]) async throws -> ChatMessage {
            guard !queue.isEmpty else { throw NSError(domain: "replay", code: 1, userInfo: [NSLocalizedDescriptionKey: "recording exhausted"]) }
            used += 1
            return queue.removeFirst()
        }
    }

    struct Expect: Decodable { var saved: Int?; var pending: Int?; var asks: Bool? }
    struct Turn: Decodable { var user: String?; var button: String?; var responses: [ChatMessage]?; var expect: Expect? }
    struct Recording: Decodable { var name: String; var turns: [Turn]; var expectTxs: [String]? }
    struct File: Decodable { var model: String; var recordings: [Recording] }

    func testRealModelRepliesThroughSwiftEngine() async throws {
        let file = try JSONDecoder().decode(File.self, from: Data(LiveRecordings.json.utf8))
        XCTAssertGreaterThanOrEqual(file.recordings.count, 12)
        let cal = SpendeeFixture.calendar
        let ymd = DateFormatter.ymd(cal)
        for rec in file.recordings {
            let host = TestHost(SpendeeFixture.make())
            let transport = ReplayTransport()
            let engine = AssistantEngine(transport: transport, host: host.host, calendar: cal, now: { SpendeeFixture.now })
            for turn in rec.turns {
                if turn.button == "confirm" {
                    _ = try engine.confirmPending()
                    continue
                }
                guard let user = turn.user, let responses = turn.responses else { continue }
                transport.queue = responses
                let r = try await engine.send(user)
                XCTAssertTrue(transport.queue.isEmpty, "[\(rec.name)] engine stopped early on \"\(user)\"")
                let e = turn.expect
                if let s = e?.saved { XCTAssertEqual(host.data.transactions.count, s, "[\(rec.name)] saved after \"\(user)\"") }
                if let p = e?.pending { XCTAssertEqual(engine.pending?.transactions.count ?? 0, p, "[\(rec.name)] pending after \"\(user)\"") }
                if e?.asks == true {
                    XCTAssertFalse(r.events.contains { if case .saved = $0 { return true }; return false }, "[\(rec.name)] should ask, not save")
                    XCTAssertFalse(r.reply.isEmpty)
                }
            }
            guard let expected = rec.expectTxs else { continue }
            var left = host.data.transactions.map { t -> (String, TxKind, Int64, String) in
                (ymd.string(from: t.date), t.kind, t.amountMinor, host.data.category(t.categoryID)?.name ?? "?")
            }
            for e in expected {
                let p = e.split(separator: "|").map(String.init)
                let minor = Int64((Double(p[2]) ?? 0) * 100)
                let cats = p[3].split(separator: "/").map(String.init)
                if let i = left.firstIndex(where: { $0.0 == p[0] && $0.1.rawValue == p[1] && $0.2 == minor && cats.contains($0.3) }) {
                    left.remove(at: i)
                } else {
                    XCTFail("[\(rec.name)] missing \(e)")
                }
            }
            XCTAssertTrue(left.isEmpty, "[\(rec.name)] unexpected: \(left)")
        }
    }
}
