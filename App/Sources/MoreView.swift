import SwiftUI
import UniformTypeIdentifiers
import GroshiCore

/// Spendee "More": large title and white rounded groups with counts on the right.
struct MoreView: View {
    @Environment(Store.self) private var store

    var body: some View {
        let data = store.data
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Ещё")).font(.system(size: 28, weight: .bold)).padding(.top, 50)

                    group {
                        link(L("Категории"), "square.on.circle", value: "\(data.categories.filter { !$0.isArchived }.count)", id: "more-categories") { CategoriesView() }
                        link(L("Метки"), "tag", value: "\(data.labels.count)", id: "more-labels") { LabelsView() }
                        link(L("Основная валюта"), "dollarsign.circle", value: data.settings.baseCurrency, id: "more-currency") { CurrencySettingsView() }
                    }
                    group {
                        link(L("Кошельки"), "wallet.pass", value: "\(data.activeWallets.count)", id: "more-wallets") { WalletsView() }
                        link(L("Запланированные операции"), "clock.arrow.circlepath", value: data.recurring.isEmpty ? nil : "\(data.recurring.filter { $0.isActive }.count)", id: "more-scheduled") { ScheduledView() }
                    }
                    group {
                        link(L("Язык"), "globe", value: Lang.name(data.settings.language), id: "more-language") { LanguageView() }
                        link(L("Оформление"), "circle.lefthalf.filled", value: themeName(data.settings.theme), id: "more-appearance") { AppearanceView() }
                    }
                    group {
                        link(L("Экспорт и импорт"), "arrow.up.arrow.down.circle", value: nil, id: "more-data") { DataTransferView() }
                        link(L("Резервная копия"), "externaldrive", value: nil, id: "more-backup") { BackupView() }
                        link(L("AI-ассистент"), "sparkles", value: nil, id: "more-ai") { AISettingsView() }
                    }
                    Text("WorkFlow Spend " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + " · " + "\(data.transactions.count) " + L("операций"))
                        .font(.system(size: 12)).foregroundStyle(Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .background(Palette.background)
            .tabBarSafeArea()
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    func themeName(_ t: AppTheme) -> String {
        switch t {
        case .system: return L("Системная")
        case .light: return L("Светлая")
        case .dark: return L("Тёмная")
        }
    }

    func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.vertical, 4)
            .spendCard()
    }

