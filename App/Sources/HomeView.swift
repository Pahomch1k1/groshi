import SwiftUI
import Charts
import GroshiCore

struct HomeView: View {
    @Environment(Store.self) private var store
    @State private var filter = TxFilter()
    @State private var search = ""
    @State private var showFilter = false
    @State private var selected: Txn?
    @State private var editing: Txn?

    var body: some View {
        let data = store.data
        let cal = store.calendar
        var f = filter
        f.text = search
        let txs = Analytics.filter(data, period: store.period, filter: f)
        let totals = Analytics.totals(txs, data: data)
        let groups = Analytics.dayGroups(txs, data: data, calendar: cal)
        let base = data.settings.baseCurrency

        return NavigationStack {
            List {
                Section {
                    CashFlowHeader(totals: totals, base: base, filter: f)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    PeriodSwitcher()
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    if !totals.missingRates.isEmpty {
                        Label(L("Нет курса для: ") + totals.missingRates.sorted().joined(separator: ", "), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if groups.isEmpty {
                    EmptyStateView(filtered: f.isActive)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                ForEach(groups) { g in
                    Section {
                        ForEach(g.items) { tx in
                            TransactionRow(tx: tx)
                                .onTapGesture { Haptics.tap(enabled: data.settings.haptics); selected = tx }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        store.perform(.deleteTransactions([tx.id]), label: L("Операция удалена"))
                                    } label: { Label(L("Удалить"), systemImage: "trash") }
                                }
                                .swipeActions(edge: .leading) {
                                    Button { editing = tx } label: { Label(L("Изменить"), systemImage: "pencil") }.tint(.blue)
                                }
                                .contextMenu {
                                    Button { editing = tx } label: { Label(L("Изменить"), systemImage: "pencil") }
                                    Button { duplicate(tx) } label: { Label(L("Повторить сегодня"), systemImage: "plus.square.on.square") }
                                    Button(role: .destructive) {
                                        store.perform(.deleteTransactions([tx.id]), label: L("Операция удалена"))
                                    } label: { Label(L("Удалить"), systemImage: "trash") }
                                }
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                                .accessibilityIdentifier("tx-row")
                        }
                    } header: {
                        HStack {
                            Text(Fmt.dayTitle(g.day, calendar: cal))
                            Spacer()
                            Text(Fmt.money(g.net, base, sign: true)).monospacedDigit()
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .animation(.snappy, value: txs.map(\.id))
            .tabBarSafeArea()
            .navigationTitle(L("Главная"))
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: L("Поиск"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AssistantToolbarButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilter = true } label: {
                        Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityIdentifier("filter-button")
                }
            }
            .sheet(isPresented: $showFilter) { FilterSheet(filter: $filter).presentationDetents([.medium, .large]) }
            .sheet(item: $selected) { tx in TransactionDetailView(txID: tx.id) }
            .sheet(item: $editing) { tx in AddTransactionView(editing: tx) }
        }
    }

    func duplicate(_ tx: Txn) {
        var copy = tx
        copy.id = UUID(); copy.date = Date(); copy.createdAt = Date(); copy.source = .manual
        store.perform(.addTransactions([copy]), label: L("Операция добавлена"))
    }
}

/// Big net figure with income / expense pills and a bar chart of recent periods.
struct CashFlowHeader: View {
    @Environment(Store.self) private var store
    var totals: Totals
    var base: String
    var filter: TxFilter

    var body: some View {
        let cal = store.calendar
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.money(totals.net, base, sign: true))
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(value: Double(totals.net)))
                        .accessibilityIdentifier("cashflow-net")
                    Text(L("Денежный поток") + " · " + Fmt.periodTitle(store.period, calendar: cal))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Pill(text: "+ " + Fmt.money(totals.income, base), color: Palette.income)
                    .accessibilityIdentifier("cashflow-income")
                Pill(text: "− " + Fmt.money(totals.expense, base), color: Palette.expense)
                    .accessibilityIdentifier("cashflow-expense")
            }
            if store.period.canStep {
                RecentPeriodsChart(filter: filter)
                    .frame(height: 120)
            }
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.snappy, value: totals)
    }
}

struct Pill: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .contentTransition(.numericText())
    }
}

