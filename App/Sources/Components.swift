import SwiftUI
import GroshiCore

// MARK: Icons

/// Category glyph in a circle. `.pastel` = tinted circle (lists), `.white` = white circle (category grid, detail).
struct CategoryIconView: View {
    enum Style { case pastel, white }
    @Environment(Store.self) private var store
    var icon: CategoryIcon
    var colorHex: String
    var size: CGFloat = 30
    var style: Style = .pastel

    var body: some View {
        let color = Color(hex: colorHex)
        ZStack {
            switch style {
            case .pastel:
                Circle().fill(LinearGradient(colors: [color.opacity(0.26), color.opacity(0.12)], startPoint: .top, endPoint: .bottom))
            case .white:
                Circle().fill(Palette.card).shadow(color: Palette.shadow, radius: 4, y: 1)
            }
            glyph(color)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder func glyph(_ color: Color) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: UIImage(systemName: name) != nil ? name : "tag.fill")
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(color)
        case .emoji(let e):
            Text(e).font(.system(size: size * 0.5))
        case .image(let file):
            if let ui = UIImage(contentsOfFile: store.iconURL(file).path) {
                Image(uiImage: ui).resizable().scaledToFill()
                    .frame(width: size * 0.92, height: size * 0.92)
                    .clipShape(Circle())
            } else {
                Image(systemName: "photo").foregroundStyle(color)
            }
        }
    }
}

extension CategoryIconView {
    init(category: GroshiCore.Category?, size: CGFloat = 30, style: Style = .pastel) {
        self.icon = category?.icon ?? .symbol("questionmark")
        self.colorHex = category?.colorHex ?? "#8395A7"
        self.size = size
        self.style = style
    }
}

/// Neutral glyph for transfers between own wallets.
struct TransferIcon: View {
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(Color(hex: "#5B6573"))
            .frame(width: size, height: size)
            .background(Color(hex: "#8395A7").opacity(0.18), in: Circle())
    }
}

/// Icon for any transaction (category or transfer).
struct TxIcon: View {
    @Environment(Store.self) private var store
    var tx: Txn
    var size: CGFloat = 34
    var body: some View {
        if tx.isTransfer { TransferIcon(size: size) } else { CategoryIconView(category: store.data.category(tx.categoryID), size: size) }
    }
}

/// Grey "pick a category" glyph from Spendee's empty entry screen.
struct CategoryPlaceholderIcon: View {
    var size: CGFloat = 46
    var body: some View {
        ZStack {
            Circle().fill(Palette.card.opacity(0.7))
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow { Image(systemName: "star.fill"); Image(systemName: "triangle.fill") }
                GridRow { Image(systemName: "heart.fill"); Image(systemName: "bag.fill") }
            }
            .font(.system(size: size * 0.17, weight: .bold))
            .foregroundStyle(Color(hex: "#7C8794"))
        }
        .frame(width: size, height: size)
    }
}

// MARK: Tab bar

/// Floating translucent capsule with a bubble that slides horizontally to the active tab.
/// Fixed size: icons and labels never change dimensions, so nothing around it moves.
struct SpendTabBar: View {
    @Binding var selection: AppTab
    var haptics: Bool
    @Namespace private var ns

    struct Item: Identifiable { let id: AppTab; let title: String; let icon: String; let activeIcon: String }
    var items: [Item] {
        [Item(id: .home, title: L("Главная"), icon: "house", activeIcon: "house.fill"),
         Item(id: .overview, title: L("Обзор"), icon: "chart.pie", activeIcon: "chart.pie.fill"),
         Item(id: .more, title: L("Ещё"), icon: "ellipsis", activeIcon: "ellipsis")]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let active = selection == item.id
                ZStack {
                    if active {
                        Capsule(style: .continuous)
                            .fill(Palette.bubble.opacity(0.9))
                            .matchedGeometryEffect(id: "bubble", in: ns)
                    }
                    VStack(spacing: 2) {
                        Image(systemName: active ? item.activeIcon : item.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 24, height: 20)
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(active ? Palette.accent : Color.primary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard selection != item.id else { return }
                    Haptics.select(enabled: haptics)
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = item.id }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("tab-\(item.id)")
            }
        }
        .padding(4)
        .frame(height: 56)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .background(Palette.card.opacity(0.55), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
    }
}

// MARK: Buttons

/// Round floating "+" with press animation; long press triggers `onLongPress`.
struct FAB: View {
    var systemImage: String
    var color: Color = Palette.accent
    var size: CGFloat = 52
    var onLongPress: (() -> Void)? = nil
    var action: () -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .shadow(color: color.opacity(0.35), radius: 10, y: 4)
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .onLongPressGesture(minimumDuration: 0.45, perform: { onLongPress?() }, onPressingChanged: { pressed = $0 })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}

/// White circular icon button (header actions, close buttons).
struct CircleButton: View {
    var systemImage: String
    var size: CGFloat = 36
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: size, height: size)
                .background(Palette.card.opacity(0.92), in: Circle())
                .shadow(color: Palette.shadow, radius: 6, y: 2)
                .frame(width: max(size, 44), height: max(size, 44))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
    }
}

