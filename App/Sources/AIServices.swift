import Foundation
import Security
import Speech
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
        let body = try JSONEncoder().encode(Body(model: s.model, messages: messages, tools: tools.isEmpty ? nil : tools,
                                                 tool_choice: tools.isEmpty ? nil : "auto"))
        let proxy = s.proxyURL.trimmingCharacters(in: .whitespaces)
        if !proxy.isEmpty, let url = URL(string: proxy) {
            return try await post(url, token: Keychain.read(), body: body)
        }
        if let ownKey = Keychain.read() {
            // The owner deliberately entered their own key: talk to OpenAI directly.
            return try await post(URL(string: "https://api.openai.com/v1/chat/completions")!, token: ownKey, body: body)
        }
        // Default: the WorkFlow Spend server holds the OpenAI key; this phone has its own device token.
        let url = Gateway.base.appendingPathComponent("chat/completions")
        do {
            return try await post(url, token: try await Gateway.deviceToken(), body: body)
        } catch let e as HTTPFailure where e.code == 401 {
            Gateway.forgetToken() // revoked or lost on the server: register again once
            return try await post(url, token: try await Gateway.deviceToken(), body: body)
        }
    }

    struct HTTPFailure: LocalizedError {
        var code: Int
        var message: String
        var errorDescription: String? { message }
    }

    private func post(_ url: URL, token: String?, body: Data) async throws -> ChatMessage {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data).error.message) ?? String(decoding: data.prefix(300), as: UTF8.self)
            switch code {
            case 401: throw HTTPFailure(code: 401, message: L("Нет доступа к AI (401)."))
            case 429: throw HTTPFailure(code: 429, message: L("Достигнут лимит запросов к AI, попробуйте позже."))
            default: throw HTTPFailure(code: code, message: "AI \(code): \(msg)")
            }
        }
        guard let m = try JSONDecoder().decode(Response.self, from: data).choices.first?.message else {
            throw AIError(message: L("Пустой ответ OpenAI"))
        }
        return m
    }
}

/// The WorkFlow Spend AI server (Cloudflare Worker "workflow-spend-ai"): it keeps the OpenAI key,
/// the app only keeps a per-device token in the Keychain, obtained automatically on first use.
enum Gateway {
    static let base = URL(string: "https://workflow-spend-ai.espero-hotel-management.workers.dev/v1")!
    static let tokenAccount = "deviceToken"
    static let installAccount = "installId"

    static var hasToken: Bool { Keychain.read(account: tokenAccount) != nil }

    static func forgetToken() { Keychain.set("", account: tokenAccount) }

