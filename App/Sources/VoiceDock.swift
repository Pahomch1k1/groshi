import SwiftUI
import GroshiCore

/// Floating AI panel above the tab bar: recording (timer, wave, live text, ✕ and stop) →
/// "thinking" → result (saved operations with "Исправить" / "Отменить", a question, or an error).
/// No extra screens: one tap on the AI button starts recording, the stop button sends.
struct VoiceDock: View {
    @Environment(Store.self) private var store
    @Environment(AssistantViewModel.self) private var ai
    @State private var editing: Txn?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch ai.phase {
            case .idle: EmptyView()
            case .recording: recording
            case .thinking: thinking
            case .result: result
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.14), radius: 18, y: 6)
        .sheet(item: $editing) { tx in AddTransactionView(editing: tx) }
    }

    // MARK: Recording

    var recording: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(Palette.expense).frame(width: 8, height: 8)
                    .opacity(0.9)
                    .phaseAnimator([0.3, 1.0]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.6) }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.elapsed(from: ai.speech.startedAt, to: ctx.date))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .accessibilityIdentifier("voice-timer")
                }
                WaveBars(level: ai.speech.level)
                Spacer()
            }
            Text(ai.speech.transcript.isEmpty ? L("Говорите — паузы не прерывают запись") : ai.speech.transcript)
                .font(.subheadline)
                .foregroundStyle(ai.speech.transcript.isEmpty ? Palette.textSecondary : Color.primary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.15), value: ai.speech.transcript)
                .accessibilityIdentifier("voice-transcript")
            HStack(spacing: 10) {
                Button { ai.cancelVoice() } label: {
                    Label(L("Отмена"), systemImage: "xmark")
                        .font(.system(size: 15, weight: .medium))
                        .frame(height: 44).padding(.horizontal, 16)
                        .background(Palette.bubble, in: Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.95))
                .foregroundStyle(Color.primary)
                .accessibilityIdentifier("voice-cancel")
                Button { Task { await ai.finishVoice() } } label: {
                    Label(L("Готово"), systemImage: "stop.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Palette.accent, in: Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.97))
                .accessibilityIdentifier("voice-stop")
            }
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Thinking

    var thinking: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let c = ai.lastCommand {
                Text(c).font(.footnote).foregroundStyle(Palette.textSecondary).lineLimit(3)
            }
            HStack(spacing: 8) {
                ProgressView()
                Text(L("Обрабатываю…")).font(.subheadline)
            }
        }
        .accessibilityIdentifier("voice-thinking")
    }

    // MARK: Result

    @ViewBuilder var result: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                if let e = ai.lastError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Palette.expense)
                } else if let saved = ai.lastSaved, saved.resolved == nil {
                    savedCard(saved)
                } else if let saved = ai.lastSaved, let r = saved.resolved {
                    Label(r, systemImage: "arrow.uturn.backward.circle.fill").font(.subheadline).foregroundStyle(.orange)
                    if !ai.lastReply.isEmpty { Text(ai.lastReply).font(.footnote).foregroundStyle(Palette.textSecondary) }
                } else if !ai.lastReply.isEmpty {
                    Text(ai.lastReply).font(.subheadline).accessibilityIdentifier("voice-reply")
                }
            }
            Spacer(minLength: 0)
            Button { ai.closePanel() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.textSecondary)
                    .frame(width: 28, height: 28).background(Palette.bubble, in: Circle())
                    .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Закрыть"))
            .accessibilityIdentifier("voice-close")
        }
        if let p = ai.pending {
            HStack(spacing: 8) {
                bigButton(p.isDraft ? L("Добавить всё равно") : L("Подтвердить"), id: "pending-confirm", primary: true) { ai.confirmPending() }
                bigButton(L("Нет"), id: "pending-cancel", primary: false) { ai.cancelPending() }
            }
        } else if let saved = ai.lastSaved, saved.resolved == nil, ai.lastError == nil {
            if ai.correcting {
                Text(L("Нажмите на операцию, чтобы изменить её вручную, или скажите, что исправить."))
                    .font(.caption).foregroundStyle(Palette.textSecondary)
                HStack(spacing: 8) {
                    bigButton(L("Сказать"), icon: "mic.fill", id: "saved-fix-voice", primary: true) { Task { await ai.correctByVoice(saved) } }
                    bigButton(L("Отменить"), id: "saved-undo", primary: false) { ai.undo(saved) }
                }
            } else {
                HStack(spacing: 8) {
                    bigButton(L("Исправить"), icon: "pencil", id: "saved-fix", primary: false) { withAnimation(.snappy) { ai.correcting = true } }
                    bigButton(L("Отменить"), icon: "arrow.uturn.backward", id: "saved-undo", primary: false) { ai.undo(saved) }
                }
            }
        } else {
            HStack(spacing: 8) {
                if let e = ai.lastError, let c = ai.lastCommand, !e.isEmpty {
                    bigButton(L("Повторить"), icon: "arrow.clockwise", id: "voice-retry", primary: false) { Task { await ai.send(c) } }
                }
                bigButton(ai.lastReply.hasSuffix("?") ? L("Ответить") : L("Ещё команда"), icon: "mic.fill", id: "voice-answer", primary: true) {
                    Task { await ai.startVoice() }
                }
                bigButton(L("Чат"), icon: "bubble.left.and.bubble.right", id: "voice-chat", primary: false) { ai.openSheet() }
            }
        }
    }

    func savedCard(_ m: AssistantViewModel.Message) -> some View {
        let txs = ai.current(m.txs)
        let base = store.data.settings.baseCurrency
        let total = Analytics.totals(txs, data: store.data)
        let days = Set(txs.map { store.calendar.startOfDay(for: $0.date) })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                Text(Self.savedTitle(txs.count) + " · " + Fmt.code(total.expense + total.income, base).replacingOccurrences(of: "−", with: ""))
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityIdentifier("saved-title")
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(txs.prefix(ai.correcting ? 50 : 6))) { t in
                    Button { if ai.correcting { editing = t } } label: {
                        HStack(spacing: 6) {
                            Text(store.data.category(t.categoryID)?.name ?? "—").font(.footnote)
                            Text("—").font(.footnote).foregroundStyle(Palette.textTertiary)
                            Text(Fmt.code(t.amountMinor, t.currency, sign: t.kind == .income))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(t.kind == .income ? Palette.income : Color.primary)
                            if days.count > 1 {
                                Text(DraftRow.day(t.date, store.calendar)).font(.caption2).foregroundStyle(Palette.textTertiary)
                            }
                            Spacer(minLength: 0)
                            if ai.correcting { Image(systemName: "pencil").font(.caption).foregroundStyle(Palette.accent) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!ai.correcting)
                    .accessibilityIdentifier("saved-row")
                }
                if !ai.correcting && txs.count > 6 {
                    Text(L("ещё") + " \(txs.count - 6)").font(.caption).foregroundStyle(Palette.textTertiary)
                }
            }
            if days.count == 1, let d = days.first {
                Text(L("Дата") + ": " + DraftRow.day(d, store.calendar)).font(.caption).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    func bigButton(_ title: String, icon: String? = nil, id: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(primary ? Color.white : Color.primary)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(primary ? Palette.accent : Palette.bubble, in: Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .accessibilityIdentifier(id)
    }

    /// "Сохранено 3 транзакции" with the right plural in uk/ru/en.
    static func savedTitle(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let few = (2...4).contains(m10) && !(12...14).contains(m100)
        let one = m10 == 1 && m100 != 11
        switch Lang.effective {
        case .en: return "Saved \(n) transaction" + (n == 1 ? "" : "s")
        case .uk: return "Збережено \(n) " + (one ? "транзакцію" : few ? "транзакції" : "транзакцій")
        default: return "Сохранено \(n) " + (one ? "транзакция" : few ? "транзакции" : "транзакций")
        }
    }
}

/// Sound wave for the recording state.
struct WaveBars: View {
    var level: Float
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
            let time = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<14, id: \.self) { i in
                    let wobble = (sin(time * 7 + Double(i) * 0.7) + 1) / 2
                    Capsule().fill(Palette.accent)
                        .frame(width: 3, height: 4 + CGFloat(level) * 20 * CGFloat(0.35 + 0.65 * wobble))
                }
            }
            .frame(height: 26)
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

/// The green AI button: a microphone with a small sparkles badge.
struct AIFab: View {
    var recording: Bool
    var size: CGFloat = 52
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(recording ? Palette.expense : Palette.accent, in: Circle())
                    .shadow(color: Palette.accent.opacity(0.35), radius: 10, y: 4)
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 20, height: 20)
                    .background(Color.white, in: Circle())
                    .overlay(Circle().stroke(Palette.accent.opacity(0.25), lineWidth: 1))
                    .offset(x: 3, y: -3)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(L("AI: голосовая команда"))
    }
}