    func link<D: View>(_ title: String, _ icon: String, value: String?, id: String, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink { destination() } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 22).foregroundStyle(Color.primary)
                Text(title).font(.system(size: 15)).foregroundStyle(Color.primary)
                Spacer()
                if let value { Text(value).font(.system(size: 14)).foregroundStyle(Palette.textSecondary) }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textSecondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct LanguageView: View {
    @Environment(Store.self) private var store
    var body: some View {
        List {
            ForEach(AppLanguage.allCases, id: \.self) { l in
                Button {
                    store.updateSettings { $0.language = l }
                } label: {
                    HStack {
                        Text(Lang.name(l)).foregroundStyle(Color.primary)
                        Spacer()
                        if store.data.settings.language == l { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
                    }
                }
            }
        }
        .navigationTitle(L("Язык"))
    }
}

struct AppearanceView: View {
    @Environment(Store.self) private var store
    var body: some View {
        let s = store.data.settings
        Form {
            Picker(L("Тема"), selection: Binding(get: { s.theme }, set: { v in store.updateSettings { $0.theme = v } })) {
                Text(L("Системная")).tag(AppTheme.system)
                Text(L("Светлая")).tag(AppTheme.light)
                Text(L("Тёмная")).tag(AppTheme.dark)
            }
            .pickerStyle(.inline)
            Section {
                Toggle(L("Тактильный отклик"), isOn: Binding(get: { s.haptics }, set: { v in store.updateSettings { $0.haptics = v } }))
                Picker(L("Начало недели"), selection: Binding(get: { s.firstWeekday }, set: { v in store.updateSettings { $0.firstWeekday = v } })) {
                    Text(L("Понедельник")).tag(2)
                    Text(L("Воскресенье")).tag(1)
                }
            }
        }
        .navigationTitle(L("Оформление"))
    }
}

// MARK: Categories

struct CategoriesView: View {
    @Environment(Store.self) private var store
    @State private var kind: TxKind = .expense
    @State private var editing: FinCategory?
    @State private var creating = false
    @State private var reordering = false

    var body: some View {
        let cats = store.data.categories(of: kind)
        let archived = store.data.categories.filter { $0.kind == kind && $0.isArchived }
        Group {
            if reordering {
                List {
                    ForEach(cats) { c in
                        HStack(spacing: 12) { CategoryIconView(category: c, size: 28); Text(c.name) }
                    }
                    .onMove { from, to in
                        var arr = cats
                        arr.move(fromOffsets: from, toOffset: to)
                        let muts = arr.enumerated().map { (i, c) -> Mutation in var cc = c; cc.sortOrder = i + 1; return .upsertCategory(cc) }
                        store.perform(.batch(muts), label: L("Порядок категорий"), toast: false)
                    }
                }
                .environment(\.editMode, .constant(.active))
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        KindSegment(kind: $kind, haptics: store.data.settings.haptics)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 12) {
                            ForEach(cats) { c in
                                Button { editing = c } label: {
                                    VStack(spacing: 5) {
                                        CategoryIconView(category: c, size: 50, style: .white)
                                        Text(c.name).font(.system(size: 12)).foregroundStyle(Palette.textSecondary).lineLimit(1).minimumScaleFactor(0.92)
                                    }
                                }
                                .buttonStyle(PressableStyle(scale: 0.9))
                            }
                            Button { creating = true } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: "plus").font(.system(size: 20)).foregroundStyle(Palette.accent)
                                        .frame(width: 50, height: 50).background(Palette.accent.opacity(0.16), in: Circle())
                                    Text(L("Создать категорию")).font(.system(size: 12)).foregroundStyle(Palette.textSecondary).lineLimit(1).minimumScaleFactor(0.92)
                                }
                            }
                            .buttonStyle(PressableStyle(scale: 0.9))
                            .accessibilityIdentifier("add-category")
                        }
                        if !archived.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(L("В архиве")).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.textSecondary).padding(12)
                                ForEach(archived) { c in
                                    HStack {
                                        CategoryIconView(category: c, size: 26)
                                        Text(c.name).foregroundStyle(Palette.textSecondary)
                                        Spacer()
                                        Button(L("Вернуть")) { var cc = c; cc.isArchived = false; store.perform(.upsertCategory(cc), label: L("Категория восстановлена")) }
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                }
                            }
                            .padding(.bottom, 6)
                            .spendCard(radius: 18)
                        }
                    }
                    .padding(16)
                }
                .background(Palette.background)
            }
        }
        .tabBarSafeArea()
        .navigationTitle(L("Категории"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(reordering ? L("Готово") : L("Порядок")) { withAnimation { reordering.toggle() } }
            }
        }
        .sheet(item: $editing) { c in CategoryEditor(category: c, kind: c.kind) { _ in } }
        .sheet(isPresented: $creating) { CategoryEditor(category: nil, kind: kind) { _ in } }
    }
}

// MARK: Labels

struct LabelsView: View {
    @Environment(Store.self) private var store
    @State private var newName = ""
    @State private var renaming: TxLabel?
    @State private var renameText = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField(L("Новая метка"), text: $newName).onSubmit(add)
                    Button(L("Добавить"), action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                ForEach(store.data.sortedLabels) { l in
                    let count = store.data.transactions.filter { $0.tags.contains(l.name) }.count
                    Button { renaming = l; renameText = l.name } label: {
                        HStack {
                            Image(systemName: "tag").foregroundStyle(Palette.textSecondary)
                            Text(l.name).foregroundStyle(Color.primary)
                            Spacer()
                            Text("\(count)").foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.perform(.deleteLabel(id: l.id), label: L("Метка удалена: ") + l.name) } label: { Label(L("Удалить"), systemImage: "trash") }
                    }
                }
                .onMove { from, to in
                    var arr = store.data.sortedLabels
                    arr.move(fromOffsets: from, toOffset: to)
                    store.perform(.batch(arr.enumerated().map { (i, l) -> Mutation in var ll = l; ll.sortOrder = i + 1; return .upsertLabel(ll) }),
                                  label: L("Порядок меток"), toast: false)
                }
            } footer: { Text(L("Метки показываются под описанием при добавлении операции. Переименование меняет метку во всех операциях.")) }
        }
        .tabBarSafeArea()
        .navigationTitle(L("Метки"))
        .toolbar { EditButton() }
        .alert(L("Переименовать метку"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Название"), text: $renameText)
            Button(L("Отмена"), role: .cancel) { renaming = nil }
            Button(L("Сохранить")) {
                if var l = renaming { l.name = renameText; store.perform(.upsertLabel(l), label: L("Метка переименована")) }
                renaming = nil
            }
        }
    }

    func add() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if store.perform(.upsertLabel(TxLabel(name: n)), label: L("Метка создана: ") + n) { newName = "" }
    }
}

