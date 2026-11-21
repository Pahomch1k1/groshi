import SwiftUI
import Observation
import GroshiCore

@MainActor
@Observable
final class AssistantViewModel {
    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant, saved, undone, error }
        let id = UUID()
        var role: Role
        var text: String
        var txs: [Txn] = []
        var resolved: String? = nil
        /// For errors: the command to send again (safe: a failed turn leaves nothing behind).
        var retry: String? = nil
        /// Its request id: a retry is the same submission, so nothing can be saved twice.
        var retryID: String? = nil
    }

    /// The floating voice panel on the main screen.
    /// `draft`: the unsent dictated text, editable; the microphone adds to it, "Отправить" sends it.
    enum Phase: Equatable { case idle, recording, draft, thinking, result }

    var messages: [Message] = []
    var input = ""
    var busy = false
    var sheetVisible = false
    var context: String?
    /// The action waiting for "да" or the button (a possible duplicate, a mass change, a deletion).
    var pending: PendingAction?
    var phase: Phase = .idle
    /// Result of the latest command for the voice panel.
    var lastReply = ""
    var lastError: String?
    var lastCommand: String?
    /// Items of the latest command that were not saved (the AI asks about them).
    var lastNotSaved = 0
    /// Message (in `messages`) holding the operations saved by the latest command.
    var lastSavedID: UUID?
    var correcting = false
    let speech = SpeechRecognizer()
    let store: Store
    @ObservationIgnored private var engine: AssistantEngine!

    /// The unsent voice text. Kept on disk on every change (see `VoiceDraftStore`), so switching to
    /// another app, iOS stopping the microphone, closing the panel or a restart never loses it.
    private(set) var draft: VoiceDraft?
    /// Draft text before the current recording; the recording is appended to it.
    @ObservationIgnored private var recordingBase = ""

    init(store: Store) {
        self.store = store
        let transport: LLMTransport = ScriptedTransport.isOn ? ScriptedTransport() : OpenAITransport(settings: { [unowned store] in store.data.settings.ai })
        let host = AssistantHost(
            data: { [unowned store] in store.data },
            apply: { [unowned store] m, label in try store.apply(m, label: label) },
            undo: { [unowned store] in store.undo() },
            isValidSymbol: { UIImage(systemName: $0) != nil })
        engine = AssistantEngine(transport: transport, host: host, calendar: store.calendar, replyLanguage: Lang.aiReplyLanguage)
        draft = store.draftStore.load()
        if draft != nil { phase = .draft } // restored after a restart: shown at once
        speech.onTranscript = { [weak self] text in self?.recognised(text) }
        speech.onInterrupted = { [weak self] in Task { await self?.pauseVoice() } }
    }

    /// Works out of the box through the WorkFlow Spend server; no key setup needed.
    var hasKey: Bool { true }
    var settings: AISettings { store.data.settings.ai }

    var lastSaved: Message? { messages.first { $0.id == lastSavedID } }

    var hasDraft: Bool { !(draft?.isEmpty ?? true) }

    /// The text field of the draft (editable while not recording).
    var draftText: String {
        get { draft?.text ?? "" }
        set {
            var d = draft ?? VoiceDraft()
            d.text = newValue
            d.updatedAt = Date()
            setDraft(d)
        }
    }

    private func setDraft(_ d: VoiceDraft?) {
        draft = d
        do { try store.draftStore.save(d) } catch {
            store.show(L("Ошибка сохранения: ") + error.localizedDescription, canUndo: false, isError: true)
        }
    }

    /// The draft is removed only by an explicit delete or after its operations were saved.
    private func clearDraft() {
        recordingBase = ""
        draft = nil
        store.draftStore.clear()
    }

    func openSheet(context: String? = nil) {
        self.context = context
        sheetVisible = true
    }

    func newChat() {
        if speech.isRecording { Task { await pauseVoice() } }
        engine.reset()
        withAnimation(.snappy) {
            messages = []; pending = nil; lastSavedID = nil
            phase = hasDraft ? .draft : .idle
        }
    }

    // MARK: Voice draft (the microphone adds text, nothing is sent until "Отправить")

    func startVoice(context: String? = nil) async {
        guard phase != .recording, !busy else { return }
        if let context { self.context = context }
        Haptics.tap(enabled: store.data.settings.haptics)
        lastError = nil
        if draft == nil { setDraft(VoiceDraft()) }
        recordingBase = draft?.text ?? ""
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { phase = .recording; correcting = false }
        await speech.start(locale: settings.voiceLocale, after: recordingBase)
        if let e = speech.error {
            lastError = e
            withAnimation { phase = hasDraft ? .draft : .result }
        }
    }

    /// Every partial result goes straight into the draft on disk.
    private func recognised(_ text: String) {
        guard phase == .recording || speech.isRecording else { return }
        var d = draft ?? VoiceDraft()
        d.text = VoiceDraft.joined(recordingBase, text)
        d.updatedAt = Date()
        setDraft(d)
    }

    /// Stops the microphone and keeps everything heard in the draft (also used when the app leaves
    /// the screen: iOS does not let a non-background app keep the microphone).
    func pauseVoice() async {
        guard speech.isRecording || phase == .recording else { return }
        let text = await speech.stop()
        var d = draft ?? VoiceDraft()
        d.text = VoiceDraft.joined(recordingBase, text)
        d.updatedAt = Date()
        setDraft(d.isEmpty ? nil : d)
        recordingBase = draft?.text ?? ""
        withAnimation(.snappy) { phase = hasDraft ? .draft : (lastReply.isEmpty && lastSavedID == nil ? .idle : .result) }
    }

    /// The stop button of the chat: stop and send the whole draft.
    func finishVoice() async {
        guard phase == .recording else { return }
        await pauseVoice()
        await sendDraft()
    }

    /// The app goes to the background (another app, Telegram, the home screen).
    func appWillLeave() async {
        guard speech.isRecording else { return }
        let task = BackgroundTask("voice-draft")
        await pauseVoice()
        task.end()
    }

    /// Explicit delete of the draft (after a confirmation in the panel).
    func deleteDraft() {
        speech.cancel()
        clearDraft()
        context = nil
        withAnimation(.snappy) { phase = .idle }
    }

    /// The ✕ of the panel: hides it; a draft is kept (the AI button shows it is there).
    func closePanel() {
        if speech.isRecording { Task { await pauseVoice(); withAnimation(.snappy) { phase = .idle } } }
        withAnimation(.snappy) { phase = .idle; correcting = false }
    }

    /// The AI button: continue the draft if there is one (recording adds to it), otherwise start one.
    func aiButton() async {
        await startVoice()
    }

    /// "Отправить": the whole draft in one request.
    func sendDraft() async {
        if speech.isRecording { await pauseVoice() }
        guard let d = draft, !d.isEmpty else { return }
        await send(d.text, requestID: d.requestID)
    }

    /// An error message's "Повторить" in the chat.
    func resend(_ m: Message) async {
        guard let text = m.retry else { return }
        if let id = m.retryID, let d = draft, d.requestID == id { await sendDraft(); return }
        await send(text, requestID: m.retryID)
    }

    // MARK: Conversation

    /// Sends a command. A draft (`requestID` = the draft's) is cleared only after the command was
    /// processed without an error; on an error it stays for "Повторить" with the same request id,
    /// so the operations can never be saved twice.
    func send(_ textOverride: String? = nil, requestID: String? = nil) async {
        let text = (textOverride ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        let fromDraft = requestID != nil && requestID == draft?.requestID
        let rid = requestID ?? UUID().uuidString
        if textOverride == nil { input = "" }
        lastCommand = text
        lastError = nil
        lastNotSaved = 0
        withAnimation(.snappy) {
            messages.append(Message(role: .user, text: text))
            phase = .thinking
            correcting = false
        }
        busy = true
        engine.calendar = store.calendar
        engine.replyLanguage = Lang.aiReplyLanguage
        var prompt = text
        if let c = context { prompt = "[Context: \(c)]\n" + text; context = nil }
        // Finish the request even if the user switches to another app right after "Отправить".
        let bg = BackgroundTask("ai-send")
        defer { bg.end() }
        do {
            let r = try await engine.send(prompt, requestID: rid)
            busy = false
            handle(r.events)
            lastNotSaved = r.notSaved.count
            if r.unverifiedClaim {
                // The model said "added" but nothing was written: never show that as a success.
                let e = L("AI ответил, что сохранил, но ни одна операция не записана. Текст остался в черновике — отправьте ещё раз.")
                withAnimation {
                    lastError = e; lastReply = ""
                    messages.append(Message(role: .error, text: e, retry: text, retryID: rid))
                    phase = .result
                }
                Haptics.error(enabled: store.data.settings.haptics)
                return
            }
            let reply: String
            if r.alreadySaved {
                reply = L("Эти операции уже были сохранены — повторно не добавлены.")
            } else if r.interrupted {
                reply = L("Связь прервалась, но изменения уже сохранены — повторять команду не нужно.")
            } else {
                reply = r.reply
            }
            // The draft is done once something was saved, or when the AI answered without asking back.
            // A clarifying question keeps it: the answer is dictated into the same draft and sent whole.
            if fromDraft && (r.savedSomething || !reply.trimmingCharacters(in: .whitespaces).hasSuffix("?")) {
                clearDraft()
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                lastReply = reply
                if !reply.isEmpty { messages.append(Message(role: .assistant, text: reply)) }
                phase = .result
            }
        } catch {
            busy = false
            let e = Self.describe(error) + (fromDraft ? " " + L("Текст сохранён в черновике.") : "")
            withAnimation {
                lastError = e
                lastReply = ""
                messages.append(Message(role: .error, text: e, retry: text, retryID: rid))
                phase = .result
            }
            Haptics.error(enabled: store.data.settings.haptics)
        }
    }

    static func describe(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return L("Нет связи с интернетом — ничего не сохранено.")
            case .timedOut: return L("Сервер AI не ответил вовремя — ничего не сохранено.")
            default: break
            }
        }
        return error.localizedDescription
    }

    func handle(_ events: [AssistantEvent]) {
        var newSaved: [Txn] = []
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            for e in events {
                switch e {
                case .saved(let txs): newSaved += txs
                case .applied(let s): messages.append(Message(role: .saved, text: s))
                case .undone(let s): messages.append(Message(role: .undone, text: s))
                case .pending(let p): pending = p
                case .resolved(let id, _): if pending?.id == id { pending = nil }
                }
            }
            if !newSaved.isEmpty {
                let m = Message(role: .saved, text: "", txs: newSaved)
                messages.append(m)
                lastSavedID = m.id
            } else if events.contains(where: { if case .undone = $0 { return true }; return false }) {
                lastSavedID = nil
            } else if !events.isEmpty || phase == .thinking {
                // A new command without saves must not show the previous command's card.
                lastSavedID = nil
            }
        }
        if events.contains(where: { if case .saved = $0 { return true }; if case .applied = $0 { return true }; return false }) {
            Haptics.success(enabled: store.data.settings.haptics)
        }
    }

    func confirmPending() {
        do { handle(try engine.confirmPending()) } catch {
            withAnimation { messages.append(Message(role: .error, text: Store.describe(error))) }
        }
    }

    func cancelPending() {
        handle(engine.cancelPending())
        withAnimation { messages.append(Message(role: .undone, text: L("Ничего не сохранено"))) }
    }

    /// "Отменить": removes every operation of that command (even if other changes happened after it).
    func undo(_ msg: Message) {
        guard let i = messages.firstIndex(where: { $0.id == msg.id }) else { return }
        if msg.txs.isEmpty {
            if store.undo() != nil { withAnimation(.snappy) { messages[i].resolved = L("Отменено") } }
            return
        }
        let ids = msg.txs.map { $0.id }.filter { id in store.data.transactions.contains { $0.id == id } }
        guard !ids.isEmpty || msg.txs.isEmpty else { withAnimation { messages[i].resolved = L("Отменено") }; return }
        if store.perform(.deleteTransactions(ids), label: L("Отменено операций") + ": \(ids.count)", toast: false) {
            engine.note("The user removed the \(ids.count) operation(s) just saved with the Undo button")
            Haptics.success(enabled: store.data.settings.haptics)
            withAnimation(.snappy) { messages[i].resolved = L("Отменено"); correcting = false }
        }
    }

    /// "Исправить" by voice: the next command refers to these operations.
    func correctByVoice(_ msg: Message) async {
        let ids = msg.txs.map { String($0.id.uuidString.prefix(8)).lowercased() }.joined(separator: ", ")
        await startVoice(context: "The user is correcting the operations just saved (ids: \(ids)); change them with update_transactions / delete_transactions, do not add new ones unless asked")
    }

    /// Current version of operations (after manual edits) for the result panel.
    func current(_ txs: [Txn]) -> [Txn] {
        txs.compactMap { t in store.data.transactions.first { $0.id == t.id } }
    }
}

