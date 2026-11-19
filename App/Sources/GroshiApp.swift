import SwiftUI
import GroshiCore

/// `Category` clashes with the Objective-C runtime type on Apple platforms.
typealias FinCategory = GroshiCore.Category

@main
struct GroshiApp: App {
    @State private var store: Store
    @State private var assistant: AssistantViewModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let s = Store()
        _store = State(initialValue: s)
        _assistant = State(initialValue: AssistantViewModel(store: s))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(assistant)
                .preferredColorScheme(store.data.settings.theme.colorScheme)
                .environment(\.locale, Lang.locale)
                .id(store.data.settings.language) // rebuild all text on language change
                .tint(Palette.accent)
                .onChange(of: scenePhase) { _, phase in if phase == .active { store.catchUpRecurring() } }
        }
    }
}

/// Root: the three tabs stay alive (state and scroll position are kept) and are cross-faded;
/// the tab bar and the "+" button float in fixed overlays that never take part in the content layout.
///
/// The 0.1 jump came from (1) recreating each tab's NavigationStack with a large title and a search bar
/// on every switch, (2) a scale transition on the content, and (3) a spring animation applied to the
/// container that held the "+" button (shown only on some tabs) together with the tab bar.
struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(AssistantViewModel.self) private var ai
    @State private var showAdd = false

    var body: some View {
        @Bindable var store = store
        @Bindable var ai = ai
        ZStack {
            Palette.background.ignoresSafeArea()
            tab(.home) { HomeView() }
            tab(.overview) { OverviewView() }
            tab(.more) { MoreView() }
        }
        .overlay(alignment: .bottomTrailing) {
            if store.selectedTab != .more {
                FAB(systemImage: "plus", onLongPress: {
                    Haptics.success(enabled: store.data.settings.haptics)
                    ai.openSheet(context: nil, startVoice: true)
                }) {
                    Haptics.tap(enabled: store.data.settings.haptics)
                    showAdd = true
                }
                .accessibilityIdentifier("add-button")
                .padding(.trailing, 18)
                .padding(.bottom, 92)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let t = store.toast {
                    ToastView(toast: t).transition(.move(edge: .bottom).combined(with: .opacity))
                }
                SpendTabBar(selection: $store.selectedTab, haptics: store.data.settings.haptics)
                    .padding(.horizontal, 24)
            }
            .padding(.bottom, 2)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.selectedTab == .more)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showAdd) {
            AddTransactionView(editing: nil)
        }
        .sheet(isPresented: $ai.sheetVisible) {
            AssistantView(isSheet: true)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert(L("Восстановление данных"), isPresented: Binding(get: { store.startupNotice != nil }, set: { if !$0 { store.startupNotice = nil } })) {
            Button("OK") { store.startupNotice = nil }
        } message: {
            Text(store.startupNotice ?? "")
        }
    }

    /// Keeps the tab in the hierarchy; only its opacity and hit-testing change.
    func tab<V: View>(_ t: AppTab, @ViewBuilder _ content: () -> V) -> some View {
        let active = store.selectedTab == t
        return content()
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .animation(.easeInOut(duration: 0.16), value: active)
    }
}

/// Bottom padding so scroll content clears the floating tab bar and "+".
extension View {
    func tabBarSafeArea() -> some View {
        safeAreaInset(edge: .bottom) { Color.clear.frame(height: 96) }
    }
}