/// Scale-down press effect for buttons.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Toolbar/header button that opens the assistant (available on every screen, including sheets).
struct AssistantToolbarButton: View {
    @Environment(AssistantViewModel.self) private var ai
    var context: String? = nil
    var startVoice = false
    var label: AnyView? = nil
    @State private var show = false
    var body: some View {
        Button {
            ai.prepare(context: context, startVoice: startVoice)
            show = true
        } label: {
            if let label { label } else { Image(systemName: "sparkles") }
        }
        .accessibilityLabel(L("Ассистент"))
        .sheet(isPresented: $show) {
            AssistantView(isSheet: true)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: Period pager

/// "Oct 2026 | This month": horizontally scrolling periods, the selected one on a white capsule.
struct PeriodPager: View {
    @Environment(Store.self) private var store
    @State private var showCustom = false

    var body: some View {
        let cal = store.calendar
        let current = store.period
        Group {
            if current.canStep {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(periods(cal), id: \.start) { p in
                                let selected = p.start == current.start
                                Text(label(p, cal))
                                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                                    .foregroundStyle(selected ? Color.primary : Palette.textTertiary)
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .background {
                                        if selected { Capsule().fill(Palette.card).shadow(color: Palette.shadow, radius: 5, y: 2) }
                                    }
                                    .frame(height: 40)
                                    .contentShape(Rectangle())
                                    .id(p.start)
                                    .onTapGesture {
                                        Haptics.select(enabled: store.data.settings.haptics)
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.period = p }
                                    }
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.vertical, 2)
                    }
                    .onAppear { proxy.scrollTo(current.start, anchor: .center) }
                    .onChange(of: current.start) { _, s in withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { proxy.scrollTo(s, anchor: .center) } }
                }
            } else {
                Button { showCustom = true } label: {
                    Text(Fmt.periodTitle(current, calendar: cal))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.primary)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Palette.card).shadow(color: Palette.shadow, radius: 5, y: 2))
                        .frame(height: 40)
                        .contentShape(Rectangle())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
            }
        }
        .accessibilityIdentifier("period-pager")
        .sheet(isPresented: $showCustom) { CustomPeriodSheet().presentationDetents([.medium]) }
    }

    /// From the first transaction's period to the current one (at least 12 back).
    func periods(_ cal: Calendar) -> [Period] {
        let now = Period.containing(Date(), kind: store.period.kind, calendar: cal)
        let first = store.data.transactions.map(\.date).min() ?? Date()
        var list: [Period] = []
        var p = now
        var n = 0
        while (p.end > first || n < 12) && n < 240 {
            list.append(p)
            p = p.shifted(by: -1, calendar: cal)
            n += 1
        }
        if store.period.start > now.start { list.insert(store.period, at: 0) }
        return list.reversed()
    }

    func label(_ p: Period, _ cal: Calendar) -> String {
        let now = Period.containing(Date(), kind: p.kind, calendar: cal)
        if p.start == now.start {
            switch p.kind {
            case .week: return L("Эта неделя")
            case .month: return L("Этот месяц")
            case .year: return L("Этот год")
            default: break
            }
        }
        let f = DateFormatter(); f.locale = Lang.locale
        switch p.kind {
        case .month: f.setLocalizedDateFormatFromTemplate("LLL yyyy")
        case .year: f.setLocalizedDateFormatFromTemplate("yyyy")
        default: return Fmt.periodTitle(p, calendar: cal)
        }
        return f.string(from: p.start).capitalizedFirst.replacingOccurrences(of: #"\s*[гр]\.$"#, with: "", options: .regularExpression)
    }
}