// MARK: Scheduled

struct ScheduledView: View {
    @Environment(Store.self) private var store
    @State private var showAdd = false

    var body: some View {
        let rules = store.data.recurring.sorted { $0.nextDate < $1.nextDate }
        List {
            if rules.isEmpty {
                Text(L("Нет запланированных операций. Выберите «Повтор» при добавлении операции.")).foregroundStyle(Palette.textSecondary)
            }
            ForEach(rules) { r in
                let t = r.template
                HStack(spacing: 12) {
                    TxIcon(tx: t, size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.isTransfer ? L("Перевод") : (store.data.category(t.categoryID)?.name ?? "—"))
                        Text(AddTransactionView.frequencyName(r.frequency) + " · " + L("след.") + " " + Fmt.fullDate(r.nextDate))
                            .font(.footnote).foregroundStyle(Palette.textSecondary)
                        if !t.note.isEmpty { Text(t.note).font(.footnote).foregroundStyle(Palette.textSecondary) }
                    }
                    Spacer()
                    Text(Fmt.txCode(t)).monospacedDigit().foregroundStyle(r.isActive ? Color.primary : Palette.textTertiary)
                }
                .swipeActions {
                    Button(role: .destructive) { store.perform(.deleteRecurring(id: r.id), label: L("Повтор отключён")) } label: { Label(L("Удалить"), systemImage: "trash") }
                }
            }
        }
        .tabBarSafeArea()
        .navigationTitle(L("Запланированные"))
        .toolbar { Button { showAdd = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $showAdd) { AddTransactionView(editing: nil) }
    }
}

struct DeleteCategorySheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let category: FinCategory
    @State private var target: UUID?

    var body: some View {
        let count = store.data.transactions.filter { $0.categoryID == category.id }.count
        NavigationStack {
            Form {
                if count == 0 {
                    Text(L("Категория не используется и будет удалена."))
                } else {
                    Section {
                        Picker(L("Перенести операции в"), selection: $target) {
                            Text(L("Не переносить (в архив)")).tag(UUID?.none)
                            ForEach(store.data.categories(of: category.kind).filter { $0.id != category.id }) { c in Text(c.name).tag(UUID?.some(c.id)) }
                        }
                    } footer: {
                        Text(L("Операций в категории: ") + "\(count). " + L("Без переноса категория уйдёт в архив, история сохранится."))
                    }
                }
            }
            .navigationTitle(L("Удалить «") + category.name + "»")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button(L("Удалить"), role: .destructive) {
                        if store.perform(.deleteCategory(id: category.id, moveTo: target), label: L("Категория удалена: ") + category.name) { dismiss() }
                    }
                }
            }
        }
    }
}

// MARK: Wallets

struct WalletsView: View {
    @Environment(Store.self) private var store
    @State private var editing: Wallet?
    @State private var creating = false

