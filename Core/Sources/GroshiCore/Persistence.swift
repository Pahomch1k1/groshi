import Foundation

/// Durable on-device storage: one JSON document written atomically, plus rolling daily snapshots.
/// Writes go to a temp file and are renamed into place, so a crash mid-write never corrupts data.
public final class FileStore {
    public let directory: URL
    public var dataURL: URL { directory.appendingPathComponent("groshi-data.json") }
    public var snapshotsURL: URL { directory.appendingPathComponent("Snapshots", isDirectory: true) }
    public var keepSnapshots = 14

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: snapshotsURL, withIntermediateDirectories: true)
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601withFraction
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601withFraction
        return d
    }

    public enum LoadResult {
        case loaded(AppData)
        case recoveredFromSnapshot(AppData, URL)
        case empty
    }

    public func load() -> LoadResult {
        if let data = try? Data(contentsOf: dataURL) {
            if let decoded = try? FileStore.decoder().decode(AppData.self, from: data) { return .loaded(decoded) }
            // Main file unreadable: keep it aside for diagnostics and fall back to the newest snapshot.
            let broken = directory.appendingPathComponent("groshi-data.broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: dataURL, to: broken)
        }
        for url in snapshotFiles().reversed() {
            if let d = try? Data(contentsOf: url), let decoded = try? FileStore.decoder().decode(AppData.self, from: d) {
                return .recoveredFromSnapshot(decoded, url)
            }
        }
        return .empty
    }

    public func save(_ appData: AppData) throws {
        let data = try FileStore.encoder().encode(appData)
        try data.write(to: dataURL, options: [.atomic])
        try snapshotIfNeeded(data)
    }

    /// One snapshot per day; older ones pruned.
    func snapshotIfNeeded(_ data: Data) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let url = snapshotsURL.appendingPathComponent("snapshot-\(f.string(from: Date())).json")
        try data.write(to: url, options: [.atomic])
        let files = snapshotFiles()
        if files.count > keepSnapshots {
            for old in files.prefix(files.count - keepSnapshots) { try? FileManager.default.removeItem(at: old) }
        }
    }

    public func snapshotFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: snapshotsURL, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("snapshot-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Full backup file: data plus custom icon images (base64), so a restore on a new phone is complete.
public struct BackupFile: Codable {
    public var format: String = "groshi-backup"
    public var formatVersion: Int = 1
    public var createdAt: Date
    public var data: AppData
    public var icons: [String: String] // file name -> base64 PNG

    public init(createdAt: Date = Date(), data: AppData, icons: [String: String]) {
        self.createdAt = createdAt; self.data = data; self.icons = icons
    }

    public func encoded() throws -> Data {
        let e = FileStore.encoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> BackupFile {
        let b = try FileStore.decoder().decode(BackupFile.self, from: data)
        guard b.format == "groshi-backup" else { throw CocoaErrorLike.wrongFormat }
        return b
    }

    public enum CocoaErrorLike: Error { case wrongFormat }
}

extension JSONEncoder.DateEncodingStrategy {
    static var iso8601withFraction: JSONEncoder.DateEncodingStrategy {
        // Seconds since 1970 as a string: Swift prints the shortest exact Double, so it round-trips, so saved data equals loaded data bit for bit.
        .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(String(date.timeIntervalSince1970))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static var iso8601withFraction: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n) }
            let raw = try c.decode(String.self)
            if let n = Double(raw) { return Date(timeIntervalSince1970: n) }
            let s = raw
            if let d = ISO8601.formatter.date(from: s) ?? ISO8601.plain.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
        }
    }
}

enum ISO8601 {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