struct AssistantView: View {
    @Environment(Store.self) private var store
    @Environment(AssistantViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    var isSheet: Bool
    @FocusState private var focused: Bool

    static let examples = [
        "Добавь расход: тысяча гривен на игры",
        "За 11 ноября: 450 на пиццу, 300 в магазин и 200 на такси",
        "Сколько я потратил на одежду в этом месяце?",
        "Отмени последнее действие"
    ]

    var body: some View {
        @Bindable var vm = vm
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if !vm.hasKey { keyBanner }
                            if vm.messages.isEmpty && vm.pending == nil { emptyState }
                            ForEach(vm.messages) { m in
                                MessageView(message: m).id(m.id)
                                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                            }
                            if vm.busy {
                                HStack { TypingDots(); Spacer() }.id("typing")
                            }
                            if let p = vm.pending {
                                PendingCard(pending: p).id("pending")
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: vm.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: vm.pending) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: vm.busy) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                inputBar
            }
            .background(Palette.background)
            .navigationTitle(L("Ассистент"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isSheet { ToolbarItem(placement: .cancellationAction) { Button(L("Закрыть")) { dismiss() } } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { vm.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .disabled(vm.messages.isEmpty && vm.pending == nil)
                }
            }
            .safeAreaInset(edge: .bottom) { if !isSheet { Color.clear.frame(height: focused ? 0 : 80) } }
        }
    }

