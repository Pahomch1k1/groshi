import SwiftUI
import GroshiCore

/// Spendee-style entry: 1) pick a category on a grey sheet, 2) the sheet takes the category's colour and
/// a calculator replaces the grid. Editing opens directly on step 2.
struct AddTransactionView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let editing: Txn?

    enum Stage { case category, amount }
    @State private var stage: Stage = .category
    @State private var kind: TxKind = .expense
    @State private var categoryID: UUID?
    @State private var expr = ""
    @State private var currency = "UAH"
    @State private var walletID: UUID?
    @State private var toWalletID: UUID?
    @State private var toAmountText = ""
    @State private var date = Date()
    @State private var note = ""
    @State private var tags: [String] = []
    @State private var frequency: Frequency?
    @State private var showMenu = false
    @State private var menuKind: TxKind = .expense
    @State private var showDate = false
    @State private var showNewCategory = false
    @State private var showNewLabel = false
    @State private var newLabel = ""
    @State private var shake = 0
    @State private var loaded = false
    @FocusState private var noteFocused: Bool
    @FocusState private var creditFocused: Bool

    init(editing: Txn?) { self.editing = editing }

    var category: FinCategory? { categoryID.flatMap { store.data.category($0) } }
    var amountMinor: Int64 { Calculator.minor(expr, currency: currency) ?? 0 }
    var tint: Color { kind == .transfer ? Color(hex: "#8FA3BC") : Color(hex: category?.colorHex ?? "#A3ACB6") }
    var haptics: Bool { store.data.settings.haptics }

    var body: some View {
        ZStack(alignment: .top) {
            background.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                headerBlock
                    .padding(.top, 2)
                descriptionCard
                    .padding(.horizontal, 16)
                    .padding(.top, stage == .category ? 14 : 8)
                if stage == .category {
                    categoryGrid
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .bottom).combined(with: .opacity)))
                } else {
                    amountStage
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
            }
            if showMenu {
                Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { closeMenu() }
                categoryMenu
                    .padding(.top, 58)
                    .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: stage)
        .animation(.easeInOut(duration: 0.35), value: categoryID)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showMenu)
        .presentationDetents([.large])
        .presentationCornerRadius(30)
        .presentationBackground(.clear)
        .onAppear(perform: load)
        .sheet(isPresented: $showNewCategory) {
            CategoryEditor(category: nil, kind: kind == .income ? .income : .expense) { c in pick(c) }
        }
        .sheet(isPresented: $showDate) {
            DateSheet(date: $date).presentationDetents([.medium, .large])
        }
        .alert(L("Новая метка"), isPresented: $showNewLabel) {
            TextField(L("Название"), text: $newLabel)
            Button(L("Отмена"), role: .cancel) { newLabel = "" }
            Button(L("Добавить")) {
                let name = newLabel.trimmingCharacters(in: .whitespaces)
                newLabel = ""
                guard !name.isEmpty else { return }
                if let existing = store.data.labelNamed(name) { toggleTag(existing.name); return }
                if store.perform(.upsertLabel(TxLabel(name: name)), label: L("Метка создана: ") + name, toast: false) { toggleTag(name) }
            }
        }
    }

    // MARK: Background & header

    var background: some View {
        ZStack {
            Palette.background
            if stage == .category {
                LinearGradient(colors: [Color.dynamic("#DFE1E5", "#1C1C1E"), Palette.background], startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.22), Palette.background], startPoint: .top, endPoint: .bottom)
            }
        }
    }

    var topBar: some View {
        HStack {
            CircleButton(systemImage: "xmark") { dismiss() }
                .accessibilityIdentifier("add-close")
            Spacer()
            if stage == .amount && editing == nil {
                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { stage = .category }
                } label: {
                    Image(systemName: "square.grid.2x2").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.primary)
                        .frame(width: 36, height: 36).background(Palette.card.opacity(0.92), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.9))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    var headerBlock: some View {
        VStack(spacing: 6) {
            Button {
                guard stage == .amount else { return }
                menuKind = kind == .income ? .income : .expense
                Haptics.tap(enabled: haptics)
                showMenu.toggle()
            } label: {
                VStack(spacing: 4) {
                    Group {
                        if stage == .category {
                            CategoryPlaceholderIcon(size: 54)
                        } else if kind == .transfer {
                            TransferIcon(size: 52).background(Palette.card, in: Circle())
                        } else {
                            CategoryIconView(category: category, size: 52, style: .white)
                        }
                    }
                    .transition(.scale.combined(with: .opacity))
                    if stage == .amount {
                        HStack(spacing: 4) {
                            Text(kind == .transfer ? L("Перевод") : (category?.name ?? ""))
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.primary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("category-switch")

            VStack(spacing: 2) {
                if Calculator.hasOperator(expr) {
                    Text(expr).font(.system(size: 15, weight: .medium).monospacedDigit()).foregroundStyle(Palette.textSecondary)
                        .transition(.opacity)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(amountText)
                        .font(.system(size: 36, weight: .bold).monospacedDigit())
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("amount-display")
                    Menu {
                        ForEach(Currencies.common, id: \.self) { c in Button(c + "  " + Currencies.symbol(c)) { currency = c } }
                    } label: {
                        HStack(spacing: 2) {
                            Text(currency).font(.system(size: 26, weight: .bold))
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.textSecondary)
                        }
                        .foregroundStyle(Color.primary)
                    }
                    .accessibilityIdentifier("currency-menu")
                }
                .lineLimit(1).minimumScaleFactor(0.5)
                .modifier(ShakeEffect(shakes: CGFloat(shake)))
            }
            .padding(.horizontal, 20)
            .animation(.snappy(duration: 0.18), value: expr)
        }
    }

    var amountText: String {
        if expr.isEmpty { return "0" }
        if Calculator.hasOperator(expr) {
            return MoneyMath.format(amountMinor, currency: currency, symbol: false)
        }
        return AddTransactionView.grouped(expr)
    }

    // MARK: Description & labels

    var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("Опишите операцию"), text: $note, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...3)
                .focused($noteFocused)
                .accessibilityIdentifier("note-field")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button { showNewLabel = true } label: {
                        Image(systemName: "tag.fill").font(.system(size: 12)).foregroundStyle(Color.primary)
                            .frame(width: 30, height: 30).background(Palette.bubble.opacity(0.85), in: Circle())
                    }
                    .accessibilityIdentifier("add-label")
                    ForEach(labelOrder, id: \.self) { name in
                        Chip(text: name, selected: tags.contains(name))
                            .onTapGesture { Haptics.select(enabled: haptics); toggleTag(name) }
                    }
                }
            }
        }
        .padding(12)
        .background(Palette.card.opacity(stage == .category ? 0.75 : 0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.5), lineWidth: 0.6))
    }

    /// Selected labels first, then the rest in their saved order.
    var labelOrder: [String] {
        let all = store.data.sortedLabels.map { $0.name }
        return tags.filter { all.contains($0) } + all.filter { !tags.contains($0) }
    }

    func toggleTag(_ name: String) {
        withAnimation(.snappy) { if tags.contains(name) { tags.removeAll { $0 == name } } else { tags.append(name) } }
    }

    // MARK: Stage 1 — category grid

    var categoryGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Выберите категорию"))
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.top, 16)
            ScrollView {
                CategoryGrid(kind: kind == .income ? .income : .expense, iconSize: 52, onTap: { pick($0) }) {
                    Button { showNewCategory = true } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "plus").font(.system(size: 21, weight: .regular)).foregroundStyle(Palette.accent)
                                .frame(width: 52, height: 52).background(Palette.accent.opacity(0.16), in: Circle())
                            Text(L("Создать категорию")).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                                .lineLimit(1).minimumScaleFactor(0.92)
                        }
                    }
                    .buttonStyle(PressableStyle(scale: 0.9))
                    .accessibilityIdentifier("create-category")
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 84)
            }
            .scrollIndicators(.hidden)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        }
        .overlay(alignment: .bottom) { kindBar.padding(.bottom, 8) }
    }

    /// [Expenses | Income] [Transfer]
    var kindBar: some View {
        HStack(spacing: 8) {
            KindSegment(kind: $kind, haptics: haptics)
            Button {
                Haptics.select(enabled: haptics)
                startTransfer()
            } label: {
                Text(L("Перевод")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.primary)
                    .padding(.horizontal, 14).frame(height: 46)
                    .background(Palette.card, in: Capsule()).shadow(color: Palette.shadow, radius: 6, y: 2)
            }
            .buttonStyle(PressableStyle(scale: 0.94))
            .accessibilityIdentifier("kind-transfer")
        }
        .padding(.horizontal, 16)
    }

    // MARK: Stage 2 — calculator

    var amountStage: some View {
        VStack(spacing: 10) {
            chipsRow
                .padding(.top, 6)
            Spacer(minLength: 0)
            if !noteFocused && !creditFocused {
                keypad
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Button(action: save) {
                Text(editing == nil ? L("Добавить операцию") : L("Сохранить"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(canSave ? Palette.accent : Palette.accent.opacity(0.45), in: Capsule())
                    .shadow(color: Palette.accent.opacity(canSave ? 0.35 : 0), radius: 9, y: 4)
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityIdentifier("save-button")
        }
        .animation(.snappy, value: noteFocused || creditFocused)
    }

    var canSave: Bool {
        guard amountMinor > 0 else { return false }
        if kind == .transfer { return toWalletID != nil && toWalletID != walletID }
        return categoryID != nil
    }

    var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { showDate = true } label: { Chip(text: dateLabel, systemImage: "calendar") }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chip-date")
                walletMenu(selection: $walletID, prefix: kind == .transfer ? L("Откуда") : nil, id: "chip-wallet")
                if kind == .transfer {
                    Image(systemName: "arrow.right").foregroundStyle(Palette.textSecondary)
                    walletMenu(selection: $toWalletID, prefix: L("Куда"), id: "chip-to-wallet", excluding: walletID)
                    if let to = toWalletID.flatMap({ store.data.wallet($0) }), to.currency != currency {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.to.line").font(.system(size: 11, weight: .semibold))
                            TextField(creditPlaceholder(to), text: $toAmountText)
                                .keyboardType(.decimalPad).focused($creditFocused).frame(width: 80)
                            Text(to.currency)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Palette.bubble.opacity(0.85), in: Capsule())
                    }
                } else {
                    Menu {
                        Button(L("Не повторять")) { frequency = nil }
                        ForEach(Frequency.allCases, id: \.self) { f in Button(Self.frequencyName(f)) { frequency = f } }
                    } label: {
                        Chip(text: frequency.map(Self.frequencyName) ?? L("Повтор"), systemImage: "arrow.triangle.2.circlepath", selected: frequency != nil)
                    }
                    .accessibilityIdentifier("chip-repeat")
                }
            }
            .padding(.horizontal, 16)
        }
    }

    func walletMenu(selection: Binding<UUID?>, prefix: String?, id: String, excluding: UUID? = nil) -> some View {
        let w = selection.wrappedValue.flatMap { store.data.wallet($0) }
        return Menu {
            ForEach(store.data.activeWallets.filter { $0.id != excluding }) { wal in
                Button("\(wal.name) · \(wal.currency)") {
                    selection.wrappedValue = wal.id
                    if selection.wrappedValue == walletID, editing == nil || expr.isEmpty { currency = wal.currency }
                }
            }
        } label: {
            Chip(text: (prefix.map { $0 + ": " } ?? "") + (w?.name ?? "—"), systemImage: "wallet.pass")
        }
        .accessibilityIdentifier(id)
    }

    var dateLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L("Сегодня") }
        if cal.isDateInYesterday(date) { return L("Вчера") }
        let f = DateFormatter(); f.locale = Lang.locale; f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: date)
    }

    func creditPlaceholder(_ to: Wallet) -> String {
        guard amountMinor > 0, let c = store.data.settings.converter.convert(amountMinor, from: currency, to: to.currency) else { return "0" }
        return MoneyMath.plainString(c, currency: to.currency).replacingOccurrences(of: ".", with: ",")
    }

    static func frequencyName(_ f: Frequency) -> String {
        switch f {
        case .daily: return L("Каждый день")
        case .weekly: return L("Каждую неделю")
        case .monthly: return L("Каждый месяц")
        case .yearly: return L("Каждый год")
        }
    }

    var keypad: some View {
        let rows: [[String]] = [["1", "2", "3", "÷"], ["4", "5", "6", "×"], ["7", "8", "9", "−"], [",", "0", "⌫", "+"]]
        return VStack(spacing: 8) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { k in
                        Button {
                            Haptics.tap(enabled: haptics)
                            expr = Calculator.press(k, to: expr)
                        } label: {
                            Group {
                                if k == "⌫" { Image(systemName: "delete.left.fill") } else { Text(k) }
                            }
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(Palette.card.opacity(0.9), in: Capsule())
                            .shadow(color: Palette.shadow, radius: 3, y: 1)
                        }
                        .buttonStyle(PressableStyle(scale: 0.92))
                        .accessibilityIdentifier("key-\(k)")
                    }
                }
            }
        }
    }

    // MARK: Category menu (glass dropdown)

    var categoryMenu: some View {
        let list = store.data.categories(of: menuKind)
        let other: TxKind = menuKind == .expense ? .income : .expense
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                menuRow(title: L("Перевод"), icon: nil, checked: kind == .transfer) { startTransfer(); closeMenu() }
                menuRow(title: other == .income ? L("Доходы") : L("Расходы"), icon: nil, checked: false, chevron: true) {
                    withAnimation(.snappy) { menuKind = other }
                }
                Divider().padding(.vertical, 4).padding(.horizontal, 14)
                Text(menuKind == .expense ? L("Расходы") : L("Доходы"))
                    .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 22).padding(.vertical, 4)
                ForEach(list) { c in
                    menuRow(title: c.name, icon: c, checked: kind != .transfer && categoryID == c.id) { pick(c); closeMenu() }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: 250, height: min(430, CGFloat(list.count) * 40 + 130))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(Palette.card.opacity(0.45), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.6), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        .accessibilityIdentifier("category-menu")
    }

    func menuRow(title: String, icon: FinCategory?, checked: Bool, chevron: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.select(enabled: haptics); action() }) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).opacity(checked ? 1 : 0).frame(width: 14)
                if let icon {
                    CategoryIconView(category: icon, size: 22).frame(width: 22)
                }
                Text(title).font(.system(size: 15)).lineLimit(1)
                Spacer()
                if chevron { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)) }
            }
            .foregroundStyle(Color.primary)
            .frame(minHeight: 22)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func closeMenu() { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showMenu = false } }

    // MARK: Actions

    func pick(_ c: FinCategory) {
        Haptics.select(enabled: haptics)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            kind = c.kind
            categoryID = c.id
            stage = .amount
        }
    }

    func startTransfer() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            kind = .transfer
            categoryID = nil
            if toWalletID == nil || toWalletID == walletID { toWalletID = store.data.activeWallets.first { $0.id != walletID }?.id }
            stage = .amount
        }
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        let data = store.data
        if let t = editing {
            kind = t.kind
            expr = MoneyMath.plainString(t.amountMinor, currency: t.currency).replacingOccurrences(of: ".00", with: "").replacingOccurrences(of: ".", with: ",")
            currency = t.currency; walletID = t.walletID; date = t.date; note = t.note; tags = t.tags
            categoryID = t.isTransfer ? nil : t.categoryID
            toWalletID = t.toWalletID
            if t.isTransfer && t.creditedCurrency != t.currency {
                toAmountText = MoneyMath.plainString(t.creditedMinor, currency: t.creditedCurrency).replacingOccurrences(of: ".", with: ",")
            }
            frequency = t.recurringID.flatMap { id in data.recurring.first { $0.id == id && $0.isActive } }?.frequency
            stage = .amount
        } else {
            walletID = data.defaultWallet?.id
            currency = data.defaultWallet?.currency ?? data.settings.baseCurrency
        }
    }

    func fail() {
        Haptics.error(enabled: haptics)
        withAnimation(.default) { shake += 1 }
    }

    func save() {
        let minor = amountMinor
        guard minor > 0, let wal = walletID ?? store.data.defaultWallet?.id else { fail(); return }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var muts: [Mutation] = []
        var label = ""
        if kind == .transfer {
            guard let to = toWalletID.flatMap({ store.data.wallet($0) }), to.id != wal else { fail(); return }
            var credited: Int64? = nil
            if to.currency != currency {
                if !toAmountText.isEmpty {
                    guard let v = MoneyMath.parseMinor(toAmountText, currency: to.currency), v > 0 else { fail(); return }
                    credited = v
                } else if let v = store.data.settings.converter.convert(minor, from: currency, to: to.currency) {
                    credited = v
                } else { fail(); return }
            }
            if let t = editing {
                muts.append(.updateTransactions(ids: [t.id], changes: TxChanges(
                    kind: .transfer, amountMinor: minor, currency: currency, walletID: wal, date: date, note: cleanNote,
                    transfer: TransferTarget(toWalletID: to.id, toAmountMinor: credited, toCurrency: to.currency), labels: tags)))
                label = L("Операция изменена")
            } else {
                var tx = Txn.transfer(from: wal, to: to.id, amountMinor: minor, currency: currency, toAmountMinor: credited,
                                      toCurrency: to.currency, date: date, note: cleanNote)
                tx.tags = tags
                muts.append(.addTransactions([tx]))
                label = L("Перевод") + " " + Fmt.code(minor, currency)
            }
        } else {
            guard let cat = categoryID else { fail(); return }
            if let t = editing {
                muts.append(.updateTransactions(ids: [t.id], changes: TxChanges(kind: kind, amountMinor: minor, currency: currency,
                                                                                 categoryID: cat, walletID: wal, date: date, note: cleanNote, labels: tags)))
                // Repeat setting on an existing transaction.
                let rule = t.recurringID.flatMap { id in store.data.recurring.first { $0.id == id } }
                if let f = frequency {
                    var tpl = t
                    tpl.kind = kind; tpl.amountMinor = minor; tpl.currency = currency; tpl.categoryID = cat; tpl.walletID = wal; tpl.note = cleanNote; tpl.tags = tags
                    if var r = rule {
                        r.frequency = f; r.template = tpl; r.isActive = true
                        muts.append(.upsertRecurring(r))
                    } else {
                        let r = RecurringRule(template: tpl, frequency: f, nextDate: Recurrence.advance(date, by: f, calendar: store.calendar))
                        muts.append(.upsertRecurring(r))
                        muts.append(.updateTransactions(ids: [t.id], changes: TxChanges(recurringID: r.id)))
                    }
                } else if let r = rule {
                    muts.append(.deleteRecurring(id: r.id))
                }
                label = L("Операция изменена")
            } else {
                var tx = Txn(kind: kind, amountMinor: minor, currency: currency, categoryID: cat, walletID: wal, date: date,
                             note: cleanNote, labels: tags)
                if let f = frequency {
                    let rule = RecurringRule(template: tx, frequency: f, nextDate: Recurrence.advance(date, by: f, calendar: store.calendar))
                    tx.recurringID = rule.id
                    muts.append(.upsertRecurring(rule))
                }
                muts.insert(.addTransactions([tx]), at: 0)
                label = (kind == .expense ? L("Расход") : L("Доход")) + " " + Fmt.code(minor, currency)
            }
        }
        if store.perform(muts.count == 1 ? muts[0] : .batch(muts), label: label) { dismiss() }
    }

    /// "15000,5" → "15 000,5" for display.
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
}

/// Expenses | Income capsule with a sliding white pill.
struct KindSegment: View {
    @Binding var kind: TxKind
    var haptics: Bool
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach([TxKind.expense, .income], id: \.self) { k in
                let on = kind == k || (k == .expense && kind == .transfer)
                Text(k == .expense ? L("Расходы") : L("Доходы"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(on ? 1 : 0.75))
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background {
                        if on { Capsule().fill(Palette.card).shadow(color: Palette.shadow, radius: 5, y: 2).matchedGeometryEffect(id: "pill", in: ns) }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        Haptics.select(enabled: haptics)
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { kind = k }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier(k == .expense ? "kind-expense" : "kind-income")
            }
        }
        .padding(3)
        .background(Palette.bubble.opacity(0.95), in: Capsule())
    }
}

struct DateSheet: View {
    @Binding var date: Date
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            DatePicker("", selection: $date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle(L("Дата"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(L("Сегодня")) { date = Date() } }
                    ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() } }
                }
        }
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
