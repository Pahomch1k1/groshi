import Foundation

/// The text dictated for the AI but not sent yet. It lives on disk, so it survives switching to
/// another app, iOS stopping the microphone in the background, closing the panel and a restart.
/// New dictation is appended, never replaces it. Only "Отправить" (after a successful save) or an
/// explicit delete clears it.
public struct VoiceDraft: Codable, Equatable {
    public var text: String
    /// One id per submission: a repeated send of the same draft never saves its operations twice.
    public var requestID: String
    public var updatedAt: Date

    public init(text: String = "", requestID: String = UUID().uuidString, updatedAt: Date = Date()) {
        self.text = text; self.requestID = requestID; self.updatedAt = updatedAt
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// `base` followed by newly dictated `addition`: "…320 грн" + "15 ноября кофе…" → "…320 грн, 15 ноября кофе…".
    public static func joined(_ base: String, _ addition: String) -> String {
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = tidy(addition)
        if b.isEmpty { return a }
        if a.isEmpty { return b }
        if let last = b.last, ".,;:!?".contains(last) { return b + " " + a }
        return b + ", " + a
    }

    /// Shortens spoken currency after a number ("850 гривен" → "850 грн") and trims spaces.
    public static func tidy(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return out }
        let pattern = #"(\d)\s*(?:гривен|гривень|гривнями|гривнях|гривны|гривні|гривна|гривня|гривну|гривни)(?=[\s.,;:!?]|$)"#
        if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1 грн")
        }
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out
    }
}

/// One small JSON file next to the app data, written atomically on every change.
public final class VoiceDraftStore {
    public let url: URL

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("voice-draft.json")
    }

    public func load() -> VoiceDraft? {
        guard let d = try? Data(contentsOf: url), let draft = try? FileStore.decoder().decode(VoiceDraft.self, from: d),
              !draft.isEmpty else { return nil }
        return draft
    }

    public func save(_ draft: VoiceDraft?) throws {
        guard let draft, !draft.isEmpty else { clear(); return }
        try FileStore.encoder().encode(draft).write(to: url, options: [.atomic])
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }
}