    var body: some View {
        List {
            Section {
                ForEach(store.data.activeWallets) { w in
                    Button { editing = w } label: {
                        HStack(spacing: 12) {
                            Image(systemName: w.symbol).foregroundStyle(.white).frame(width: 30, height: 30)
                                .background(Color(hex: w.colorHex), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading) {
                                Text(w.name).foregroundStyle(.primary)
                                if store.data.defaultWallet?.id == w.id { Text(L("По умолчанию")).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(Fmt.money(store.data.balance(of: w), w.currency)).monospacedDigit().foregroundStyle(.primary)
                        }
                    }
                    .accessibilityIdentifier("wallet-row")
                }
                .onMove { from, to in
                    var arr = store.data.activeWallets
                    arr.move(fromOffsets: from, toOffset: to)
                    var data = store.data
                    for (i, w) in arr.enumerated() { if let idx = data.wallets.firstIndex(where: { $0.id == w.id }) { data.wallets[idx].sortOrder = i } }
                    store.perform(.replaceAll(data), label: L("Порядок кошельков"), toast: false)
                }
            } footer: {
                let all = store.data.activeWallets.map { (minor: store.data.balance(of: $0), currency: $0.currency) }
                let total = store.data.settings.converter.sum(all, into: store.data.settings.baseCurrency)
                Text(L("Всего: ") + Fmt.money(total.total, store.data.settings.baseCurrency))
            }
            let archived = store.data.wallets.filter { $0.isArchived }
            if !archived.isEmpty {
                Section(L("В архиве")) {
                    ForEach(archived) { w in
                        HStack {
                            Text(w.name).foregroundStyle(.secondary)
                            Spacer()
                            Button(L("Вернуть")) { var ww = w; ww.isArchived = false; store.perform(.upsertWallet(ww), label: L("Кошелёк восстановлен")) }
                        }
                    }
                }
            }
        }
        .navigationTitle(L("Кошельки"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") }.accessibilityIdentifier("add-wallet") }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .sheet(item: $editing) { w in WalletEditor(wallet: w) }
        .sheet(isPresented: $creating) { WalletEditor(wallet: nil) }
    }
}

struct WalletEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let wallet: Wallet?
    @State private var name = ""
    @State private var currency = "UAH"
    @State private var initial = ""
    @State private var color = "#2E86DE"
    @State private var symbol = "wallet.pass.fill"
    @State private var isDefault = false
    @State private var moveTo: UUID?
    @State private var confirmDelete = false

    static let symbols = ["wallet.pass.fill", "creditcard.fill", "banknote.fill", "building.columns.fill", "dollarsign.circle.fill",
                          "eurosign.circle.fill", "bitcoinsign.circle.fill", "briefcase.fill", "house.fill", "car.fill",
                          "airplane", "gift.fill", "lock.fill", "star.fill", "heart.fill", "bag.fill"]

    var body: some View {
        let hasTx = wallet.map { w in store.data.transactions.contains { $0.walletID == w.id } } ?? false
        NavigationStack {
            Form {
                Section {
                    TextField(L("Название"), text: $name).accessibilityIdentifier("wallet-name")
                    Picker(L("Валюта"), selection: $currency) {
                        ForEach(Currencies.common, id: \.self) { Text("\($0) \(Currencies.symbol($0))").tag($0) }
                    }
                    .disabled(hasTx)
                    TextField(L("Начальный баланс"), text: $initial).keyboardType(.decimalPad)
                    Toggle(L("По умолчанию"), isOn: $isDefault)
                } footer: {
                    if hasTx { Text(L("Валюту нельзя менять, пока в кошельке есть операции.")) }
                }
                Section(L("Значок")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(Self.symbols, id: \.self) { s in
                            Image(systemName: s).font(.title3).frame(width: 40, height: 40)
                                .foregroundStyle(symbol == s ? .white : .primary)
                                .background(symbol == s ? Color(hex: color) : Palette.bubble, in: RoundedRectangle(cornerRadius: 10))
                                .onTapGesture { Haptics.select(); symbol = s }
                        }
                    }
                    ColorRow(hex: $color)
                }
                if let w = wallet {
                    Section {
                        if hasTx {
                            Picker(L("Перенести операции в"), selection: $moveTo) {
                                Text(L("Не переносить (в архив)")).tag(UUID?.none)
                                ForEach(store.data.activeWallets.filter { $0.id != w.id }) { Text($0.name).tag(UUID?.some($0.id)) }
                            }
                        }
                        Button(L("Удалить кошелёк"), role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(wallet == nil ? L("Новый кошелёк") : L("Кошелёк"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("Сохранить"), action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("wallet-save") }
            }
            .confirmationDialog(L("Удалить кошелёк?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(L("Удалить"), role: .destructive) {
                    if let w = wallet, store.perform(.deleteWallet(id: w.id, moveTo: moveTo), label: L("Кошелёк удалён: ") + w.name) { dismiss() }
                }
            }
            .onAppear {
                if let w = wallet {
                    name = w.name; currency = w.currency; color = w.colorHex; symbol = w.symbol
                    initial = w.initialBalanceMinor == 0 ? "" : MoneyMath.plainString(w.initialBalanceMinor, currency: w.currency)
                    isDefault = store.data.defaultWallet?.id == w.id
                } else {
                    currency = store.data.settings.baseCurrency
                }
            }
        }
    }

    func save() {
        let initialMinor = initial.isEmpty ? 0 : (MoneyMath.parseMinor(initial, currency: currency) ?? 0)
        var w = wallet ?? Wallet(name: name, currency: currency)
        w.name = name; w.currency = currency; w.colorHex = color; w.symbol = symbol; w.initialBalanceMinor = initialMinor
        var s = store.data.settings
        if isDefault { s.defaultWalletID = w.id }
        let m = Mutation.batch([.upsertWallet(w), .updateSettings(s)])
        if store.perform(m, label: (wallet == nil ? L("Кошелёк создан: ") : L("Кошелёк изменён: ")) + w.name) { dismiss() }
    }
}

struct ColorRow: View {
    @Binding var hex: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Defaults.palette, id: \.self) { c in
                    Circle().fill(Color(hex: c)).frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(.white, lineWidth: hex == c ? 3 : 0))
                        .overlay(Circle().strokeBorder(Color(hex: c), lineWidth: hex == c ? 1 : 0).padding(-2))
                        .onTapGesture { Haptics.select(); withAnimation(.snappy) { hex = c } }
                }
                ColorPicker("", selection: Binding(get: { Color(hex: hex) }, set: { hex = $0.hexString }), supportsOpacity: false)
                    .labelsHidden()
            }
            .padding(.vertical, 4).padding(.horizontal, 2)
        }
    }
}

// MARK: Currencies

struct CurrencySettingsView: View {
    @Environment(Store.self) private var store
    @State private var newCode = "USD"
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        let s = store.data.settings
        Form {
            Section {
                Picker(L("Основная валюта"), selection: Binding(get: { s.baseCurrency }, set: { v in
                    store.updateSettings { $0 = Self.rebase($0, to: v) }
                })) {
                    ForEach(Currencies.common, id: \.self) { Text("\($0) \(Currencies.symbol($0))").tag($0) }
                }
            } footer: { Text(L("Итоги и аналитика пересчитываются в основную валюту по курсам ниже.")) }

            Section {
                ForEach(s.rates.keys.sorted(), id: \.self) { code in
                    HStack {
                        Text("1 \(code) =")
                        TextField("0", text: Binding(get: { store.data.settings.rates[code] ?? "" }, set: { v in
                            let clean = v.replacingOccurrences(of: ",", with: ".")
                            store.updateSettings { $0.rates[code] = clean }
                        }))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        Text(s.baseCurrency).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button(role: .destructive) { store.updateSettings { $0.rates[code] = nil } } label: { Label(L("Удалить"), systemImage: "trash") } }
                }
                HStack {
                    Picker(L("Добавить"), selection: $newCode) {
                        ForEach(Currencies.common.filter { $0 != s.baseCurrency && s.rates[$0] == nil }, id: \.self) { Text($0).tag($0) }
                    }
                    Button(L("Добавить")) { store.updateSettings { $0.rates[newCode] = "1" } }
                }
            } header: { Text(L("Курсы")) } footer: {
                if let d = s.ratesUpdatedAt { Text(L("Обновлено: ") + Fmt.fullDate(d)) }
            }

            Section {
                Button {
                    Task { await fetchNBU() }
                } label: {
                    HStack { Text(L("Загрузить курсы НБУ")); Spacer(); if loading { ProgressView() } }
                }
                .disabled(loading)
                if let m = message { Text(m).font(.footnote).foregroundStyle(.secondary) }
            } footer: { Text(L("Официальные курсы Национального банка Украины (bank.gov.ua). Отправляется только запрос курсов, без ваших данных.")) }
        }
        .navigationTitle(L("Валюты"))
    }

