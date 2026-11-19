import SwiftUI
import GroshiCore

/// Category glyph in a pastel circle (SF Symbol, emoji or custom image).
struct CategoryIconView: View {
    @Environment(Store.self) private var store
    var icon: CategoryIcon
    var colorHex: String
    var size: CGFloat = 40

    var body: some View {
        let color = Color(hex: colorHex)
        ZStack {
            Circle().fill(color.opacity(0.18))
            switch icon {
            case .symbol(let name):
                Image(systemName: UIImage(systemName: name) != nil ? name : "tag.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
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
        .frame(width: size, height: size)
    }
}

extension CategoryIconView {
    init(category: GroshiCore.Category?, size: CGFloat = 40) {
        self.icon = category?.icon ?? .symbol("questionmark")
        self.colorHex = category?.colorHex ?? "#8395A7"
        self.size = size
    }
}

/// Floating capsule tab bar with a bubble that slides to the active tab.
struct BubbleTabBar: View {
    @Binding var selection: AppTab
    var haptics: Bool
    @Namespace private var ns

    struct Item: Identifiable { let id: AppTab; let title: String; let icon: String }
    var items: [Item] {
        [Item(id: .home, title: L("Главная"), icon: "house"),
         Item(id: .overview, title: L("Обзор"), icon: "chart.pie"),
         Item(id: .assistant, title: L("Ассистент"), icon: "sparkles"),
         Item(id: .more, title: L("Ещё"), icon: "ellipsis")]
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let active = selection == item.id
                Button {
                    guard selection != item.id else { return }
                    Haptics.select(enabled: haptics)
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { selection = item.id }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: active ? item.icon + (item.icon == "ellipsis" || item.icon == "sparkles" ? "" : ".fill") : item.icon)
                            .font(.system(size: 18, weight: active ? .semibold : .regular))
                            .symbolEffect(.bounce, value: active)
                            .frame(height: 22)
                        Text(item.title).font(.system(size: 10, weight: active ? .semibold : .medium))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(active ? Palette.accent : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if active {
                            Capsule(style: .continuous)
                                .fill(Palette.bubble)
                                .matchedGeometryEffect(id: "bubble", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.9))
                .accessibilityIdentifier("tab-\(item.id)")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(5)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
    }
}

/// Bottom toast with optional Undo.
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
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .task(id: toast.id) {
            try? await Task.sleep(for: .seconds(toast.canUndo ? 5 : 3.5))
            withAnimation(.easeOut) { if store.toast?.id == toast.id { store.toast = nil } }
        }
    }
}

/// Round floating action button with press animation.
struct FAB: View {
    var systemImage: String
    var color: Color = Palette.accent
    var size: CGFloat = 58
    var onLongPress: (() -> Void)? = nil
    var action: () -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .shadow(color: color.opacity(0.45), radius: 12, y: 6)
            .scaleEffect(pressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .onLongPressGesture(minimumDuration: 0.45, perform: { onLongPress?() }, onPressingChanged: { pressed = $0 })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}

/// Toolbar button that opens the assistant (available on every screen, including sheets).
struct AssistantToolbarButton: View {
    @Environment(AssistantViewModel.self) private var ai
    var context: String? = nil
    @State private var show = false
    var body: some View {
        Button {
            ai.prepare(context: context, startVoice: false)
            show = true
        } label: {
            Image(systemName: "sparkles")
        }
        .accessibilityLabel(L("Ассистент"))
        .sheet(isPresented: $show) {
            AssistantView(isSheet: true)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// "‹ Ноябрь 2026 ›" period switcher with kind menu.
struct PeriodSwitcher: View {
    @Environment(Store.self) private var store
    @State private var showCustom = false

    var body: some View {
        @Bindable var store = store
        let cal = store.calendar
        HStack(spacing: 6) {
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 34, height: 34) }
                .disabled(!store.period.canStep)
                .accessibilityIdentifier("period-prev")
            Menu {
                ForEach([PeriodKind.week, .month, .year, .all], id: \.self) { k in
                    Button {
                        withAnimation(.snappy) { store.period = Period.containing(Date(), kind: k, calendar: cal) }
                    } label: {
                        if store.period.kind == k { Label(Fmt.kindName(k), systemImage: "checkmark") } else { Text(Fmt.kindName(k)) }
                    }
                }
                Button(Fmt.kindName(.custom) + "…") { showCustom = true }
            } label: {
                HStack(spacing: 4) {
                    Text(Fmt.periodTitle(store.period, calendar: cal))
                        .font(.subheadline.weight(.semibold))
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Palette.bubble, in: Capsule())
            }
            .accessibilityIdentifier("period-menu")
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 34, height: 34) }
                .disabled(!store.period.canStep)
                .accessibilityIdentifier("period-next")
        }
        .font(.subheadline.weight(.semibold))
        .tint(.primary)
        .sheet(isPresented: $showCustom) { CustomPeriodSheet().presentationDetents([.medium]) }
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -40 { step(1) } else if v.translation.width > 40 { step(-1) }
        })
    }

    func step(_ n: Int) {
        guard store.period.canStep else { return }
        Haptics.select(enabled: store.data.settings.haptics)
        withAnimation(.snappy) { store.period = store.period.shifted(by: n, calendar: store.calendar) }
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

/// One transaction row card.
struct TransactionRow: View {
    @Environment(Store.self) private var store
    var tx: Txn

    var body: some View {
        let cat = store.data.category(tx.categoryID)
        let wallet = store.data.wallet(tx.walletID)
        HStack(spacing: 12) {
            CategoryIconView(category: cat, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(cat?.name ?? L("Без категории")).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: wallet?.symbol ?? "wallet.pass").font(.caption2)
                    Text(wallet?.name ?? "—")
                    if !tx.note.isEmpty { Text("·"); Text(tx.note).lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.signed(tx))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.amount(tx.kind))
                if tx.currency != store.data.settings.baseCurrency,
                   let conv = store.data.settings.converter.convert(tx.amountMinor, from: tx.currency, to: store.data.settings.baseCurrency) {
                    Text("≈ " + Fmt.money(conv, store.data.settings.baseCurrency)).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(Fmt.time(tx.date)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
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
