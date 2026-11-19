import SwiftUI
import GroshiCore

/// `Category` clashes with the Objective-C runtime type on Apple platforms.
typealias FinCategory = GroshiCore.Category

@main
struct GroshiApp: App {
    @State private var store: Store
    @State private var assistant: AssistantViewModel

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
        }
    }
}

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(AssistantViewModel.self) private var ai
    @State private var showAdd = false

    var body: some View {
        @Bindable var store = store
        @Bindable var ai = ai
        ZStack(alignment: .bottom) {
            Group {
                switch store.selectedTab {
                case .home: HomeView()
                case .overview: OverviewView()
                case .assistant: AssistantView(isSheet: false)
                case .more: MoreView()
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 12) {
                if let t = store.toast {
                    ToastView(toast: t).transition(.move(edge: .bottom).combined(with: .opacity))
                }
                HStack(alignment: .bottom) {
                    Spacer()
                    if store.selectedTab == .home || store.selectedTab == .overview {
                        FAB(systemImage: "plus") {
                            Haptics.tap(enabled: store.data.settings.haptics)
                            showAdd = true
                        }
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                            Haptics.success(enabled: store.data.settings.haptics)
                            ai.openSheet(context: nil, startVoice: true)
                        })
                        .accessibilityIdentifier("add-button")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20)
                BubbleTabBar(selection: $store.selectedTab, haptics: store.data.settings.haptics)
                    .padding(.horizontal, 16)
            }
            .padding(.bottom, 4)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: store.selectedTab)
        }
        .background(Palette.background.ignoresSafeArea())
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
}

/// Bottom padding so scroll content clears the floating tab bar.
extension View {
    func tabBarSafeArea() -> some View {
        safeAreaInset(edge: .bottom) { Color.clear.frame(height: 96) }
    }
}
