import SwiftUI
import GroshiCore

/// Category grid (4 columns) used when adding a transaction and in "Categories".
/// Press and hold a category to lift it, drag it to another place — the others shift — and release:
/// the order is saved (`reorderCategories`), so every screen and the assistant see the same order.
struct CategoryGrid<Trailing: View>: View {
    @Environment(Store.self) private var store
    let kind: TxKind
    var iconSize: CGFloat = 52
    var spacing: CGFloat = 10
    let onTap: (FinCategory) -> Void
    @ViewBuilder var trailing: () -> Trailing

    @State private var order: [UUID] = []
    @State private var dragging: UUID?
    @State private var dragPoint: CGPoint = .zero
    @State private var frames: [UUID: CGRect] = [:]
    @State private var lastDragEnd = Date.distantPast
    @GestureState private var holding = false

    var body: some View {
        let ids = dragging == nil ? CategoryOrder.ids(store.data, kind) : order
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: CategoryOrder.columns), spacing: spacing) {
            ForEach(ids, id: \.self) { id in
                if let c = store.data.category(id) { cell(c) }
            }
            trailing()
        }
        .coordinateSpace(name: "catgrid")
        .onPreferenceChange(CategoryCellFrames.self) { frames = $0 }
        .onChange(of: holding) { _, now in UITrace.log("holding \(now)"); if !now { finishDrag() } }
    }

    func cell(_ c: FinCategory) -> some View {
        let lifted = dragging == c.id
        return Button {
            // A release after dragging is not a tap.
            guard dragging == nil, Date().timeIntervalSince(lastDragEnd) > 0.4 else { return }
            onTap(c)
        } label: {
            VStack(spacing: 5) {
                CategoryIconView(category: c, size: iconSize, style: .white)
                    .shadow(color: lifted ? Color.black.opacity(0.18) : .clear, radius: 10, y: 6)
                Text(c.name).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.92)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .background(GeometryReader { g in
            Color.clear.preference(key: CategoryCellFrames.self, value: [c.id: g.frame(in: .named("catgrid"))])
        })
        .scaleEffect(lifted ? 1.15 : 1)
        .offset(lifted ? liftOffset(c.id) : .zero)
        .opacity(dragging != nil && !lifted ? 0.8 : 1)
        .zIndex(lifted ? 10 : 0)
        .simultaneousGesture(reorder(c))
        .accessibilityIdentifier("category-\(c.name)")
    }

    func liftOffset(_ id: UUID) -> CGSize {
        guard let f = frames[id] else { return .zero }
        return CGSize(width: dragPoint.x - f.midX, height: dragPoint.y - f.midY)
    }

    func reorder(_ c: FinCategory) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("catgrid")))
            .updating($holding) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if dragging == nil {
                    UITrace.log("drag start \(c.name) frames=\(frames.count) own=\(frames[c.id].map { "\($0)" } ?? "nil")")
                    order = CategoryOrder.ids(store.data, kind)
                    if let f = frames[c.id] { dragPoint = CGPoint(x: f.midX, y: f.midY) }
                    Haptics.select(enabled: store.data.settings.haptics)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { dragging = c.id }
                }
                guard let drag else { return }
                dragPoint = drag.location
                if let target = frames.first(where: { $0.key != c.id && order.contains($0.key) && $0.value.contains(drag.location) })?.key,
                   let from = order.firstIndex(of: c.id), let to = order.firstIndex(of: target) {
                    UITrace.log("drag over \(store.data.category(target)?.name ?? "?") at \(drag.location) \(from)→\(to)")
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        order.remove(at: from)
                        order.insert(c.id, at: to)
                    }
                    Haptics.tap(enabled: store.data.settings.haptics)
                }
            }
            .onEnded { _ in finishDrag() }
    }

    func finishDrag() {
        guard dragging != nil else { return }
        let newOrder = order
        UITrace.log("drag end at \(dragPoint) changed=\(newOrder != CategoryOrder.ids(store.data, kind))")
        if newOrder != CategoryOrder.ids(store.data, kind) {
            _ = store.perform(.reorderCategories(kind: kind, order: newOrder), label: L("Порядок категорий"), toast: false)
        }
        lastDragEnd = Date()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragging = nil }
    }
}

struct CategoryCellFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
