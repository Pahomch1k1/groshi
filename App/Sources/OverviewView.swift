import SwiftUI
import GroshiCore

struct OverviewView: View {
    @Environment(Store.self) private var store
    @State private var path = NavigationPath()
    @State private var showFilter = false
    @State private var filter = TxFilter()

    enum Route: Hashable { case category(UUID), breakdown(TxKind) }

    var body: some View {
        let data = store.data
        let cal = store.calendar
        let txs = Analytics.filter(data, period: store.period, filter: filter)
        let totals = Analytics.totals(txs, data: data)
        let prevTotals: Totals? = store.period.canStep
            ? Analytics.totals(Analytics.filter(data, period: store.period.previous(calendar: cal), filter: filter), data: data) : nil
        let base = data.settings.baseCurrency

        return NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Spacer()
                        Button { showFilter = true } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(filter.isActive ? Palette.accent : Color.primary)
                                .frame(width: 40, height: 40)
                                .background(Palette.card, in: Circle())
                                .shadow(color: Palette.shadow, radius: 7, y: 2)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle(scale: 0.9))
                    }
                    .padding(.top, 4)
                    Text(L("Обзор"))
                        .font(.system(size: 28, weight: .bold))
                        .padding(.top, 2)
                    PeriodPager()
                        .padding(.horizontal, -16)
                        .padding(.top, 6)

                    BreakdownCard(kind: .expense, txs: txs, total: totals.expense, previous: prevTotals?.expense) { route in path.append(route) }
                        .padding(.top, 10)
                    BreakdownCard(kind: .income, txs: txs, total: totals.income, previous: prevTotals?.income) { route in path.append(route) }
                        .padding(.top, 12)
                    CashFlowCard(txs: txs, totals: totals, base: base)
                        .padding(.top, 12)
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .background(Palette.background)
            .tabBarSafeArea()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { r in
                switch r {
                case .category(let id): CategoryTransactionsView(categoryID: id)
                case .breakdown(let k): BreakdownListView(kind: k, filter: filter) { path.append(Route.category($0)) }
                }
            }
            .sheet(isPresented: $showFilter) { FilterSheet(filter: $filter).presentationDetents([.medium, .large]) }
        }
    }
}

/// "Expenses › / −UAH 82 002 / ⌄ 45 % vs. previous period" + donut with icons + legend.
struct BreakdownCard: View {
    @Environment(Store.self) private var store
    var kind: TxKind
    var txs: [Txn]
    var total: Int64
    var previous: Int64?
    var navigate: (OverviewView.Route) -> Void

