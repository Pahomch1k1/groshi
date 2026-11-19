import SwiftUI
import GroshiCore

struct HomeView: View {
    @Environment(Store.self) private var store
    @State private var filter = TxFilter()
    @State private var search = ""
    @State private var showFilter = false
    @State private var selected: Txn?
    @State private var editing: Txn?
    @State private var showScheduled = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let data = store.data
        let cal = store.calendar
        var f = filter
        f.text = search
        let txs = Analytics.filter(data, period: store.period, filter: f)
        let totals = Analytics.totals(txs, data: data)
        let groups = Analytics.dayGroups(txs, data: data, calendar: cal)
        let base = data.settings.baseCurrency
        let upcoming = Recurrence.upcoming(data, in: store.period, after: Date(), calendar: cal)

        return NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.top, 8)
                    CashFlowSummary(totals: totals, base: base, caption: L("Денежный поток") + " · " + pagerTitle(cal))
                        .padding(.top, 22)
                    if store.period.canStep {
                        GroupedBarsChart(groups: barGroups(cal: cal, filter: f), currency: base) { g in
                            Haptics.select(enabled: data.settings.haptics)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                store.period = Period.containing(g.id, kind: store.period.kind, calendar: cal)
                            }
                        }
                        .frame(height: 168)
                        .padding(.top, 18)
                    }
                    PeriodPager()
                        .padding(.horizontal, -16)
                        .padding(.top, 10)

                    if !upcoming.isEmpty {
                        ScheduledCard(items: upcoming) { showScheduled = true }
                            .padding(.top, 14)
                    }

                    if groups.isEmpty {
                        EmptyStateView(filtered: f.isActive).padding(.top, 30)
                    }
                    ForEach(groups) { g in
                        DayGroupView(group: g, onTap: { selected = $0 }, onEdit: { editing = $0 })
                            .padding(.top, 18)
                    }
                }
                .padding(.horizontal, 16)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: txs.map(\.id))
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .background(Palette.background)
            .tabBarSafeArea()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showScheduled) { ScheduledView() }
            .sheet(isPresented: $showFilter) { FilterSheet(filter: $filter).presentationDetents([.medium, .large]) }
            .sheet(item: $selected) { tx in TransactionDetailView(txID: tx.id) }
            .sheet(item: $editing) { tx in AddTransactionView(editing: tx) }
        }
    }

    var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.textSecondary)
                TextField(L("Поиск"), text: $search)
                    .font(.system(size: 18))
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .accessibilityIdentifier("search-field")
                if !search.isEmpty {
                    Button { search = ""; searchFocused = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Palette.card, in: Capsule())
            .shadow(color: Palette.shadow, radius: 10, y: 3)

            Button { showFilter = true } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(filter.isActive ? Palette.accent : Color.primary)
                    .frame(width: 50, height: 50)
                    .background(Palette.card, in: Circle())
                    .shadow(color: Palette.shadow, radius: 10, y: 3)
                    .overlay(alignment: .topTrailing) {
                        if filter.isActive { Circle().fill(Palette.expense).frame(width: 9, height: 9).offset(x: -6, y: 6) }
                    }
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityIdentifier("filter-button")
        }
    }

    func pagerTitle(_ cal: Calendar) -> String {
        let p = store.period
        guard p.canStep else { return Fmt.periodTitle(p, calendar: cal) }
        let now = Period.containing(Date(), kind: p.kind, calendar: cal)
        if p.start == now.start {
            switch p.kind {
            case .week: return L("Эта неделя")
            case .month: return L("Этот месяц")
            case .year: return L("Этот год")
            default: break
            }
        }
        return Fmt.periodTitle(p, calendar: cal)
    }

    /// Six periods for the chart: ending at the current period, or at the selected one if it is older.
    func barGroups(cal: Calendar, filter f: TxFilter) -> [BarGroup] {
        let p = store.period
        let now = Period.containing(Date(), kind: p.kind, calendar: cal)
        var end = now
        var k = 0
        var probe = now
        while probe.start > p.start && k < 6 { probe = probe.shifted(by: -1, calendar: cal); k += 1 }
        if probe.start != p.start || k >= 6 { end = p }
        let df = DateFormatter(); df.locale = Lang.locale
        var out: [BarGroup] = []
        for i in stride(from: -5, through: 0, by: 1) {
            let pp = end.shifted(by: i, calendar: cal)
            let t = Analytics.totals(Analytics.filter(store.data, period: pp, filter: f), data: store.data)
            var top = "", bottom = ""
            switch p.kind {
            case .month:
                df.setLocalizedDateFormatFromTemplate("LLL"); top = df.string(from: pp.start).capitalizedFirst.replacingOccurrences(of: ".", with: "")
                df.setLocalizedDateFormatFromTemplate("yyyy"); bottom = df.string(from: pp.start)
            case .year:
                df.setLocalizedDateFormatFromTemplate("yyyy"); top = df.string(from: pp.start)
            default:
                df.setLocalizedDateFormatFromTemplate("d MMM"); top = df.string(from: pp.start)
            }
            out.append(BarGroup(id: pp.start, top: top, bottom: bottom, income: t.income, expense: t.expense, selected: pp.start == p.start))
        }
        return out
    }
}