    var keyBanner: some View {
        NavigationLink { AISettingsView() } label: {
            HStack {
                Image(systemName: "key.fill").foregroundStyle(.orange)
                Text(L("Добавьте ключ OpenAI, чтобы ассистент заработал")).font(.footnote)
                    .multilineTextAlignment(.leading).foregroundStyle(Color.primary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(Palette.accent)
                .symbolEffect(.pulse)
            Text(L("Скажите, что записать")).font(.subheadline.weight(.semibold))
            VStack(spacing: 6) {
                ForEach(Self.examples, id: \.self) { e in
                    Button { Task { await vm.send(L(e)) } } label: {
                        Text(L(e)).font(.footnote).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                    .foregroundStyle(.primary)
                }
            }
        }
        .padding(.top, 14)
    }

    var inputBar: some View {
        @Bindable var vm = vm
        return VStack(spacing: 6) {
            if vm.speech.isRecording {
                HStack(spacing: 8) {
                    VoiceLevel(level: vm.speech.level)
                    Text(vm.speech.transcript.isEmpty ? L("Говорите…") : vm.speech.transcript)
                        .font(.footnote).lineLimit(3).foregroundStyle(.secondary)
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
                    .font(.subheadline)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
                    .submitLabel(.send)
                    .onSubmit { Task { await vm.send() } }
                    .accessibilityIdentifier("assistant-input")
                if vm.input.isEmpty {
                    Button { Task { if vm.phase == .recording { await vm.finishVoice() } else { await vm.startVoice() } } } label: {
                        Image(systemName: vm.speech.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(vm.speech.isRecording ? Palette.expense : Palette.accent, in: Circle())
                            .scaleEffect(vm.speech.isRecording ? 1 + CGFloat(vm.speech.level) * 0.25 : 1)
                            .animation(.easeOut(duration: 0.1), value: vm.speech.level)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("assistant-mic")
                } else {
                    Button { Task { await vm.send() } } label: {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(Palette.accent, in: Circle())
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

/// The draft of recognised operations (one tap saves all) or another action waiting for confirmation.
struct PendingCard: View {
    @Environment(Store.self) private var store
    @Environment(AssistantViewModel.self) private var vm
    let pending: PendingAction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if pending.isDraft {
                draft
            } else {
                Label(title, systemImage: "hand.raised.fill").font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                Text(pending.summary).font(.caption)
            }
            HStack(spacing: 8) {
                Button {
                    vm.confirmPending()
                } label: {
                    Text(pending.isDraft ? L("Добавить всё равно") : L("Подтвердить"))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .foregroundStyle(.white)
                        .background(pending.mutation.isDestructive ? Palette.expense : Palette.accent, in: Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.97))
                .accessibilityIdentifier("pending-confirm")
                Button { vm.cancelPending() } label: {
                    Text(L("Отмена")).font(.subheadline.weight(.medium))
                        .frame(height: 40).padding(.horizontal, 16)
                        .background(Palette.bubble, in: Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.97))
                .foregroundStyle(.primary)
                .accessibilityIdentifier("pending-cancel")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spendCard(radius: 18)
    }

    var draft: some View {
        let txs = pending.transactions
        let base = store.data.settings.baseCurrency
        let tot = Analytics.totals(txs, data: store.data)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(pending.reason == .possibleDuplicate ? L("Похоже на дубль — добавить всё равно?") : L("Проверьте и сохраните"))
                    .font(.footnote.weight(.semibold))
                Spacer()
                Text(summaryLine(tot, base)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)
            ForEach(Array(txs.enumerated()), id: \.element.id) { i, t in
                DraftRow(tx: t, duplicate: pending.duplicateIndexes.contains(i))
            }
        }
    }

    func summaryLine(_ t: Totals, _ base: String) -> String {
        var parts: [String] = []
        if t.expense > 0 { parts.append(Fmt.code(-t.expense, base)) }
        if t.income > 0 { parts.append(Fmt.code(t.income, base, sign: true)) }
        return parts.joined(separator: " · ")
    }

    var title: String {
        switch pending.reason {
        case .possibleDuplicate: return L("Похоже на дубль — добавить всё равно?")
        case .massChange: return L("Изменить несколько операций?")
        default: return L("Требуется подтверждение")
        }
    }
}

struct DraftRow: View {
    @Environment(Store.self) private var store
    let tx: Txn
    var duplicate = false
    var remove: (() -> Void)? = nil

    var body: some View {
        let cat = store.data.category(tx.categoryID)
        HStack(spacing: 8) {
            TxIcon(tx: tx, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(cat?.name ?? "—").font(.footnote).lineLimit(1).accessibilityIdentifier("draft-row")
                    if duplicate {
                        Text(L("дубль?")).font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
                Text(DraftRow.day(tx.date, store.calendar) + (tx.note.isEmpty ? "" : " · " + tx.note))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Fmt.code(tx.kind == .expense ? -tx.amountMinor : tx.amountMinor, tx.currency, sign: true))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(tx.kind == .income ? Palette.income : Color.primary)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Убрать"))
            }
        }
        .padding(.vertical, 1)
    }

    static func day(_ d: Date, _ cal: Calendar) -> String {
        if cal.isDateInToday(d) { return L("Сегодня") }
        if cal.isDateInYesterday(d) { return L("Вчера") }
        let f = DateFormatter()
        f.locale = Lang.locale
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: d)
    }
}

struct MessageView: View {
    @Environment(AssistantViewModel.self) private var vm
    @Environment(Store.self) private var store
    let message: AssistantViewModel.Message

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 50)
                Text(message.text).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case .assistant:
            HStack {
                Text(message.text).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("assistant-reply")
                Spacer(minLength: 50)
            }
        case .error:
            HStack(spacing: 8) {
                Label(message.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Palette.expense)
                Spacer()
                if message.retry != nil {
                    Button(L("Повторить")) { Task { await vm.resend(message) } }.font(.caption.weight(.semibold))
                }
            }
        case .saved, .undone:
            HStack(spacing: 8) {
                Image(systemName: message.role == .saved ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(message.role == .saved ? Palette.accent : .orange)
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                if message.role == .saved {
                    if let r = message.resolved {
                        Text(r).font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Button(L("Отменить")) { vm.undo(message) }.font(.caption.weight(.semibold))
                            .accessibilityIdentifier("assistant-undo")
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Palette.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    var line: String {
        guard !message.txs.isEmpty else { return message.text }
        if message.txs.count == 1, let t = message.txs.first {
            let cat = store.data.category(t.categoryID)?.name ?? ""
            return L("Сохранено") + ": " + cat + " · " + Fmt.code(t.kind == .expense ? -t.amountMinor : t.amountMinor, t.currency, sign: true)
                + " · " + DraftRow.day(t.date, store.calendar)
        }
        return L("Сохранено операций") + ": \(message.txs.count)"
    }
}

struct TypingDots: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().frame(width: 6, height: 6).foregroundStyle(.secondary)
                    .opacity(0.3 + 0.7 * abs(sin(phase + Double(i) * 0.6)))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
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
                    .frame(width: 3, height: 5 + CGFloat(level) * CGFloat([8, 14, 20, 14, 8][i]))
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
        .frame(height: 26)
    }
}

struct AISettingsView: View {
    @Environment(Store.self) private var store
    @State private var key = ""
    @State private var hasKey = Keychain.hasKey
    @State private var testing = false
    @State private var testResult: String?
    @State private var keyError: String?

    static let models = ["gpt-4.1", "gpt-4.1-mini"]
    static let voices = ["ru-RU", "uk-UA", "en-US"]
    static let voiceNames = ["ru-RU": "Русский", "uk-UA": "Українська", "en-US": "English"]

    var body: some View {
        let ai = store.data.settings.ai
        Form {
            Section {
                LabeledContent(L("Подключение")) {
                    Text(hasKey ? L("Свой ключ OpenAI") : L("Сервер WorkFlow Spend")).foregroundStyle(.secondary)
                }
                Button {
                    Task { await test() }
                } label: { HStack { Text(L("Проверить подключение")); Spacer(); if testing { ProgressView() } } }
                .accessibilityIdentifier("ai-test")
                if let r = testResult { Text(r).font(.footnote).foregroundStyle(.secondary) }
                Picker(L("Модель"), selection: Binding(get: { ai.model }, set: { v in store.updateSettings { $0.ai.model = v } })) {
                    ForEach(Self.models + (Self.models.contains(ai.model) ? [] : [ai.model]), id: \.self) { Text($0).tag($0) }
                }
            } header: { Text(L("AI")) } footer: {
                Text(L("Ассистент работает сразу: ключ OpenAI хранится на сервере WorkFlow Spend, в приложении его нет. Телефон получает свой токен доступа автоматически. gpt-4.1 точнее понимает даты и категории; gpt-4.1-mini дешевле примерно в 5 раз."))
            }
            Section {
                Picker(L("Язык голоса"), selection: Binding(get: { ai.voiceLocale }, set: { v in store.updateSettings { $0.ai.voiceLocale = v } })) {
                    ForEach(Self.voices, id: \.self) { Text(Self.voiceNames[$0] ?? $0).tag($0) }
                }
            } header: { Text(L("Голос")) } footer: {
                Text(L("Речь распознаётся системой iOS; в OpenAI уходит только текст команды. Нажмите кнопку микрофона на главном экране: запись идёт, пока вы её не остановите, паузы не прерывают её. После остановки команда отправляется сама."))
            }
            Section {
                DisclosureGroup(L("Свой ключ OpenAI (необязательно)")) {
                    if hasKey {
                        LabeledContent(L("Ключ"), value: "••••••••")
                        Button(L("Удалить ключ"), role: .destructive) { Keychain.set(""); hasKey = false; testResult = nil }
                    } else {
                        PasteButton(payloadType: String.self) { strings in
                            Task { @MainActor in save(strings.first ?? "") }
                        }
                        .labelStyle(.titleAndIcon)
                        SecureField("sk-...", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(L("Сохранить ключ")) { save(key) }.disabled(key.count < 20)
                        if let e = keyError { Text(e).font(.footnote).foregroundStyle(Palette.expense) }
                    }
                    TextField(L("Адрес своего прокси"), text: Binding(get: { ai.proxyURL }, set: { v in store.updateSettings { $0.ai.proxyURL = v.trimmingCharacters(in: .whitespaces) } }))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } footer: {
                Text(L("Только если хотите обращаться к OpenAI напрямую своим ключом. Ключ хранится в Связке ключей iOS на этом устройстве."))
            }
            Section(L("Что отправляется в OpenAI")) {
                Text(L("Текст вашей команды, текущая дата, названия категорий и кошельков. Суммы и операции — только те, что нужны для ответа (например, найденные по запросу). Остальная история остаётся на телефоне."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("AI-ассистент"))
    }

    func save(_ raw: String) {
        // Accept a bare key or a line like OPENAI_API_KEY=sk-...
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = v.range(of: "OPENAI_API_KEY=") { v = String(v[r.upperBound...]) }
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\r\t"))
        guard v.hasPrefix("sk-"), v.count >= 40, !v.contains(" ") else {
            keyError = L("Это не похоже на ключ OpenAI (он начинается с sk-).")
            return
        }
        Keychain.set(v)
        key = ""
        keyError = nil
        hasKey = Keychain.hasKey
        Haptics.success(enabled: store.data.settings.haptics)
        Task { await test() }
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
