import SwiftUI
import Observation
import GroshiCore

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var canUndo: Bool
    var isError = false
}

/// Single source of truth. Every change is a `Mutation`, saved to disk immediately and undoable.
@MainActor
@Observable
final class Store {
    private(set) var data: AppData
    private(set) var undoStack: [(label: String, data: AppData)] = []
    var toast: Toast?
    var startupNotice: String?
    let fileStore: FileStore
    let iconsDirectory: URL

    // UI state shared between tabs
    var period: Period
    var selectedTab: AppTab = .home

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Groshi", isDirectory: true)
        // Exclude nothing from iCloud/iTunes backup: the data must survive device restores.
        fileStore = FileStore(directory: base)
        iconsDirectory = base.appendingPathComponent("Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)

        let isUITest = ProcessInfo.processInfo.arguments.contains("-uiTestReset")
        if isUITest { try? FileManager.default.removeItem(at: fileStore.dataURL) }

        var loaded: AppData
        var notice: String?
        var fresh = false
        switch fileStore.load() {
        case .loaded(let d):
            loaded = d
        case .recoveredFromSnapshot(let d, let url):
            loaded = d
            notice = "Основной файл данных был повреждён — восстановлено из копии \(url.lastPathComponent)."
        case .empty:
            loaded = Defaults.makeInitialData(language: Lang.deviceLanguage)
            fresh = true
        }
        let cal = Period.calendar(firstWeekday: loaded.settings.firstWeekday)
        Lang.current = loaded.settings.language
        data = loaded
        startupNotice = notice
        period = Period.containing(Date(), kind: .month, calendar: cal)
        if fresh { persist() }
    }

    var calendar: Calendar { Period.calendar(firstWeekday: data.settings.firstWeekday) }

    // MARK: Changes

    /// Applies a change, saves, and records undo. Throws on validation errors.
    func apply(_ m: Mutation, label: String, undoable: Bool = true) throws {
        var copy = data
        try m.apply(to: &copy)
        if undoable {
            undoStack.append((label, data))
            if undoStack.count > 40 { undoStack.removeFirst(undoStack.count - 40) }
        }
        withAnimation(.snappy) { data = copy }
        Lang.current = data.settings.language
        persist()
    }

    /// UI helper: apply and show a toast (with Undo) or an error.
    @discardableResult
    func perform(_ m: Mutation, label: String, toast showToast: Bool = true) -> Bool {
        do {
            try apply(m, label: label)
            if showToast { show(label, canUndo: true) }
            Haptics.success(enabled: data.settings.haptics)
            return true
        } catch {
            show(L("Не удалось: ") + Self.describe(error), canUndo: false, isError: true)
            Haptics.error(enabled: data.settings.haptics)
            return false
        }
    }

    @discardableResult
    func undo() -> String? {
        guard let last = undoStack.popLast() else { return nil }
        withAnimation(.snappy) { data = last.data }
        Lang.current = data.settings.language
        persist()
        return last.label
    }

    func undoWithToast() {
        if let l = undo() { show(L("Отменено: ") + l, canUndo: false) }
    }

    func show(_ text: String, canUndo: Bool, isError: Bool = false) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { toast = Toast(text: text, canUndo: canUndo, isError: isError) }
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var s = data.settings
        change(&s)
        try? apply(.updateSettings(s), label: L("Настройки"), undoable: false)
    }

    private func persist() {
        do { try fileStore.save(data) } catch {
            show(L("Ошибка сохранения: ") + error.localizedDescription, canUndo: false, isError: true)
        }
    }

    static func describe(_ error: Error) -> String {
        if let m = error as? MutationError {
            switch m {
            case .conflict(let s): return s.hasPrefix("category exists") ? L("такая категория уже есть") : (s.hasPrefix("wallet exists") ? L("такой кошелёк уже есть") : s)
            case .invalid(let s): return s
            case .notFound(let s): return L("не найдено: ") + s
            }
        }
        return error.localizedDescription
    }

    // MARK: Icons

    func iconURL(_ name: String) -> URL { iconsDirectory.appendingPathComponent(name) }

    func saveIcon(_ image: UIImage) -> String? {
        let size = CGSize(width: 120, height: 120)
        let renderer = UIGraphicsImageRenderer(size: size)
        let scaled = renderer.image { _ in
            let s = image.size
            let scale = max(size.width / s.width, size.height / s.height)
            let w = s.width * scale, h = s.height * scale
            image.draw(in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        }
        guard let png = scaled.pngData() else { return nil }
        let name = "icon-\(UUID().uuidString).png"
        do { try png.write(to: iconURL(name), options: .atomic); return name } catch { return nil }
    }

    // MARK: Backup

    func makeBackup() throws -> URL {
        var icons: [String: String] = [:]
        for c in data.categories {
            if case .image(let n) = c.icon, let d = try? Data(contentsOf: iconURL(n)) { icons[n] = d.base64EncodedString() }
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HHmm"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Groshi-backup-\(f.string(from: Date())).json")
        try BackupFile(data: data, icons: icons).encoded().write(to: url, options: .atomic)
        return url
    }

    func restore(_ backup: BackupFile) throws {
        for (name, b64) in backup.icons {
            if let d = Data(base64Encoded: b64) { try? d.write(to: iconURL(name), options: .atomic) }
        }
        try apply(.replaceAll(backup.data), label: L("Восстановление из копии"))
    }

    func exportCSV(_ txs: [Txn]? = nil) throws -> URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Groshi-\(f.string(from: Date())).csv")
        try CSVExchange.export(data, transactions: txs).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

enum AppTab: Hashable { case home, overview, assistant, more }
