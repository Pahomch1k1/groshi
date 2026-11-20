import SwiftUI
import GroshiCore

/// Spendee transaction card: category gradient, big amount, a glass card with wallet/date/repeat/exclude,
/// and a card with the description and labels. Changes made here apply immediately (undoable).
struct TransactionDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let txID: UUID
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var note = ""
    @State private var showDate = false
    @State private var date = Date()
    @State private var loaded = false
    @FocusState private var noteFocused: Bool

    var tx: Txn? { store.data.transactions.first { $0.id == txID } }

    var body: some View {
        Group {
            if let tx {
                content(tx)
            } else {
                ContentUnavailableView(L("Операция удалена"), systemImage: "trash")
                    .onAppear { dismiss() }
            }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(30)
        .presentationBackground(.clear)
        .presentationDragIndicator(.visible)
    }

    func content(_ tx: Txn) -> some View {
        let data = store.data
        let cat = data.category(tx.categoryID)
        let tint = tx.isTransfer ? Color(hex: "#8FA3BC") : Color(hex: cat?.colorHex ?? "#8395A7")
        return ZStack(alignment: .top) {
            LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.25), Palette.background], startPoint: .top, endPoint: .bottom)
                .background(Palette.background)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        CircleButton(systemImage: "xmark") { dismiss() }
                        Spacer()
                        Button { editing = true } label: {
                            Text(L("Изменить")).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.primary)
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(Palette.card.opacity(0.92), in: Capsule())
                                .shadow(color: Palette.shadow, radius: 6, y: 2)
                                .frame(height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle(scale: 0.93))
                        .accessibilityIdentifier("detail-edit")
                        CircleButton(systemImage: "trash") { confirmDelete = true }
                            .accessibilityIdentifier("detail-delete")
                    }
                    .padding(.top, 12)

                    VStack(spacing: 6) {
                        if tx.isTransfer { TransferIcon(size: 60).background(Palette.card, in: Circle()) }
                        else { CategoryIconView(category: cat, size: 60, style: .white) }
                        Text(tx.isTransfer ? L("Перевод") : (cat?.name ?? "—")).font(.system(size: 15))
                        Text(tx.isTransfer ? Fmt.trailingCode(tx.amountMinor, tx.currency) : Fmt.trailingCode(tx.signedMinor, tx.currency, sign: tx.kind == .income))
                            .font(.system(size: 30, weight: .bold).monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .strikethrough(tx.isExcluded)
                        if tx.currency != data.settings.baseCurrency,
                           let c = data.settings.converter.convert(tx.amountMinor, from: tx.currency, to: data.settings.baseCurrency) {
                            Text("≈ " + Fmt.trailingCode(c, data.settings.baseCurrency)).font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .padding(.top, 4)

                    paramsCard(tx)
                        .padding(.top, 14)
                    noteCard(tx)
                        .padding(.top, 12)
                    if tx.source != .manual {
                        Text(tx.source == .ai ? L("Добавлено AI-ассистентом") : L("Импортировано"))
                            .font(.system(size: 12)).foregroundStyle(Palette.textTertiary)
                            .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            note = tx.note
            date = tx.date
        }
        .onChange(of: noteFocused) { _, focused in if !focused { saveNote() } }
        .onDisappear { saveNote() }
        .sheet(isPresented: $editing) {
            if let t = self.tx { AddTransactionView(editing: t) }
        }
        .sheet(isPresented: $showDate, onDismiss: {
            if let t = self.tx, t.date != date { update(TxChanges(date: date), L("Дата изменена")) }
        }) {
            DateSheet(date: $date).presentationDetents([.medium, .large])
        }
        .confirmationDialog(L("Удалить операцию?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Удалить"), role: .destructive) {
                if store.perform(.deleteTransactions([txID]), label: L("Операция удалена")) { dismiss() }
            }
        }
    }

    func paramsCard(_ tx: Txn) -> some View {
        let data = store.data
        let rule = tx.recurringID.flatMap { id in data.recurring.first { $0.id == id && $0.isActive } }
        return VStack(spacing: 0) {
            row(tx.isTransfer ? L("Откуда") : (tx.kind == .income ? L("Зачислено в") : L("Оплачено с"))) {
                Menu {
                    ForEach(data.activeWallets) { w in
                        Button("\(w.name) · \(w.currency)") { update(TxChanges(walletID: w.id), L("Кошелёк изменён")) }
                    }
                } label: { valueLabel(data.wallet(tx.walletID)?.name ?? "—", icon: "wallet.pass.fill") }
            }
            if tx.isTransfer {
                divider
                row(L("Куда")) {
                    Text(tx.toWalletID.flatMap { data.wallet($0)?.name } ?? "—").font(.system(size: 15, weight: .semibold))
                }
                if tx.creditedCurrency != tx.currency {
                    divider
                    row(L("Зачислено")) { Text(Fmt.trailingCode(tx.creditedMinor, tx.creditedCurrency)).font(.system(size: 15, weight: .semibold)) }
                }
            }
            divider
            row(L("Когда")) {
                Button { showDate = true } label: { valueLabel(Self.whenText(tx.date), icon: nil) }
                    .buttonStyle(.plain)
            }
            if !tx.isTransfer {
                divider
                row(L("Повтор")) {
                    Menu {
                        Button(L("Не повторять")) { setRepeat(nil, tx: tx, rule: rule) }
                        ForEach(Frequency.allCases, id: \.self) { f in
                            Button(AddTransactionView.frequencyName(f)) { setRepeat(f, tx: tx, rule: rule) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(Palette.textSecondary)
                            Text(rule.map { AddTransactionView.frequencyName($0.frequency) } ?? L("Сделать повторяющейся"))
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(rule == nil ? Palette.textSecondary : Color.primary)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
                divider
                row(L("Исключить из обзора")) {
                    Toggle("", isOn: Binding(get: { tx.isExcluded }, set: { v in
                        update(TxChanges(excluded: v), v ? L("Исключено из обзора") : L("Учитывается в обзоре"))
                    }))
                    .labelsHidden()
                    .tint(Palette.accent)
                    .accessibilityIdentifier("detail-exclude")
                }
            }
        }
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(Palette.card.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.6), lineWidth: 0.6))
    }

    func noteCard(_ tx: Txn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L("Опишите операцию"), text: $note, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(2...6)
                .focused($noteFocused)
                .accessibilityIdentifier("detail-note")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Image(systemName: "tag.fill").font(.system(size: 12))
                        .frame(width: 30, height: 30).background(Palette.bubble.opacity(0.85), in: Circle())
                    let all = store.data.sortedLabels.map { $0.name }
                    ForEach(tx.tags.filter { !all.contains($0) } + all, id: \.self) { name in
                        Chip(text: name, selected: tx.tags.contains(name))
                            .onTapGesture {
                                Haptics.select(enabled: store.data.settings.haptics)
                                var t = tx.tags
                                if t.contains(name) { t.removeAll { $0 == name } } else { t.append(name) }
                                update(TxChanges(labels: t), L("Метки изменены"), toast: false)
                            }
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(Palette.card.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.6), lineWidth: 0.6))
    }

    // MARK: Helpers

    var divider: some View { Divider().padding(.leading, 16).opacity(0.5) }

    func row<V: View>(_ title: String, @ViewBuilder value: () -> V) -> some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 12)
            value()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }

    func valueLabel(_ text: String, icon: String?) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).foregroundStyle(Palette.expense.opacity(0.8)) }
            Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.primary)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textSecondary)
        }
    }

    static func whenText(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return L("Сегодня") + ", " + Fmt.time(d) }
        if cal.isDateInYesterday(d) { return L("Вчера") + ", " + Fmt.time(d) }
        return Fmt.fullDate(d)
    }

    func update(_ ch: TxChanges, _ label: String, toast: Bool = true) {
        store.perform(.updateTransactions(ids: [txID], changes: ch), label: label, toast: toast)
    }

    func saveNote() {
        guard let t = tx else { return }
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean != t.note { update(TxChanges(note: clean), L("Описание сохранено"), toast: false) }
    }

    func setRepeat(_ f: Frequency?, tx: Txn, rule: RecurringRule?) {
        if let f {
            if var r = rule {
                r.frequency = f
                store.perform(.upsertRecurring(r), label: L("Повтор изменён"))
            } else {
                let r = RecurringRule(template: tx, frequency: f, nextDate: Recurrence.advance(tx.date, by: f, calendar: store.calendar))
                store.perform(.batch([.upsertRecurring(r), .updateTransactions(ids: [tx.id], changes: TxChanges(recurringID: r.id))]),
                              label: L("Операция повторяется: ") + AddTransactionView.frequencyName(f))
            }
        } else if let r = rule {
            store.perform(.deleteRecurring(id: r.id), label: L("Повтор отключён"))
        }
    }
}
