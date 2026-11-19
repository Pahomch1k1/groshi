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
    @State private var loaded = false

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
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("kind-picker")

                        amountDisplay

                        categoryGrid(cats)
                            .gesture(DragGesture(minimumDistance: 40).onEnded { v in
                                if abs(v.translation.width) > abs(v.translation.height) * 2 {
                                    withAnimation(.snappy) { kind = v.translation.width < 0 ? .income : .expense }
                                }
                            })

                        detailsCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                if !noteFocused {
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
                ToolbarItem(placement: .keyboard) { HStack { Spacer(); Button(L("Готово")) { noteFocused = false } } }
            }
            .animation(.snappy, value: noteFocused)
            .onAppear(perform: load)
            .onChange(of: kind) { _, _ in
                if let id = categoryID, store.data.category(id)?.kind != kind { categoryID = nil }
            }
            .onChange(of: walletID) { _, new in
                if let w = new.flatMap({ store.data.wallet($0) }), amountText.isEmpty || editing == nil { currency = w.currency }
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
                Text(kind == .expense ? "−" : "+")
                    .foregroundStyle(kind == .expense ? Palette.expense : Palette.income)
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

    var detailsCard: some View {
        VStack(spacing: 0) {
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
        } else {
            walletID = data.defaultWallet?.id
            currency = data.defaultWallet?.currency ?? data.settings.baseCurrency
        }
    }

    func save() {
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