/// "UAH 6 146 / Cash Flow · This month" with green and red totals.
struct CashFlowSummary: View {
    var totals: Totals
    var base: String
    var caption: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                amountBlock
                Spacer(minLength: 8)
                pills
            }
            VStack(alignment: .leading, spacing: 10) {
                amountBlock
                pills
            }
        }
    }

    var amountBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Fmt.code(totals.net, base))
                .font(.system(size: 34, weight: .bold).monospacedDigit())
                .contentTransition(.numericText(value: Double(totals.net)))
                .lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityIdentifier("cashflow-net")
            Text(caption).font(.system(size: 16)).foregroundStyle(Palette.textSecondary)
        }
    }

    var pills: some View {
        HStack(spacing: 12) {
            AmountPill(sign: "plus", minor: totals.income, base: base, color: Palette.income).accessibilityIdentifier("cashflow-income")
            AmountPill(sign: "minus", minor: totals.expense, base: base, color: Palette.expense).accessibilityIdentifier("cashflow-expense")
        }
        .padding(.top, 8)
    }
}

struct AmountPill: View {
    var sign: String
    var minor: Int64
    var base: String
    var color: Color
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: sign + ".circle.fill").font(.system(size: 17)).foregroundStyle(color)
            Text(Fmt.code(minor, base))
                .font(.system(size: 16).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText(value: Double(minor)))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ScheduledCard: View {
    @Environment(Store.self) private var store
    var items: [(rule: RecurringRule, date: Date)]
    var onTap: () -> Void
    var body: some View {
        let base = store.data.settings.baseCurrency
        let total = store.data.settings.converter.sum(items.map { (minor: $0.rule.template.signedMinor, currency: $0.rule.template.currency) }, into: base).total
        Button(action: onTap) {
            HStack(spacing: 16) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 26)).foregroundStyle(Palette.textSecondary)
                    .frame(width: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Запланировано")).font(.system(size: 19, weight: .medium)).foregroundStyle(Color.primary)
                    Text("\(items.count) " + L("операций")).font(.system(size: 15)).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Text(Fmt.code(total, base)).font(.system(size: 18).monospacedDigit()).foregroundStyle(Color.primary)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .spendCard()
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }
}

struct EmptyStateView: View {
    var filtered: Bool
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: filtered ? "line.3.horizontal.decrease.circle" : "tray")
                .font(.system(size: 40)).foregroundStyle(Palette.textTertiary)
            Text(filtered ? L("Ничего не найдено") : L("Пока нет операций за этот период"))
                .font(.headline)
            Text(L("Нажмите «+», чтобы добавить, или удерживайте «+», чтобы сказать голосом."))
                .font(.footnote).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

/// Filter by period type, kind, wallets, categories and labels.
struct FilterSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: TxFilter
    @State private var showCustom = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section(L("Период")) {
                    Picker(L("Период"), selection: Binding(get: { store.period.kind }, set: { k in
                        if k == .custom { showCustom = true } else {
                            withAnimation(.snappy) { store.period = Period.containing(Date(), kind: k, calendar: store.calendar) }
                        }
                    })) {
                        ForEach([PeriodKind.week, .month, .year, .all, .custom], id: \.self) { Text(Fmt.kindName($0)).tag($0) }
                    }
                }
                Section(L("Тип")) {
                    Picker(L("Тип"), selection: $filter.kind) {
                        Text(L("Все")).tag(TxKind?.none)
                        Text(L("Расходы")).tag(TxKind?.some(.expense))
                        Text(L("Доходы")).tag(TxKind?.some(.income))
                        Text(L("Переводы")).tag(TxKind?.some(.transfer))
                    }
                    .pickerStyle(.segmented)
                }
                if !store.data.labels.isEmpty {
                    Section(L("Метки")) {
                        ForEach(store.data.sortedLabels) { l in
                            toggleRow(title: "#" + l.name, icon: AnyView(Image(systemName: "tag").foregroundStyle(Palette.textSecondary)),
                                      on: filter.labels.contains(l.name)) {
                                if filter.labels.contains(l.name) { filter.labels.remove(l.name) } else { filter.labels.insert(l.name) }
                            }
                        }
                    }
                }
                if store.data.activeWallets.count > 1 {
                    Section(L("Кошельки")) {
                        ForEach(store.data.activeWallets) { w in
                            toggleRow(title: w.name, icon: AnyView(Image(systemName: w.symbol).foregroundStyle(Color(hex: w.colorHex))),
                                      on: filter.walletIDs.contains(w.id)) {
                                if filter.walletIDs.contains(w.id) { filter.walletIDs.remove(w.id) } else { filter.walletIDs.insert(w.id) }
                            }
                        }
                    }
                }
                Section(L("Категории")) {
                    ForEach(store.data.categories(of: filter.kind == .income ? .income : .expense) + (filter.kind == nil ? store.data.categories(of: .income) : [])) { c in
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
            .sheet(isPresented: $showCustom) { CustomPeriodSheet().presentationDetents([.medium]) }
        }
    }

    func toggleRow(title: String, icon: AnyView, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.select(); action() }) {
            HStack {
                icon
                Text(title).foregroundStyle(Color.primary)
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }
        }
    }
}