    /// Re-expresses all rates relative to a new base currency.
    static func rebase(_ s: AppSettings, to newBase: String) -> AppSettings {
        var out = s
        guard newBase != s.baseCurrency else { return s }
        let conv = s.converter
        guard let newBaseRate = conv.rate(newBase) else { out.baseCurrency = newBase; return out }
        var rates: [String: String] = [:]
        for code in Set(s.rates.keys).union([s.baseCurrency]) where code != newBase {
            if let r = conv.rate(code) {
                let v = r / newBaseRate
                rates[code] = NSDecimalNumber(decimal: v).rounding(accordingToBehavior: NSDecimalNumberHandler(roundingMode: .plain, scale: 6, raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false)).stringValue
            }
        }
        out.rates = rates
        out.baseCurrency = newBase
        return out
    }

    func fetchNBU() async {
        loading = true; defer { loading = false }
        struct Row: Decodable { let cc: String; let rate: Double }
        do {
            let (d, _) = try await URLSession.shared.data(from: URL(string: "https://bank.gov.ua/NBUStatService/v1/statdirectory/exchange?json")!)
            let rows = try JSONDecoder().decode([Row].self, from: d)
            var uah: [String: Decimal] = ["UAH": 1]
            // Go through String to keep the published decimal digits exactly.
            for r in rows { uah[r.cc] = Decimal(string: String(r.rate), locale: Locale(identifier: "en_US_POSIX")) }
            let base = store.data.settings.baseCurrency
            guard let baseRate = uah[base] else { message = L("НБУ не публикует курс для ") + base; return }
            var updated = 0
            store.updateSettings { s in
                var codes = Set(s.rates.keys)
                for w in store.data.wallets { codes.insert(w.currency) }
                for t in store.data.transactions { codes.insert(t.currency) }
                for code in codes where code != base {
                    if let r = uah[code] {
                        let v = r / baseRate
                        s.rates[code] = NSDecimalNumber(decimal: v).rounding(accordingToBehavior: NSDecimalNumberHandler(roundingMode: .plain, scale: 6, raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false)).stringValue
                        updated += 1
                    }
                }
                s.ratesUpdatedAt = Date()
            }
            message = L("Обновлено курсов: ") + "\(updated)"
        } catch {
            message = L("Не удалось загрузить: ") + error.localizedDescription
        }
    }
}