struct CustomPeriodSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var to = Date()
    var body: some View {
        NavigationStack {
            Form {
                DatePicker(L("С"), selection: $from, displayedComponents: .date)
                DatePicker(L("По"), selection: $to, displayedComponents: .date)
            }
            .navigationTitle(L("Свой период"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Готово")) {
                        withAnimation(.snappy) { store.period = Period.custom(from: from, to: to, calendar: store.calendar) }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: Transaction rows

/// One row inside a day card: icon, category, optional wallet/note/labels, amount.
struct TransactionRow: View {
    @Environment(Store.self) private var store
    var tx: Txn

    var body: some View {
        let data = store.data
        let cat = data.category(tx.categoryID)
        let multiWallet = data.activeWallets.count > 1
        let subtitle: String? = tx.isTransfer ? Fmt.route(tx, data) : (multiWallet ? data.wallet(tx.walletID)?.name : nil)
        HStack(alignment: .center, spacing: 12) {
            TxIcon(tx: tx, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.isTransfer ? L("Перевод") : (cat?.name ?? L("Без категории")))
                    .font(.system(size: 15)).foregroundStyle(Color.primary).lineLimit(1)
                if let subtitle {
                    HStack(spacing: 4) {
                        Image(systemName: tx.isTransfer ? "arrow.left.arrow.right" : "wallet.pass").font(.system(size: 11))
                        Text(subtitle).lineLimit(1)
                    }
                    .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                }
                if !tx.note.isEmpty {
                    Text(tx.note).font(.system(size: 12)).foregroundStyle(Palette.textSecondary).lineLimit(2)
                }
                if !tx.tags.isEmpty {
                    Text(tx.tags.map { "#" + $0 }.joined(separator: " "))
                        .font(.system(size: 11)).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.txCode(tx))
                    .font(.system(size: 15).monospacedDigit())
                    .foregroundStyle(tx.kind == .income ? Palette.income : Color.primary)
                    .strikethrough(tx.isExcluded, color: Palette.textTertiary)
                if tx.recurringID != nil {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Day header + all its transactions in one white rounded card.
struct DayGroupView: View {
    @Environment(Store.self) private var store
    var group: DayGroup
    var onTap: (Txn) -> Void
    var onEdit: (Txn) -> Void

    var body: some View {
        let base = store.data.settings.baseCurrency
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Fmt.dayTitle(group.day, calendar: store.calendar))
                Spacer()
                Text(Fmt.code(group.net, base)).monospacedDigit()
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 16)

            VStack(spacing: 0) {
                ForEach(group.items) { tx in
                    TransactionRow(tx: tx)
                        .onTapGesture { Haptics.tap(enabled: store.data.settings.haptics); onTap(tx) }
                        .contextMenu {
                            Button { onEdit(tx) } label: { Label(L("Изменить"), systemImage: "pencil") }
                            Button {
                                var copy = tx
                                copy.id = UUID(); copy.date = Date(); copy.createdAt = Date(); copy.source = .manual; copy.recurringID = nil
                                store.perform(.addTransactions([copy]), label: L("Операция добавлена"))
                            } label: { Label(L("Повторить сегодня"), systemImage: "plus.square.on.square") }
                            Button(role: .destructive) {
                                store.perform(.deleteTransactions([tx.id]), label: L("Операция удалена"))
                            } label: { Label(L("Удалить"), systemImage: "trash") }
                        }
                        .accessibilityIdentifier("tx-row")
                        .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                }
            }
            .padding(.vertical, 4)
            .spendCard()
        }
    }
}

// MARK: Toast

struct ToastView: View {
    @Environment(Store.self) private var store
    var toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? Palette.expense : Palette.accent)
            Text(toast.text).font(.subheadline).lineLimit(3)
            Spacer(minLength: 0)
            if toast.canUndo && !store.undoStack.isEmpty {
                Button(L("Отменить")) {
                    store.toast = nil
                    store.undoWithToast()
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("toast-undo")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .task(id: toast.id) {
            try? await Task.sleep(for: .seconds(toast.canUndo ? 5 : 3.5))
            withAnimation(.easeOut) { if store.toast?.id == toast.id { store.toast = nil } }
        }
    }
}

// MARK: Misc

/// Card container used in settings-like screens.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .spendCard(radius: 18)
    }
}

/// Simple wrap for share sheets of generated files.
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct IdentifiableURL: Identifiable { let url: URL; var id: String { url.absoluteString } }

/// Capsule chip (labels, date, wallet).
struct Chip: View {
    var text: String
    var systemImage: String? = nil
    var selected = false
    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)) }
            Text(text).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(selected ? Palette.accent : Palette.bubble.opacity(0.85), in: Capsule())
    }
}
