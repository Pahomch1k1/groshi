import Foundation
import Security
import Speech
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

    static func get(account: String = "apiKey") -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(decoding: d, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    static var hasKey: Bool { get() != nil }
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
        let key = Keychain.get()
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
@MainActor
@Observable
final class SpeechRecognizer {
    var transcript = ""
    var isRecording = false
    var level: Float = 0
    var error: String?

    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start(locale: String) async {
        error = nil
        transcript = ""
        let speechOK: Bool = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speechOK else { error = L("Нет доступа к распознаванию речи. Разрешите в Настройках iOS."); return }
        guard await AVAudioApplication.requestRecordPermission() else { error = L("Нет доступа к микрофону. Разрешите в Настройках iOS."); return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            error = L("Распознавание недоступно для языка ") + locale; return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = false }
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
            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if err != nil || (result?.isFinal ?? false) { self.finish() }
                }
            }
        } catch {
            self.error = error.localizedDescription
            finish()
        }
    }

    func stop() {
        request?.endAudio()
        // Give the recognizer a moment to deliver the final result.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            self.finish()
        }
    }

    private func finish() {
        guard isRecording || audio.isRunning else { return }
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