// MARK: CSV

struct DataTransferView: View {
    @Environment(Store.self) private var store
    @State private var share: IdentifiableURL?
    @State private var importing = false
    @State private var plan: CSVExchange.ImportPlan?
    @State private var planName = ""
    @State private var error: String?
    @State private var exportPeriodOnly = false
    @State private var parsing = false

    var body: some View {
        Form {
            Section {
                Toggle(L("Только выбранный период"), isOn: $exportPeriodOnly)
                Button {
                    do {
                        let txs = exportPeriodOnly ? Analytics.filter(store.data, period: store.period) : nil
                        share = IdentifiableURL(url: try store.exportCSV(txs))
                    } catch { self.error = error.localizedDescription }
                } label: { Label(L("Экспорт в CSV"), systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("export-csv")
            } header: { Text(L("Экспорт")) } footer: {
                Text(L("Колонки: Date, Type, Amount, Currency, Category, Wallet, Note, Labels. Файл открывается в Excel/Numbers и импортируется обратно."))
            }
            Section {
                Button { importing = true } label: {
                    HStack { Label(L("Импорт из CSV"), systemImage: "square.and.arrow.down"); Spacer(); if parsing { ProgressView() } }
                }
            } header: { Text(L("Импорт")) } footer: {
                Text(L("Поддерживаются файлы этого приложения и экспорт Spendee (Date, Wallet, Type, Category name, Amount, Currency, Note, Labels). Перед импортом автоматически создаётся резервная копия. Повторный импорт того же файла не создаёт дублей."))
            }
            if let e = error { Text(e).foregroundStyle(Palette.expense) }
        }
        .navigationTitle(L("Экспорт и импорт"))
        .tabBarSafeArea()
        .sheet(item: $share) { u in ShareSheet(items: [u.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data]) { result in
            switch result {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let d = try Data(contentsOf: url)
                    let text = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1251) ?? ""
                    planName = url.lastPathComponent
                    let snapshot = store.data
                    parsing = true
                    Task.detached {
                        let p = CSVExchange.plan(csv: text, into: snapshot, fallbackCategoryName: "Other")
                        await MainActor.run { plan = p; parsing = false }
                    }
                } catch { self.error = error.localizedDescription }
            case .failure(let e): error = e.localizedDescription
            }
        }
        .sheet(isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } })) {
            if let p = plan { ImportPreview(plan: p, fileName: planName) { plan = nil } }
        }
    }
}

