import SwiftUI
import Observation
import GroshiCore

@MainActor
@Observable
final class AssistantViewModel {
    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant, applied, undone, pending, error }
        let id = UUID()
        var role: Role
        var text: String
        var pending: PendingAction?
        var resolved: String? = nil
    }

    var messages: [Message] = []
    var input = ""
    var busy = false
    var sheetVisible = false
    var context: String?
    var startVoiceOnOpen = false
    let speech = SpeechRecognizer()
    let store: Store
    @ObservationIgnored private var engine: AssistantEngine!

    init(store: Store) {
        self.store = store
        let transport = OpenAITransport(settings: { [unowned store] in store.data.settings.ai })
        let host = AssistantHost(
            data: { [unowned store] in store.data },
            apply: { [unowned store] m, label in try store.apply(m, label: label) },
            undo: { [unowned store] in store.undo() },
            isValidSymbol: { UIImage(systemName: $0) != nil })
        engine = AssistantEngine(transport: transport, host: host, calendar: store.calendar, replyLanguage: Lang.aiReplyLanguage)
    }

    var hasKey: Bool { Keychain.hasKey || !store.data.settings.ai.proxyURL.isEmpty }

    func prepare(context: String?, startVoice: Bool) {
        self.context = context
        self.startVoiceOnOpen = startVoice
    }

    func openSheet(context: String?, startVoice: Bool = false) {
        prepare(context: context, startVoice: startVoice)
        sheetVisible = true
    }

    func newChat() {
        engine.reset()
        withAnimation(.snappy) { messages = [] }
    }

    func send(_ textOverride: String? = nil) async {
        let text = (textOverride ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        input = ""
        withAnimation(.snappy) { messages.append(Message(role: .user, text: text)) }
        busy = true
        defer { busy = false }
        engine.calendar = store.calendar
        engine.replyLanguage = Lang.aiReplyLanguage
        var prompt = text
        if let c = context { prompt = "[Context: \(c)]\n" + text; context = nil }
        do {
            let r = try await engine.send(prompt)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                for e in r.events {
                    switch e {
                    case .applied(let s): messages.append(Message(role: .applied, text: s))
                    case .undone(let s): messages.append(Message(role: .undone, text: s))
                    case .pending(let p): messages.append(Message(role: .pending, text: p.summary, pending: p))
                    }
                }
                if !r.reply.isEmpty { messages.append(Message(role: .assistant, text: r.reply)) }
            }
            if r.events.contains(where: { if case .applied = $0 { return true }; return false }) {
                Haptics.success(enabled: store.data.settings.haptics)
            }
        } catch {
            withAnimation { messages.append(Message(role: .error, text: error.localizedDescription)) }
            Haptics.error(enabled: store.data.settings.haptics)
        }
    }

    func confirm(_ msg: Message) {
        guard let p = msg.pending, let i = messages.firstIndex(where: { $0.id == msg.id }) else { return }
        do {
            try store.apply(p.mutation, label: p.summary)
            withAnimation(.snappy) { messages[i].resolved = L("Выполнено") }
            Haptics.success(enabled: store.data.settings.haptics)
        } catch {
            withAnimation(.snappy) { messages[i].resolved = L("Ошибка: ") + Store.describe(error) }
        }
    }

    func cancel(_ msg: Message) {
        guard let i = messages.firstIndex(where: { $0.id == msg.id }) else { return }
        withAnimation(.snappy) { messages[i].resolved = L("Отменено") }
    }

    func undo(_ msg: Message) {
        guard let i = messages.firstIndex(where: { $0.id == msg.id }) else { return }
        if let l = store.undo() {
            withAnimation(.snappy) { messages[i].resolved = L("Отменено"); messages.append(Message(role: .undone, text: l)) }
        }
    }

    func toggleVoice() async {
        if speech.isRecording {
            speech.stop()
            try? await Task.sleep(for: .milliseconds(700))
            let t = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                if store.data.settings.ai.autoSendVoice { await send(t) } else { input = t }
            }
        } else {
            Haptics.tap(enabled: store.data.settings.haptics)
            await speech.start(locale: store.data.settings.ai.voiceLocale)
        }
    }
}