    var body: some View {
        let data = store.data
        let base = data.settings.baseCurrency
        let shares = Analytics.breakdown(txs, kind: kind, data: data)
        let slices = shares.map { s -> DonutSlice in
            let c = data.category(s.categoryID)
            return DonutSlice(id: s.categoryID, value: s.amountMinor, colorHex: c?.colorHex ?? "#8395A7",
                              icon: c?.icon ?? .symbol("tag.fill"), percent: s.percentText, basisPoints: s.basisPoints)
        }
        VStack(alignment: .leading, spacing: 3) {
            Button { navigate(.breakdown(kind)) } label: {
                HStack(spacing: 4) {
                    Text(kind == .expense ? L("Расходы") : L("Доходы"))
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(Fmt.code(kind == .expense ? -total : total, base))
                .font(.system(size: 24, weight: .bold).monospacedDigit())
                .contentTransition(.numericText(value: Double(total)))
                .accessibilityIdentifier(kind == .expense ? "overview-total" : "overview-income-total")
            if let prev = previous, prev > 0 {
                let pct = Int((Double(total - prev) / Double(prev) * 100).rounded())
                let up = pct >= 0
                let good = kind == .expense ? !up : up
                HStack(spacing: 4) {
                    Image(systemName: up ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold))
                    Text("\(abs(pct)) %").font(.system(size: 13, weight: .semibold))
                    Text(L("к прошлому периоду")).font(.system(size: 13)).foregroundStyle(Palette.textTertiary)
                }
                .foregroundStyle(good ? Palette.income : Palette.expense)
            }
            if slices.isEmpty {
                Text(L("Нет данных за период")).font(.system(size: 14)).foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 34)
            } else {
                DonutWithIcons(slices: slices) { navigate(.category($0)) }
                    .frame(height: 250)
                    .padding(.top, 2)
                legend(shares.prefix(4).map { $0.categoryID })
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spendCard(radius: 22)
    }

    func legend(_ ids: [UUID]) -> some View {
        HStack(spacing: 10) {
            ForEach(ids, id: \.self) { id in
                let c = store.data.category(id)
                Button { navigate(.category(id)) } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: c?.colorHex ?? "#8395A7")).frame(width: 8, height: 8)
                        Text(c?.name ?? "").font(.system(size: 13)).foregroundStyle(Color.primary).lineLimit(1)
                    }
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct CashFlowCard: View {
    @Environment(Store.self) private var store
    var txs: [Txn]
    var totals: Totals
    var base: String

    var body: some View {
        let buckets = Analytics.buckets(txs, period: store.period, data: store.data, calendar: store.calendar)
        let groups = Self.groups(buckets, yearly: store.period.kind == .year)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(L("Денежный поток"))
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Palette.textSecondary)
            Text(Fmt.code(totals.net, base))
                .font(.system(size: 24, weight: .bold).monospacedDigit())
                .contentTransition(.numericText(value: Double(totals.net)))
            HStack(spacing: 10) {
                AmountPill(sign: "plus", minor: totals.income, base: base, color: Palette.income)
                AmountPill(sign: "minus", minor: totals.expense, base: base, color: Palette.expense)
            }
            if !groups.isEmpty {
                GroupedBarsChart(groups: groups, currency: base, showLabels: groups.count <= 12)
                    .frame(height: 120)
                    .padding(.top, 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spendCard(radius: 22)
    }

    static func groups(_ buckets: [Analytics.Bucket], yearly: Bool) -> [BarGroup] {
        let df = DateFormatter()
        df.locale = Lang.locale
        df.setLocalizedDateFormatFromTemplate(yearly ? "LLL" : "d")
        return buckets.map { BarGroup(id: $0.start, top: df.string(from: $0.start), bottom: "", income: $0.income, expense: $0.expense, selected: false) }
    }
}

/// All categories of one kind with amounts and shares.
struct BreakdownListView: View {
    @Environment(Store.self) private var store
    var kind: TxKind
    var filter: TxFilter
    var open: (UUID) -> Void

    var body: some View {
        let data = store.data
        let txs = Analytics.filter(data, period: store.period, filter: filter)
        let shares = Analytics.breakdown(txs, kind: kind, data: data)
        let base = data.settings.baseCurrency
        let maxV = shares.first?.amountMinor ?? 1
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(shares) { s in
                    let c = data.category(s.categoryID)
                    Button { open(s.categoryID) } label: {
                        HStack(spacing: 12) {
                            CategoryIconView(category: c, size: 34)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(c?.name ?? "—").font(.system(size: 15)).foregroundStyle(Color.primary)
                                    Text("\(s.count)").font(.system(size: 12)).foregroundStyle(Palette.textTertiary)
                                    Spacer()
                                    Text(Fmt.code(s.amountMinor, base)).font(.system(size: 15).monospacedDigit()).foregroundStyle(Color.primary)
                                }
                                HStack(spacing: 6) {
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Palette.bubble)
                                            Capsule().fill(Color(hex: c?.colorHex ?? "#8395A7"))
                                                .frame(width: max(4, geo.size.width * CGFloat(s.amountMinor) / CGFloat(max(maxV, 1))))
                                        }
                                    }
                                    .frame(height: 5)
                                    Text(s.percentText).font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.textSecondary)
                                        .frame(width: 44, alignment: .trailing)
                                }
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("share-row")
                }
            }
            .padding(.vertical, 4)
            .spendCard()
            .padding(16)
        }
        .background(Palette.background)
        .tabBarSafeArea()
        .navigationTitle(kind == .expense ? L("Расходы") : L("Доходы"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Transactions of one category in the selected period.
struct CategoryTransactionsView: View {
    @Environment(Store.self) private var store
    let categoryID: UUID
    @State private var selected: Txn?
    @State private var editing: Txn?

    var body: some View {
        let cal = store.calendar
        let txs = Analytics.filter(store.data, period: store.period, filter: TxFilter(categoryIDs: [categoryID]))
        let groups = Analytics.dayGroups(txs, data: store.data, calendar: cal)
        let total = Analytics.totals(txs, data: store.data)
        let cat = store.data.category(categoryID)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 6) {
                    CategoryIconView(category: cat, size: 54, style: .white)
                    Text(cat?.name ?? "").font(.system(size: 15, weight: .medium))
                    Text(Fmt.code(cat?.kind == .income ? total.income : -total.expense, store.data.settings.baseCurrency))
                        .font(.system(size: 24, weight: .bold).monospacedDigit())
                    Text(Fmt.periodTitle(store.period, calendar: cal) + " · \(txs.count)")
                        .font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(colors: [Palette.pastel(cat?.colorHex ?? "#8395A7", 0.35), Palette.background], startPoint: .top, endPoint: .bottom)
                        .padding(.horizontal, -16).padding(.top, -200)
                )
                ForEach(groups) { g in
                    DayGroupView(group: g, onTap: { selected = $0 }, onEdit: { editing = $0 })
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 16)
        }
        .background(Palette.background)
        .tabBarSafeArea()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { tx in TransactionDetailView(txID: tx.id) }
        .sheet(item: $editing) { tx in AddTransactionView(editing: tx) }
    }
}