struct ImportPreview: View {
    @Environment(Store.self) private var store
    let plan: CSVExchange.ImportPlan
    let fileName: String
    var done: () -> Void
    @State private var removeUnused = true
    @State private var showMonths = false

    var body: some View {
        let src = plan.sourceTotals, dst = plan.plannedTotals
        let ok = src == dst && plan.mismatchedMonths.isEmpty
        let unusedCats = plan.unusedCategoryIDs.compactMap { store.data.category($0)?.name }
        let unusedWallets = plan.unusedWalletIDs.compactMap { store.data.wallet($0)?.name }
        NavigationStack {
            List {
                Section(fileName) {
                    LabeledContent(L("Строк в файле"), value: "\(plan.rowCount)")
                    LabeledContent(L("Новых операций"), value: "\(plan.transactions.count)")
                    LabeledContent(L("Пропущено дублей"), value: "\(plan.duplicates)")
                    if !plan.errors.isEmpty { LabeledContent(L("Строк с ошибками"), value: "\(plan.errors.count)") }
                    if plan.pairedTransfers > 0 { LabeledContent(L("Переводы между кошельками"), value: "\(plan.pairedTransfers)") }
                    if plan.unpairedTransfers > 0 { LabeledContent(L("Переводы без пары (как доход/расход)"), value: "\(plan.unpairedTransfers)") }
                    LabeledContent(L("Новых категорий"), value: "\(plan.newCategories.count)")
                    LabeledContent(L("Новых меток"), value: "\(plan.newLabels.count)")
                    LabeledContent(L("Новых кошельков"), value: "\(plan.newWallets.count)")
                }
                Section {
                    let currencies = Set(src.income.keys).union(src.expense.keys).sorted()
                    ForEach(currencies, id: \.self) { c in
                        LabeledContent(L("Доходы") + " " + c, value: Fmt.code(src.income[c] ?? 0, c))
                        LabeledContent(L("Расходы") + " " + c, value: Fmt.code(src.expense[c] ?? 0, c))
                    }
                    if plan.duplicates == 0 {
                        Label(ok ? L("Суммы совпадают с файлом, в том числе по каждому месяцу") : L("Суммы НЕ совпадают с файлом: ") + plan.mismatchedMonths.joined(separator: ", "),
                              systemImage: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(ok ? Palette.income : Palette.expense)
                    }
                    DisclosureGroup(L("По месяцам"), isExpanded: $showMonths) {
                        ForEach(plan.sourceByMonth.keys.sorted().reversed(), id: \.self) { m in
                            let t = plan.sourceByMonth[m]!
                            let cur = t.expense.keys.first ?? t.income.keys.first ?? store.data.settings.baseCurrency
                            HStack {
                                Text(m).monospacedDigit()
                                Spacer()
                                Text("+" + Fmt.code(t.income[cur] ?? 0, cur)).foregroundStyle(Palette.income).font(.footnote.monospacedDigit())
                                Text("−" + Fmt.code(t.expense[cur] ?? 0, cur)).foregroundStyle(Palette.expense).font(.footnote.monospacedDigit())
                            }
                        }
                    }
                } header: { Text(L("Сверка с файлом (без переводов)")) }
                if !unusedCats.isEmpty || !unusedWallets.isEmpty {
                    Section {
                        Toggle(L("Убрать неиспользуемые стандартные категории и кошельки"), isOn: $removeUnused)
                    } footer: {
                        Text((unusedCats + unusedWallets).joined(separator: ", "))
                    }
                }
                if !plan.newCategories.isEmpty {
                    Section(L("Будут созданы категории")) { Text(plan.newCategories.map { $0.name }.joined(separator: ", ")).font(.footnote) }
                }
                if !plan.newLabels.isEmpty {
                    Section(L("Будут созданы метки")) { Text(plan.newLabels.map { $0.name }.joined(separator: ", ")).font(.footnote) }
                }
                if !plan.errors.isEmpty {
                    Section(L("Ошибки (строки пропущены)")) {
                        ForEach(Array(plan.errors.prefix(30).enumerated()), id: \.offset) { _, e in
                            Text(L("Строка ") + "\(e.line): \(e.message)").font(.footnote).foregroundStyle(Palette.expense)
                        }
                    }
                }
            }
            .navigationTitle(L("Проверка импорта"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Отмена"), action: done) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Импортировать")) {
                        do {
                            let backup = try store.autoBackup(reason: "import")
                            if store.perform(plan.mutation(removingUnused: removeUnused), label: L("Импортировано операций: ") + "\(plan.transactions.count)", toast: false) {
                                store.show(L("Импортировано операций: ") + "\(plan.transactions.count). " + L("Копия до импорта: ") + backup, canUndo: true)
                                withAnimation { store.selectedTab = .home }
                                done()
                            }
                        } catch {
                            store.show(L("Не удалось сделать копию перед импортом: ") + error.localizedDescription, canUndo: false, isError: true)
                        }
                    }
                    .disabled(plan.transactions.isEmpty)
                    .accessibilityIdentifier("import-confirm")
                }
            }
        }
    }
}