/// Income/expense bars for the selected period and the 5 before it; tapping a bar selects that period.
struct RecentPeriodsChart: View {
    @Environment(Store.self) private var store
    var filter: TxFilter
    @State private var appeared = false

    struct Point: Identifiable { let id = UUID(); let label: String; let kind: String; let value: Double; let isCurrent: Bool; let offset: Int }

    var body: some View {
        let cal = store.calendar
        let p = store.period
        var points: [Point] = []
        for i in stride(from: -5, through: 0, by: 1) {
            let pp = p.shifted(by: i, calendar: cal)
            let t = Analytics.totals(Analytics.filter(store.data, period: pp, filter: filter), data: store.data)
            let label = Fmt.shortPeriodLabel(pp, calendar: cal)
            points.append(Point(label: label, kind: L("Доходы"), value: Double(t.income) / 100, isCurrent: i == 0, offset: i))
            points.append(Point(label: label, kind: L("Расходы"), value: Double(t.expense) / 100, isCurrent: i == 0, offset: i))
        }
        return Chart(points) { pt in
            BarMark(x: .value("P", pt.label), y: .value("V", appeared ? pt.value : 0), width: .ratio(0.7))
                .foregroundStyle(pt.kind == L("Доходы") ? Palette.income : Palette.expense)
                .opacity(pt.isCurrent ? 1 : 0.45)
                .position(by: .value("K", pt.kind))
                .cornerRadius(4)
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { v in
                AxisValueLabel().font(.caption2)
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { loc in
                        let origin = geo[proxy.plotFrame!].origin
                        if let label: String = proxy.value(atX: loc.x - origin.x),
                           let hit = points.first(where: { $0.label == label }), hit.offset != 0 {
                            Haptics.select(enabled: store.data.settings.haptics)
                            withAnimation(.snappy) { store.period = store.period.shifted(by: hit.offset, calendar: cal) }
                        }
                    }
            }
        }
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.05)) { appeared = true } }
    }
}

struct EmptyStateView: View {
    var filtered: Bool
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: filtered ? "line.3.horizontal.decrease.circle" : "tray")
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(filtered ? L("Ничего не найдено") : L("Пока нет операций за этот период"))
                .font(.headline)
            Text(L("Нажмите «+», чтобы добавить, или удерживайте «+», чтобы сказать голосом."))
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// Filter by type, categories and wallets.
struct FilterSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: TxFilter

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Тип")) {
                    Picker(L("Тип"), selection: $filter.kind) {
                        Text(L("Все")).tag(TxKind?.none)
                        Text(L("Расходы")).tag(TxKind?.some(.expense))
                        Text(L("Доходы")).tag(TxKind?.some(.income))
                        Text(L("Переводы")).tag(TxKind?.some(.transfer))
                    }
                    .pickerStyle(.segmented)
                }
                Section(L("Кошельки")) {
                    ForEach(store.data.activeWallets) { w in
                        toggleRow(title: w.name, icon: AnyView(Image(systemName: w.symbol).foregroundStyle(Color(hex: w.colorHex))),
                                  on: filter.walletIDs.contains(w.id)) {
                            if filter.walletIDs.contains(w.id) { filter.walletIDs.remove(w.id) } else { filter.walletIDs.insert(w.id) }
                        }
                    }
                }
                Section(L("Категории")) {
                    ForEach(store.data.categories(of: filter.kind ?? .expense) + (filter.kind == nil ? store.data.categories(of: .income) : [])) { c in
                        toggleRow(title: c.name, icon: AnyView(CategoryIconView(category: c, size: 28)), on: filter.categoryIDs.contains(c.id)) {
                            if filter.categoryIDs.contains(c.id) { filter.categoryIDs.remove(c.id) } else { filter.categoryIDs.insert(c.id) }
                        }
                    }
                }
            }
            .navigationTitle(L("Фильтр"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Сбросить")) { filter = TxFilter() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() } }
            }
        }
    }

    func toggleRow(title: String, icon: AnyView, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.select(); action() }) {
            HStack {
                icon
                Text(title).foregroundStyle(.primary)
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }
        }
    }
}
