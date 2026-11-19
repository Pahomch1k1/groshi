import SwiftUI
import Charts
import GroshiCore

struct OverviewView: View {
    @Environment(Store.self) private var store
    @State private var kind: TxKind = .expense
    @State private var highlighted: UUID?
    @State private var animate = false
    @State private var angleSelection: Double?

    var body: some View {
        let data = store.data
        let cal = store.calendar
        let txs = Analytics.filter(data, period: store.period)
        let totals = Analytics.totals(txs, data: data)
        let shares = Analytics.breakdown(txs, kind: kind, data: data)
        let base = data.settings.baseCurrency
        let total = kind == .expense ? totals.expense : totals.income
        let prevTotals: Totals? = store.period.canStep
            ? Analytics.totals(Analytics.filter(data, period: store.period.previous(calendar: cal)), data: data) : nil

        return NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    PeriodSwitcher()
                    Picker("", selection: $kind.animation(.snappy)) {
                        Text(L("Расходы")).tag(TxKind.expense)
                        Text(L("Доходы")).tag(TxKind.income)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("overview-kind")

                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind == .expense ? L("Расходы") : L("Доходы")).font(.subheadline).foregroundStyle(.secondary)
                                    Text(Fmt.money(total, base))
                                        .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                                        .contentTransition(.numericText(value: Double(total)))
                                        .accessibilityIdentifier("overview-total")
                                }
                                Spacer()
                                if let prev = prevTotals {
                                    ChangeBadge(current: total, previous: kind == .expense ? prev.expense : prev.income, inverse: kind == .expense)
                                }
                            }
                            donut(shares, total: total, base: base)
                                .frame(height: 240)
                                .padding(.vertical, 6)
                        }
                    }

                    if shares.isEmpty {
                        Text(L("Нет данных за период")).foregroundStyle(.secondary).padding(.vertical, 30)
                    } else {
                        Card(padding: 8) {
                            VStack(spacing: 0) {
                                ForEach(shares) { s in
                                    NavigationLink(value: s.categoryID) {
                                        ShareRow(share: s, base: base, maxAmount: shares.first?.amountMinor ?? 1, highlighted: highlighted == s.categoryID)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("share-row")
                                    if s.id != shares.last?.id { Divider().padding(.leading, 60) }
                                }
                            }
                        }
                    }

                    if store.period.canStep {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L("Денежный поток")).font(.headline)
                                HStack(spacing: 8) {
                                    Pill(text: "+ " + Fmt.money(totals.income, base), color: Palette.income)
                                    Pill(text: "− " + Fmt.money(totals.expense, base), color: Palette.expense)
                                }
                                FlowChart(txs: txs).frame(height: 160)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .tabBarSafeArea()
            .background(Palette.background)
            .navigationTitle(L("Обзор"))
            .navigationDestination(for: UUID.self) { id in CategoryTransactionsView(categoryID: id) }
            .toolbar { ToolbarItem(placement: .topBarLeading) { AssistantToolbarButton() } }
            .onAppear { animate = false; withAnimation(.spring(response: 0.9, dampingFraction: 0.85)) { animate = true } }
            .onChange(of: kind) { _, _ in highlighted = nil; replay() }
            .onChange(of: store.period) { _, _ in replay() }
        }
    }

    func replay() {
        animate = false
        withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) { animate = true }
    }

    func donut(_ shares: [CategoryShare], total: Int64, base: String) -> some View {
        ZStack {
            if shares.isEmpty {
                Circle().stroke(Palette.bubble, lineWidth: 34).padding(30)
            } else {
                Chart(shares) { s in
                    let c = store.data.category(s.categoryID)
                    SectorMark(angle: .value("A", animate ? Double(s.amountMinor) : (s.id == shares.first?.id ? 1 : 0.0001)),
                               innerRadius: .ratio(highlighted == s.categoryID ? 0.56 : 0.62),
                               outerRadius: .ratio(highlighted == s.categoryID ? 1.0 : 0.94),
                               angularInset: 1.5)
                        .cornerRadius(5)
                        .foregroundStyle(Color(hex: c?.colorHex ?? "#8395A7"))
                        .opacity(highlighted == nil || highlighted == s.categoryID ? 1 : 0.35)
                }
                .chartLegend(.hidden)
                .chartAngleSelection(value: $angleSelection)
                .onChange(of: angleSelection) { _, v in
                    guard let v else { return }
                    var acc = 0.0
                    for s in shares {
                        acc += Double(s.amountMinor)
                        if v <= acc {
                            Haptics.select(enabled: store.data.settings.haptics)
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { highlighted = highlighted == s.categoryID ? nil : s.categoryID }
                            break
                        }
                    }
                }
                VStack(spacing: 2) {
                    if let h = highlighted, let s = shares.first(where: { $0.categoryID == h }) {
                        CategoryIconView(category: store.data.category(h), size: 34)
                        Text(store.data.category(h)?.name ?? "").font(.caption).lineLimit(1)
                        Text(s.percentText).font(.title3.weight(.bold))
                    } else {
                        Text("\(shares.count)").font(.title2.weight(.bold))
                        Text(L("категорий")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 120)
                .transition(.opacity)
            }
        }
    }
}

struct ChangeBadge: View {
    var current: Int64
    var previous: Int64
    var inverse: Bool
    var body: some View {
        if previous > 0 {
            let pct = Double(current - previous) / Double(previous) * 100
            let up = pct >= 0
            let good = inverse ? !up : up
            VStack(alignment: .trailing, spacing: 2) {
                Label(String(format: "%@%.0f%%", up ? "+" : "−", abs(pct)), systemImage: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(good ? Palette.income : Palette.expense)
                Text(L("к прошлому периоду")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct ShareRow: View {
    @Environment(Store.self) private var store
    var share: CategoryShare
    var base: String
    var maxAmount: Int64
    var highlighted: Bool

    var body: some View {
        let c = store.data.category(share.categoryID)
        HStack(spacing: 12) {
            CategoryIconView(category: c, size: 40)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(c?.name ?? "—").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("· \(share.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Fmt.money(share.amountMinor, base)).font(.subheadline.weight(.semibold).monospacedDigit())
                }
                HStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.bubble)
                            Capsule().fill(Color(hex: c?.colorHex ?? "#8395A7"))
                                .frame(width: max(4, geo.size.width * CGFloat(share.amountMinor) / CGFloat(max(maxAmount, 1))))
                        }
                    }
                    .frame(height: 6)
                    Text(share.percentText).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
        .background(highlighted ? Palette.bubble : .clear, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }
}

struct FlowChart: View {
    @Environment(Store.self) private var store
    var txs: [Txn]
    var body: some View {
        let buckets = Analytics.buckets(txs, period: store.period, data: store.data, calendar: store.calendar)
        Chart {
            ForEach(buckets) { b in
                BarMark(x: .value("D", b.start, unit: store.period.kind == .year ? .month : .day), y: .value("V", Double(b.income) / 100))
                    .foregroundStyle(Palette.income)
                BarMark(x: .value("D", b.start, unit: store.period.kind == .year ? .month : .day), y: .value("V", -Double(b.expense) / 100))
                    .foregroundStyle(Palette.expense)
            }
        }
        .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine(); AxisValueLabel() } }
        .animation(.snappy, value: buckets)
    }
}

/// Transactions of one category in the selected period.
struct CategoryTransactionsView: View {
    @Environment(Store.self) private var store
    let categoryID: UUID
    @State private var selected: Txn?

    var body: some View {
        let cal = store.calendar
        let txs = Analytics.filter(store.data, period: store.period, filter: TxFilter(categoryIDs: [categoryID]))
        let groups = Analytics.dayGroups(txs, data: store.data, calendar: cal)
        let total = Analytics.totals(txs, data: store.data)
        let cat = store.data.category(categoryID)
        return List {
            Section {
                HStack(spacing: 14) {
                    CategoryIconView(category: cat, size: 52)
                    VStack(alignment: .leading) {
                        Text(Fmt.money(cat?.kind == .income ? total.income : total.expense, store.data.settings.baseCurrency))
                            .font(.title2.weight(.bold).monospacedDigit())
                        Text(Fmt.periodTitle(store.period, calendar: cal) + " · \(txs.count)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
            ForEach(groups) { g in
                Section(Fmt.dayTitle(g.day, calendar: cal)) {
                    ForEach(g.items) { tx in
                        TransactionRow(tx: tx)
                            .onTapGesture { selected = tx }
                            .swipeActions {
                                Button(role: .destructive) { store.perform(.deleteTransactions([tx.id]), label: L("Операция удалена")) } label: { Label(L("Удалить"), systemImage: "trash") }
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .tabBarSafeArea()
        .navigationTitle(cat?.name ?? "")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { AssistantToolbarButton(context: cat.map { "The user is viewing the category '\($0.name)' for the selected period." }) } }
        .sheet(item: $selected) { tx in TransactionDetailView(txID: tx.id) }
    }
}
