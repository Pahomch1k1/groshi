import Foundation
import Security
import Speech
import VisionKit
import SwiftUI
import AVFoundation
import Observation
import GroshiCore

/// OpenAI key lives only in the iOS Keychain (encrypted, this device only, never in backups or the app bundle).
enum Keychain {
    static let service = "app.groshi.openai"

    static func set(_ value: String, account: String = "apiKey") {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(account: String = "apiKey") -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(decoding: d, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    static var hasKey: Bool { read() != nil }
}

struct AIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Chat Completions over HTTPS, directly or through an optional proxy that holds the key server-side.
final class OpenAITransport: LLMTransport {
    var settings: () -> AISettings

    init(settings: @escaping () -> AISettings) { self.settings = settings }

    struct Body: Encodable {
        var model: String
        var messages: [ChatMessage]
        var tools: [JSON]?
        var tool_choice: String?
    }
    struct Response: Decodable {
        struct Choice: Decodable { var message: ChatMessage }
        var choices: [Choice]
    }
    struct ErrorBody: Decodable { struct E: Decodable { var message: String }; var error: E }

    func complete(messages: [ChatMessage], tools: [JSON]) async throws -> ChatMessage {
        let s = settings()
        let key = Keychain.read()
        let useProxy = !s.proxyURL.trimmingCharacters(in: .whitespaces).isEmpty
        guard useProxy || key != nil else { throw AIError(message: L("Добавьте ключ OpenAI в «Ещё → AI-ассистент».")) }
        let url = URL(string: useProxy ? s.proxyURL : "https://api.openai.com/v1/chat/completions")!
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key {
            // For a proxy the stored value is the proxy's own access token, not the OpenAI key.
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(Body(model: s.model, messages: messages, tools: tools.isEmpty ? nil : tools,
                                                     tool_choice: tools.isEmpty ? nil : "auto"))
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data).error.message) ?? String(decoding: data.prefix(300), as: UTF8.self)
            switch code {
            case 401: throw AIError(message: L("Неверный ключ OpenAI (401)."))
            case 429: throw AIError(message: L("OpenAI: превышен лимит или закончился баланс (429). ") + msg)
            default: throw AIError(message: "OpenAI \(code): \(msg)")
            }
        }
        guard let m = try JSONDecoder().decode(Response.self, from: data).choices.first?.message else {
            throw AIError(message: L("Пустой ответ OpenAI"))
        }
        return m
    }
}

/// On-device/Apple speech recognition (uk-UA, ru-RU, en-US). Audio is not sent to OpenAI.
/// Stops by itself after a pause in speech, so a whole conversation can be held hands-free.
@MainActor
@Observable
final class SpeechRecognizer {
    var transcript = ""
    var isRecording = false
    var level: Float = 0
    var error: String?
    /// Seconds of silence after speech that end the recording.
    var silenceTimeout: Double = 1.6
    /// Called once per recording with the final text (empty if nothing was said).
    @ObservationIgnored var onFinish: ((String) -> Void)?

    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastChange = Date()
    private var startedAt = Date()
    private var watchdog: Task<Void, Never>?
    private var delivered = false