// MARK: Backup

struct BackupView: View {
    @Environment(Store.self) private var store
    @State private var share: IdentifiableURL?
    @State private var restoring = false
    @State private var pending: BackupFile?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Button {
                    do { share = IdentifiableURL(url: try store.makeBackup()) } catch { self.error = error.localizedDescription }
                } label: { Label(L("Создать резервную копию"), systemImage: "externaldrive.badge.plus") }
            } footer: {
                Text(L("Полная копия: операции, категории (с вашими иконками), кошельки и настройки. Сохраните в «Файлы» → iCloud Drive. Ключ OpenAI в копию не попадает."))
            }
            Section {
                Button { restoring = true } label: { Label(L("Восстановить из копии"), systemImage: "arrow.counterclockwise") }
            } footer: {
                Text(L("Текущие данные будут заменены. Действие можно отменить кнопкой «Отменить» сразу после восстановления."))
            }
            Section(L("Автоматические копии")) {
                Text(L("Приложение само хранит ежедневные снимки за последние 14 дней и восстанавливается из них, если основной файл повреждён."))
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent(L("Снимков"), value: "\(store.fileStore.snapshotFiles().count)")
            }
            if let e = error { Text(e).foregroundStyle(Palette.expense) }
        }
        .navigationTitle(L("Резервная копия"))
        .sheet(item: $share) { u in ShareSheet(items: [u.url]) }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.json, .data]) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do { pending = try BackupFile.decode(Data(contentsOf: url)) } catch { self.error = L("Это не файл резервной копии WorkFlow Spend") }
            }
        }
        .confirmationDialog(L("Заменить текущие данные?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button(L("Восстановить"), role: .destructive) {
                if let p = pending {
                    do { try store.restore(p); store.show(L("Данные восстановлены"), canUndo: true) } catch { self.error = error.localizedDescription }
                }
                pending = nil
            }
        } message: {
            if let p = pending { Text(L("В копии операций: ") + "\(p.data.transactions.count), " + Fmt.fullDate(p.createdAt)) }
        }
    }
}
