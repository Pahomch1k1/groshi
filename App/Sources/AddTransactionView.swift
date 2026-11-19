import SwiftUI
import GroshiCore

/// Single-screen entry: type switch, big amount, category grid, wallet/date/note, keypad.
struct AddTransactionView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let editing: Txn?

    @State private var kind: TxKind = .expense
    @State private var amountText = ""
    @State private var currency = "UAH"
    @State private var categoryID: UUID?
    @State private var walletID: UUID?
    @State private var date = Date()
    @State private var note = ""
    @State private var shake = 0
    @State private var showNewCategory = false
    @FocusState private var noteFocused: Bool
    @FocusState private var toAmountFocused: Bool
    @State private var loaded = false
    // Transfer
    @State private var toWalletID: UUID?
    @State private var toAmountText = ""

    var keyboardUp: Bool { noteFocused || toAmountFocused }

    init(editing: Txn?) { self.editing = editing }

    var amountMinor: Int64? {
        guard !amountText.isEmpty else { return nil }
        return MoneyMath.parseMinor(amountText, currency: currency)
    }

    var body: some View {
        let data = store.data
        let cats = data.categories(of: kind)
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        Picker("", selection: $kind.animation(.snappy)) {
                            Text(L("Расход")).tag(TxKind.expense)
                            Text(L("Доход")).tag(TxKind.income)
                            Text(L("Перевод")).tag(TxKind.transfer)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("kind-picker")

                        amountDisplay

                        if kind == .transfer {
                            transferCard
                                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        } else {
                            categoryGrid(cats)
                                .gesture(DragGesture(minimumDistance: 40).onEnded { v in
                                    if abs(v.translation.width) > abs(v.translation.height) * 2 {
                                        withAnimation(.snappy) { kind = v.translation.width < 0 ? .income : .expense }
                                    }
                                })
                                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        }

                        detailsCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                if !keyboardUp {
                    Keypad(text: $amountText, haptics: data.settings.haptics, onSave: save)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(Palette.background)
            .navigationTitle(editing == nil ? L("Новая операция") : L("Изменить операцию"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { dismiss() } }
                ToolbarItem(placement: .principal) { EmptyView() }
                ToolbarItem(placement: .topBarTrailing) { AssistantToolbarButton(context: editing.map { "Пользователь редактирует операцию id \(String($0.id.uuidString.prefix(8)).lowercased())" }) }
                ToolbarItem(placement: .keyboard) { HStack { Spacer(); Button(L("Готово")) { noteFocused = false; toAmountFocused = false } } }
            }
            .animation(.snappy, value: keyboardUp)
            .onAppear(perform: load)
            .onChange(of: kind) { _, _ in
                if let id = categoryID, store.data.category(id)?.kind != kind { categoryID = nil }
                if kind == .transfer && (toWalletID == nil || toWalletID == walletID) {
                    toWalletID = store.data.activeWallets.first { $0.id != walletID }?.id
                }
            }
            .onChange(of: walletID) { _, new in
                if let w = new.flatMap({ store.data.wallet($0) }), amountText.isEmpty || editing == nil { currency = w.currency }
                if kind == .transfer && toWalletID == new { toWalletID = store.data.activeWallets.first { $0.id != new }?.id }
            }
            .sheet(isPresented: $showNewCategory) {
                CategoryEditor(category: nil, kind: kind) { created in categoryID = created.id }
            }
        }
        .presentationDragIndicator(.visible)
    }

    var amountDisplay: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if kind == .transfer {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 30, weight: .bold)).foregroundStyle(.secondary)
                } else {
                    Text(kind == .expense ? "−" : "+")
                        .foregroundStyle(kind == .expense ? Palette.expense : Palette.income)
                }
                Text(Self.grouped(amountText))
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("amount-display")
                Menu {
                    ForEach(Currencies.common, id: \.self) { c in
                        Button(c + " " + Currencies.symbol(c)) { currency = c }
                    }
                } label: {
                    Text(Currencies.symbol(currency))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("currency-menu")
            }
            .font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
            .lineLimit(1).minimumScaleFactor(0.5)
            .modifier(ShakeEffect(shakes: CGFloat(shake)))
            .animation(.snappy(duration: 0.18), value: amountText)
            if currency != store.data.settings.baseCurrency, let m = amountMinor,
               let c = store.data.settings.converter.convert(m, from: currency, to: store.data.settings.baseCurrency) {
                Text("≈ " + Fmt.money(c, store.data.settings.baseCurrency)).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    func categoryGrid(_ cats: [FinCategory]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
            ForEach(cats) { c in
                let on = categoryID == c.id
                Button {
                    Haptics.select(enabled: store.data.settings.haptics)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { categoryID = c.id }
                } label: {
                    VStack(spacing: 5) {
                        CategoryIconView(category: c, size: 50)
                            .overlay(Circle().strokeBorder(on ? Color(hex: c.colorHex) : .clear, lineWidth: 2.5).padding(-4))
                            .scaleEffect(on ? 1.08 : 1)
                        Text(c.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                            .foregroundStyle(on ? .primary : .secondary)
                            .frame(height: 28, alignment: .top)
                    }
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("category-\(c.name)")
            }
            Button { showNewCategory = true } label: {
                VStack(spacing: 5) {
                    Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 50, height: 50)
                        .background(Palette.bubble, in: Circle())
                    Text(L("Новая")).font(.caption2).foregroundStyle(.secondary).frame(height: 28, alignment: .top)
                }
            }
            .buttonStyle(PressableStyle())
        }
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    var toWallet: Wallet? { toWalletID.flatMap { store.data.wallet($0) } }

    /// From / to wallets and, for different currencies, the credited amount.
    var transferCard: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L("Откуда"), systemImage: "arrow.up.circle").foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $walletID) {
                    ForEach(store.data.activeWallets) { w in Text("\(w.name) · \(w.currency)").tag(UUID?.some(w.id)) }
                }
                .labelsHidden()
                .accessibilityIdentifier("transfer-from")
            }
            .padding(.vertical, 6)
            Divider()
            HStack {
                Label(L("Куда"), systemImage: "arrow.down.circle").foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $toWalletID) {
                    ForEach(store.data.activeWallets.filter { $0.id != walletID }) { w in Text("\(w.name) · \(w.currency)").tag(UUID?.some(w.id)) }
                }
                .labelsHidden()
                .accessibilityIdentifier("transfer-to")
            }
            .padding(.vertical, 6)
            if let to = toWallet, to.currency != currency {
                Divider()
                HStack {
                    Label(L("Зачислено"), systemImage: "arrow.down.to.line").foregroundStyle(.secondary)
                    Spacer()
                    TextField(placeholderCredit(to), text: $toAmountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($toAmountFocused)
                        .frame(maxWidth: 140)
                        .accessibilityIdentifier("transfer-to-amount")
                    Text(Currencies.symbol(to.currency)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            }
            if store.data.activeWallets.count < 2 {
                Text(L("Для перевода нужен второй кошелёк: «Ещё → Кошельки»."))
                    .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Suggested credited amount at the app's exchange rate.
    func placeholderCredit(_ to: Wallet) -> String {
        guard let m = amountMinor, let c = store.data.settings.converter.convert(m, from: currency, to: to.currency) else { return "0" }
        return MoneyMath.plainString(c, currency: to.currency).replacingOccurrences(of: ".", with: ",")
    }

    var detailsCard: some View {
        VStack(spacing: 0) {
            if kind != .transfer {
                HStack {
                    Label(L("Кошелёк"), systemImage: "wallet.pass").foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $walletID) {
                        ForEach(store.data.activeWallets) { w in Text("\(w.name) · \(w.currency)").tag(UUID?.some(w.id)) }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("wallet-picker")
                }
                .padding(.vertical, 6)
                Divider()
            }
            HStack {
                Label(L("Дата"), systemImage: "calendar").foregroundStyle(.secondary)
                Spacer()
                DatePicker("", selection: $date).labelsHidden()
            }
            .padding(.vertical, 6)
            Divider()
            HStack {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                TextField(L("Комментарий"), text: $note, axis: .vertical)
                    .focused($noteFocused)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("note-field")
            }
            .padding(.vertical, 12)
        }
        .padding(.horizontal, 14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        let data = store.data
        if let t = editing {
            kind = t.kind
            amountText = MoneyMath.plainString(t.amountMinor, currency: t.currency).replacingOccurrences(of: ".00", with: "").replacingOccurrences(of: ".", with: ",")
            currency = t.currency; categoryID = t.categoryID; walletID = t.walletID; date = t.date; note = t.note
            if t.isTransfer {
                categoryID = nil
                toWalletID = t.toWalletID
                if t.creditedCurrency != t.currency {
                    toAmountText = MoneyMath.plainString(t.creditedMinor, currency: t.creditedCurrency).replacingOccurrences(of: ".", with: ",")
                }
            }
        } else {
            walletID = data.defaultWallet?.id
            currency = data.defaultWallet?.currency ?? data.settings.baseCurrency
        }
    }

    func save() {
        if kind == .transfer { saveTransfer(); return }
        guard let minor = amountMinor, minor > 0 else { fail(); return }
        guard let cat = categoryID else { fail(); return }
        guard let wal = walletID ?? store.data.defaultWallet?.id else { fail(); return }
        let ok: Bool
        if let t = editing {
            ok = store.perform(.updateTransactions(ids: [t.id], changes: TxChanges(kind: kind, amountMinor: minor, currency: currency,
                                                                                   categoryID: cat, walletID: wal, date: date, note: note)),
                               label: L("Операция изменена"))
        } else {
            let tx = Txn(kind: kind, amountMinor: minor, currency: currency, categoryID: cat, walletID: wal, date: date, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            ok = store.perform(.addTransactions([tx]), label: (kind == .expense ? L("Расход") : L("Доход")) + " " + Fmt.money(minor, currency))
        }
        if ok { dismiss() }
    }

    func saveTransfer() {
        guard let minor = amountMinor, minor > 0,
              let from = walletID ?? store.data.defaultWallet?.id,
              let to = toWallet, to.id != from else { fail(); return }
        var credited: Int64? = nil
        if to.currency != currency {
            if !toAmountText.isEmpty {
                guard let v = MoneyMath.parseMinor(toAmountText, currency: to.currency), v > 0 else { fail(); return }
                credited = v
            } else if let v = store.data.settings.converter.convert(minor, from: currency, to: to.currency) {
                credited = v
            } else { fail(); return }
        }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok: Bool
        if let t = editing {
            ok = store.perform(.updateTransactions(ids: [t.id], changes: TxChanges(
                kind: .transfer, amountMinor: minor, currency: currency, walletID: from, date: date, note: cleanNote,
                transfer: TransferTarget(toWalletID: to.id, toAmountMinor: credited, toCurrency: to.currency))),
                               label: L("Операция изменена"))
        } else {
            let tx = Txn.transfer(from: from, to: to.id, amountMinor: minor, currency: currency, toAmountMinor: credited,
                                  toCurrency: to.currency, date: date, note: cleanNote)
            ok = store.perform(.addTransactions([tx]), label: L("Перевод") + " " + Fmt.money(minor, currency))
        }
        if ok { dismiss() }
    }

    /// "15000,5" → "15 000,5" for display (input text stays raw).
    static func grouped(_ text: String) -> String {
        guard !text.isEmpty else { return "0" }
        let parts = text.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        var out = ""
        for (i, ch) in intPart.enumerated() {
            if i > 0 && (intPart.count - i) % 3 == 0 { out.append("\u{202F}") }
            out.append(ch)
        }
        return parts.count > 1 ? out + "," + parts[1] : out
    }

    func fail() {
        Haptics.error(enabled: store.data.settings.haptics)
        withAnimation(.default) { shake += 1 }
    }
}

struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(shakes * .pi * 4), y: 0))
    }
}

/// Calculator-style keypad.
struct Keypad: View {
    @Binding var text: String
    var haptics: Bool
    var onSave: () -> Void

    let keys: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [",", "0", "⌫"]]

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 8) {
                ForEach(keys, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(row, id: \.self) { k in
                            Button { press(k) } label: {
                                Group {
                                    if k == "⌫" { Image(systemName: "delete.left") } else { Text(k) }
                                }
                                .font(.system(size: 24, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .foregroundStyle(.primary)
                            }
                            .buttonStyle(PressableStyle(scale: 0.92))
                            .accessibilityIdentifier("key-\(k)")
                        }
                    }
                }
            }
            Button(action: onSave) {
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 72)
                    .frame(maxHeight: .infinity)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressableStyle(scale: 0.94))
            .accessibilityIdentifier("save-button")
        }
        .frame(height: 50 * 4 + 8 * 3)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    func press(_ k: String) {
        Haptics.tap(enabled: haptics)
        switch k {
        case "⌫":
            if !text.isEmpty { text.removeLast() }
        case ",":
            if !text.contains(",") { text = (text.isEmpty ? "0" : text) + "," }
        default:
            if let comma = text.firstIndex(of: ",") , text.distance(from: comma, to: text.endIndex) > 2 { return }
            if text == "0" { text = k; return }
            if text.replacingOccurrences(of: ",", with: "").count >= 12 { return }
            text += k
        }
    }
}