    func start(locale: String) async {
        guard !isRecording else { return }
        error = nil
        transcript = ""
        delivered = false
        let speechOK: Bool = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speechOK else { error = L("Нет доступа к распознаванию речи. Разрешите в Настройках iOS."); return }
        guard await AVAudioApplication.requestRecordPermission() else { error = L("Нет доступа к микрофону. Разрешите в Настройках iOS."); return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            error = L("Распознавание недоступно для языка ") + locale; return
        }
        do {
            try AudioSession.activate()
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.addsPunctuation = true
            request = req
            let input = audio.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                req.append(buffer)
                let n = Int(buffer.frameLength)
                guard n > 0, let ch = buffer.floatChannelData?[0] else { return }
                var sum: Float = 0
                for i in stride(from: 0, to: n, by: 8) { sum += abs(ch[i]) }
                let lvl = min(1, sum / Float(n / 8 + 1) * 12)
                Task { @MainActor in self?.level = lvl }
            }
            audio.prepare()
            try audio.start()
            isRecording = true
            startedAt = Date()
            lastChange = Date()
            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        if text != self.transcript { self.transcript = text; self.lastChange = Date() }
                    }
                    if err != nil || (result?.isFinal ?? false) { self.finish() }
                }
            }
            watchdog = Task { @MainActor [weak self] in
                while let self, self.isRecording, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    let quiet = Date().timeIntervalSince(self.lastChange)
                    let spoke = !self.transcript.trimmingCharacters(in: .whitespaces).isEmpty
                    // Pause after speech → done; nothing said for 8 s → give up.
                    if (spoke && quiet > self.silenceTimeout) || (!spoke && Date().timeIntervalSince(self.startedAt) > 8) {
                        self.stop()
                        return
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
            finish()
        }
    }

    /// Ends the recording; the final text arrives through `onFinish`.
    func stop() {
        guard isRecording else { return }
        request?.endAudio()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            self.finish()
        }
    }

    /// Stops without delivering anything (closing the screen, switching to typing).
    func cancel() {
        delivered = true
        finish()
    }

    private func finish() {
        watchdog?.cancel(); watchdog = nil
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        let wasRecording = isRecording
        isRecording = false
        level = 0
        if wasRecording && !delivered {
            delivered = true
            onFinish?(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// One audio session for listening and speaking, so the conversation can switch between them.
enum AudioSession {
    static func activate() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
        try s.setActive(true)
    }
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Reads the assistant's replies aloud with the system voice of the chosen language (offline, free).
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var done: (() -> Void)?
    private(set) var isSpeaking = false

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, locale: String, then: @escaping () -> Void) {
        stop()
        let clean = text.replacingOccurrences(of: "UAH", with: locale.hasPrefix("en") ? "hryvnias" : "гривень")
        guard !clean.trimmingCharacters(in: .whitespaces).isEmpty else { then(); return }
        try? AudioSession.activate()
        let u = AVSpeechUtterance(string: clean)
        u.voice = AVSpeechSynthesisVoice(language: locale)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        done = then
        isSpeaking = true
        synth.speak(u)
    }

    func stop() {
        done = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            let d = self.done
            self.done = nil
            d?()
        }
    }
}

/// Scans a QR code with the camera (used to move the OpenAI key from the computer screen
/// straight into the Keychain, without messengers or the clipboard).
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        var fired = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !fired else { return }
            for item in items {
                if case .barcode(let b) = item, let v = b.payloadStringValue {
                    fired = true
                    s.stopScanning()
                    onCode(v)
                    return
                }
            }
        }
    }
}

/// Stand-in for OpenAI in UI tests (launch argument -uiTestAI): answers with the same shape as the
/// real model did in the live tests — one add_transactions call with seven items, then a short question.
final class ScriptedTransport: LLMTransport {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-uiTestAI") }

    func complete(messages: [ChatMessage], tools: [JSON]) async throws -> ChatMessage {
        try await Task.sleep(for: .milliseconds(300))
        if messages.last?.role == "tool" { return .assistant("Распознал 7 операций, сохранить?") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        let yesterday = f.string(from: Date().addingTimeInterval(-86_400))
        let items: [(String, String, String, String)] = [
            ("expense", "1000", "Развлечения", yesterday), ("expense", "450", "Кафе и рестораны", yesterday),
            ("expense", "300", "Продукты", yesterday), ("expense", "1500", "Бензин", yesterday),
            ("expense", "200", "Транспорт", yesterday), ("expense", "800", "Кафе и рестораны", today),
            ("income", "15000", "Зарплата", today)
        ]
        let json = items.map { "{\"kind\":\"\($0.0)\",\"amount\":\"\($0.1)\",\"category\":\"\($0.2)\",\"date\":\"\($0.3)\"}" }.joined(separator: ",")
        return ChatMessage(role: "assistant", content: nil,
                           tool_calls: [ChatToolCall(id: "call_ui_\(messages.count)", name: "add_transactions", arguments: "{\"items\":[\(json)]}")])
    }
}