    static func deviceToken() async throws -> String {
        if let t = Keychain.read(account: tokenAccount) { return t }
        var install = Keychain.read(account: installAccount)
        if install == nil {
            install = UUID().uuidString
            Keychain.set(install!, account: installAccount)
        }
        var req = URLRequest(url: base.appendingPathComponent("register"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        req.httpBody = try JSONSerialization.data(withJSONObject: ["installId": install!, "appVersion": version])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 {
            throw AIError(message: L("Сервер AI не принимает новые устройства. Попросите открыть регистрацию для этого телефона."))
        }
        guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, token.hasPrefix("wfs_") else {
            throw AIError(message: L("Не удалось подключиться к серверу AI.") + " (\(code))")
        }
        Keychain.set(token, account: tokenAccount)
        return token
    }
}

/// On-device/Apple speech recognition (uk-UA, ru-RU, en-US). Audio is not sent to OpenAI.
/// Records until the user stops it — pauses never end the recording. A recognition task is limited
/// by iOS (about a minute when server-based), so long dictation is stitched from several segments.
@MainActor
@Observable
final class SpeechRecognizer {
    var transcript = "" { didSet { if transcript != oldValue { onTranscript?(transcript) } } }
    var isRecording = false
    /// Called on every change of the recognised text, so the draft on disk is always current.
    @ObservationIgnored var onTranscript: ((String) -> Void)?
    /// iOS took the microphone away (another app, a call, Telegram/the app went to the background).
    @ObservationIgnored var onInterrupted: (() -> Void)?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    var level: Float = 0
    var error: String?
    var startedAt = Date()

    private let audio = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private let requestBox = RequestBox()
    private var request: SFSpeechAudioBufferRecognitionRequest? {
        get { requestBox.get() }
        set { requestBox.set(newValue) }
    }
    private var task: SFSpeechRecognitionTask?
    /// Text of segments that already ended; `transcript` = committed + current segment.
    private var committed = ""
    private var current = ""
    private var stopping = false
    private var scripted: Task<Void, Never>?

    /// UI tests: no microphone on the simulator, the "speech" is typed in slowly — one phrase per
    /// recording, the first one not yet in the draft (so a dictation continued after switching apps
    /// adds the next phrase).
    static let scriptedPhrases = [
        "За вчера тысяча на развлечения, 450 на пиццу, 300 продукты",
        "1500 бензин, 200 такси",
        "сегодня 800 ресторан и зарплата 15 тысяч"
    ]
    static func scriptedText(after draft: String) -> String? {
        guard ScriptedTransport.isOn else { return nil }
        return scriptedPhrases.first { !draft.contains(VoiceDraft.tidy($0)) } ?? scriptedPhrases[0]
    }

    func start(locale: String, after draft: String = "") async {
        guard !isRecording else { return }
        error = nil
        transcript = ""; committed = ""; current = ""
        stopping = false
        if let text = Self.scriptedText(after: draft) {
            isRecording = true
            startedAt = Date()
            scripted = Task { @MainActor in
                for word in text.split(separator: " ") {
                    try? await Task.sleep(for: .milliseconds(60))
                    guard self.isRecording else { return }
                    self.transcript += (self.transcript.isEmpty ? "" : " ") + word
                    self.level = Float.random(in: 0.2...0.8)
                }
            }
            return
        }
        let speechOK: Bool = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speechOK else { error = L("Нет доступа к распознаванию речи. Разрешите в Настройках iOS."); return }
        guard await AVAudioApplication.requestRecordPermission() else { error = L("Нет доступа к микрофону. Разрешите в Настройках iOS."); return }
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: locale)), r.isAvailable else {
            error = L("Распознавание недоступно для языка ") + locale; return
        }
        recognizer = r
        do {
            try AudioSession.activate()
            let input = audio.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            let box = requestBox
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                box.append(buffer) // synchronous: the request is swapped between segments under a lock
                let n = Int(buffer.frameLength)
                guard n > 0, let ch = buffer.floatChannelData?[0] else { return }
                var sum: Float = 0
                for i in stride(from: 0, to: n, by: 8) { sum += abs(ch[i]) }
                let lvl = min(1, sum / Float(n / 8 + 1) * 12)
                Task { @MainActor in self?.level = lvl }
            }
            audio.prepare()
            try audio.start()
            observeInterruptions()
            isRecording = true
            startedAt = Date()
            startSegment()
        } catch {
            self.error = error.localizedDescription
            teardown()
        }
    }

    private func startSegment() {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        // On-device recognition has no one-minute limit and keeps audio on the phone.
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        current = ""
        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.current = result.bestTranscription.formattedString
                    self.transcript = [self.committed, self.current].filter { !$0.isEmpty }.joined(separator: " ")
                }
                if err != nil || (result?.isFinal ?? false) {
                    if self.isRecording && !self.stopping {
                        // The segment ended by itself (time limit, long silence): keep the text, continue.
                        self.committed = self.transcript
                        self.startSegment()
                    } else {
                        self.segmentFinished?()
                    }
                }
            }
        }
    }

    private var segmentFinished: (() -> Void)?

    /// Ends the recording and returns the full text.
    func stop() async -> String {
        guard isRecording else { return transcript }
        if scripted != nil {
            scripted?.cancel(); scripted = nil
            isRecording = false; level = 0
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        stopping = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var resumed = false
            let finish = { if !resumed { resumed = true; c.resume() } }
            segmentFinished = finish
            request?.endAudio()
            // Do not wait for the recognizer forever.
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(1500)); finish() }
        }
        segmentFinished = nil
        teardown()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops and throws the text away.
    func cancel() {
        scripted?.cancel(); scripted = nil
        stopping = true
        teardown()
        transcript = ""
    }

    /// The system stops the microphone when the app leaves the screen or a call comes in; the text
    /// heard so far is kept by the owner of the draft.
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.onInterrupted?()
            }
        }
    }

    private func teardown() {
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o); interruptionObserver = nil }
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        level = 0
        AudioSession.deactivate()
    }
}

/// The current recognition request, shared with the audio thread.
final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func get() -> SFSpeechAudioBufferRecognitionRequest? { lock.lock(); defer { lock.unlock() }; return request }
    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }
    func append(_ b: AVAudioPCMBuffer) { lock.lock(); let r = request; lock.unlock(); r?.append(b) }
}

enum AudioSession {
    static func activate() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try s.setActive(true, options: .notifyOthersOnDeactivation)
    }
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Stand-in for OpenAI in UI tests (launch argument -uiTestAI): answers with the same shape as the
/// real model did in the live tests — one add_transactions call with seven items, then a short question.
final class ScriptedTransport: LLMTransport {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-uiTestAI") }
    /// -uiTestAIOffline: the first request fails like a lost mobile connection (nothing is saved).
    private var failNext = ProcessInfo.processInfo.arguments.contains("-uiTestAIOffline")

    func complete(messages: [ChatMessage], tools: [JSON]) async throws -> ChatMessage {
        try await Task.sleep(for: .milliseconds(300))
        if failNext {
            failNext = false
            throw URLError(.notConnectedToInternet)
        }
        if messages.last?.role == "tool" { return .assistant("Сохранено 7 операций.") }
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

/// A little extra time from iOS to finish an AI request or to save the draft after the app leaves
/// the screen (switching to another app right after "Отправить" must not lose the answer).
@MainActor
final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        })
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