struct AssistantView: View {
    @Environment(Store.self) private var store
    @Environment(AssistantViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    var isSheet: Bool
    @FocusState private var focused: Bool

    static let examples = [
        "Сегодня потратил 850 гривен в ресторане",
        "Запиши 1200 на бензин и 450 на мойку",
        "Сколько я потратил на одежду в этом месяце?",
        "Сравни расходы за октябрь и ноябрь",
        "Создай категорию Кальян",
        "Удали последний расход"
    ]

    var body: some View {
        @Bindable var vm = vm
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if !vm.hasKey { keyBanner }
                            if vm.messages.isEmpty { emptyState }
                            ForEach(vm.messages) { m in
                                MessageView(message: m).id(m.id)
                                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                            }
                            if vm.busy {
                                HStack { TypingDots(); Spacer() }.id("typing")
                            }
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: vm.messages.count) { _, _ in
                        withAnimation { proxy.scrollTo(vm.messages.last?.id, anchor: .bottom) }
                    }
                    .onChange(of: vm.busy) { _, b in if b { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } } }
                }
                inputBar
            }
            .background(Palette.background)
            .navigationTitle(L("Ассистент"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isSheet { ToolbarItem(placement: .cancellationAction) { Button(L("Закрыть")) { dismiss() } } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { vm.newChat() } label: { Image(systemName: "square.and.pencil") }.disabled(vm.messages.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) { if !isSheet { Color.clear.frame(height: focused ? 0 : 90) } }
            .task {
                if vm.startVoiceOnOpen {
                    vm.startVoiceOnOpen = false
                    await vm.toggleVoice()
                }
            }
        }
    }

    var keyBanner: some View {
        NavigationLink { AISettingsView() } label: {
            HStack {
                Image(systemName: "key.fill").foregroundStyle(.orange)
                Text(L("Добавьте ключ OpenAI, чтобы ассистент заработал")).font(.subheadline)
                    .multilineTextAlignment(.leading).foregroundStyle(Color.primary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(Palette.accent)
                .symbolEffect(.pulse)
            Text(L("Скажите или напишите, что сделать")).font(.headline)
            VStack(spacing: 8) {
                ForEach(Self.examples, id: \.self) { e in
                    Button { Task { await vm.send(L(e)) } } label: {
                        Text(L(e)).font(.subheadline).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                    .foregroundStyle(.primary)
                }
            }
        }
        .padding(.top, 20)
    }

    var inputBar: some View {
        @Bindable var vm = vm
        return VStack(spacing: 6) {
            if vm.speech.isRecording {
                HStack(spacing: 8) {
                    VoiceLevel(level: vm.speech.level)
                    Text(vm.speech.transcript.isEmpty ? L("Говорите…") : vm.speech.transcript)
                        .font(.subheadline).lineLimit(3).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let e = vm.speech.error {
                Text(e).font(.caption).foregroundStyle(Palette.expense).padding(.horizontal, 16)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L("Сообщение"), text: $vm.input, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
                    .submitLabel(.send)
                    .onSubmit { Task { await vm.send() } }
                    .accessibilityIdentifier("assistant-input")
                if vm.input.isEmpty {
                    Button { Task { await vm.toggleVoice() } } label: {
                        Image(systemName: vm.speech.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(vm.speech.isRecording ? Palette.expense : Palette.accent, in: Circle())
                            .scaleEffect(vm.speech.isRecording ? 1 + CGFloat(vm.speech.level) * 0.25 : 1)
                            .animation(.easeOut(duration: 0.1), value: vm.speech.level)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("assistant-mic")
                } else {
                    Button { Task { await vm.send() } } label: {
                        Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 42, height: 42).background(Palette.accent, in: Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(vm.busy)
                    .accessibilityIdentifier("assistant-send")
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .padding(.top, 6)
        .background(.bar)
        .animation(.snappy, value: vm.speech.isRecording)
    }
}

struct MessageView: View {
    @Environment(AssistantViewModel.self) private var vm
    let message: AssistantViewModel.Message

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 50)
                Text(message.text).padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .assistant:
            HStack {
                Text(message.text).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
                Spacer(minLength: 50)
            }
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(Palette.expense)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .applied, .undone:
            HStack(spacing: 8) {
                Image(systemName: message.role == .applied ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(message.role == .applied ? Palette.accent : .orange)
                Text(message.text).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                Spacer()
                if message.role == .applied {
                    if let r = message.resolved {
                        Text(r).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(L("Отменить")) { vm.undo(message) }.font(.caption.weight(.semibold))
                    }
                }
            }
            .padding(10)
            .background(Palette.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        case .pending:
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: "hand.raised.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Text(message.text).font(.footnote)
                if let r = message.resolved {
                    Text(r).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button(L("Подтвердить")) { vm.confirm(message) }
                            .buttonStyle(.borderedProminent)
                            .tint(message.pending?.mutation.isDestructive == true ? Palette.expense : Palette.accent)
                            .accessibilityIdentifier("pending-confirm")
                        Button(L("Отмена")) { vm.cancel(message) }.buttonStyle(.bordered)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    var title: String {
        switch message.pending?.reason {
        case .some(.possibleDuplicate): return L("Похоже на дубль — добавить всё равно?")
        case .some(.massChange): return L("Изменить несколько операций?")
        default: return L("Требуется подтверждение")
        }
    }
}

struct TypingDots: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().frame(width: 7, height: 7).foregroundStyle(.secondary)
                    .opacity(0.3 + 0.7 * abs(sin(phase + Double(i) * 0.6)))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .background(Palette.card, in: Capsule())
        .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi } }
    }
}

struct VoiceLevel: View {
    var level: Float
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5) { i in
                Capsule().fill(Palette.expense)
                    .frame(width: 3, height: 6 + CGFloat(level) * CGFloat([10, 18, 24, 18, 10][i]))
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
        .frame(height: 30)
    }
}

struct AISettingsView: View {
    @Environment(Store.self) private var store
    @State private var key = ""
    @State private var hasKey = Keychain.hasKey
    @State private var testing = false
    @State private var testResult: String?

    static let models = ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini", "gpt-5-mini", "gpt-5"]
    static let voices = ["ru-RU", "uk-UA", "en-US"]
    static let voiceNames = ["ru-RU": "Русский", "uk-UA": "Українська", "en-US": "English"]

    var body: some View {
        let ai = store.data.settings.ai
        Form {
            Section {
                if hasKey {
                    LabeledContent(L("Ключ"), value: "••••••••")
                    Button(L("Удалить ключ"), role: .destructive) { Keychain.set(""); hasKey = false }
                } else {
                    SecureField("sk-...", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(L("Сохранить ключ")) {
                        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = ""; hasKey = Keychain.hasKey
                    }
                    .disabled(key.count < 20)
                }
            } header: { Text(L("Ключ OpenAI API")) } footer: {
                Text(L("Ключ хранится в зашифрованной Связке ключей iOS только на этом устройстве, не попадает в код приложения, экспорт и резервные копии. Создать ключ: platform.openai.com → API keys."))
            }
            Section {
                Picker(L("Модель"), selection: Binding(get: { ai.model }, set: { v in store.updateSettings { $0.ai.model = v } })) {
                    ForEach(Self.models + (Self.models.contains(ai.model) ? [] : [ai.model]), id: \.self) { Text($0).tag($0) }
                }
                TextField(L("Другая модель"), text: Binding(get: { ai.model }, set: { v in store.updateSettings { $0.ai.model = v.trimmingCharacters(in: .whitespaces) } }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    Task { await test() }
                } label: { HStack { Text(L("Проверить подключение")); Spacer(); if testing { ProgressView() } } }
                if let r = testResult { Text(r).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text(L("Модель")) }
            Section {
                Picker(L("Язык голоса"), selection: Binding(get: { ai.voiceLocale }, set: { v in store.updateSettings { $0.ai.voiceLocale = v } })) {
                    ForEach(Self.voices, id: \.self) { Text(Self.voiceNames[$0] ?? $0).tag($0) }
                }
                Toggle(L("Отправлять сразу после записи"), isOn: Binding(get: { ai.autoSendVoice }, set: { v in store.updateSettings { $0.ai.autoSendVoice = v } }))
            } header: { Text(L("Голос")) } footer: {
                Text(L("Речь распознаётся системой iOS; в OpenAI уходит только текст команды. Удерживайте «+» на главном экране, чтобы сразу начать запись."))
            }
            Section {
                TextField("https://…", text: Binding(get: { ai.proxyURL }, set: { v in store.updateSettings { $0.ai.proxyURL = v.trimmingCharacters(in: .whitespaces) } }))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text(L("Прокси (необязательно)")) } footer: {
                Text(L("Для будущей публикации: адрес своего сервера, который хранит ключ OpenAI. Тогда в поле ключа вводится токен доступа к прокси. Оставьте пустым для прямого подключения."))
            }
            Section(L("Что отправляется в OpenAI")) {
                Text(L("Текст вашей команды, текущая дата, названия категорий и кошельков. Суммы и операции — только те, что нужны для ответа (например, найденные по запросу). Остальная история остаётся на телефоне."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("AI-ассистент"))
    }

    func test() async {
        testing = true; defer { testing = false }
        let t = OpenAITransport(settings: { [store] in store.data.settings.ai })
        do {
            let m = try await t.complete(messages: [.user("Reply with the single word OK")], tools: [])
            testResult = L("Работает: ") + (m.content ?? "")
        } catch {
            testResult = error.localizedDescription
        }
    }
}
