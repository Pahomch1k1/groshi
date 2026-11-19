import SwiftUI
import PhotosUI
import GroshiCore

/// Create/edit a category: name, kind, colour and icon (built-in library, emoji or own image).
struct CategoryEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let category: FinCategory?
    var onSave: (FinCategory) -> Void

    @State private var name = ""
    @State private var kind: TxKind
    @State private var color = "#FF9F43"
    @State private var icon: CategoryIcon = .symbol("tag.fill")
    @State private var mode = 0
    @State private var emoji = ""
    @State private var photo: PhotosPickerItem?
    @State private var search = ""

    init(category: FinCategory?, kind: TxKind, onSave: @escaping (FinCategory) -> Void) {
        self.category = category
        self.onSave = onSave
        _kind = State(initialValue: category?.kind ?? kind)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        CategoryIconView(icon: icon, colorHex: color, size: 56)
                            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: icon)
                        TextField(L("Название"), text: $name).font(.title3).accessibilityIdentifier("category-name")
                    }
                    Picker(L("Тип"), selection: $kind) {
                        Text(L("Расход")).tag(TxKind.expense)
                        Text(L("Доход")).tag(TxKind.income)
                    }
                    .pickerStyle(.segmented)
                    .disabled(category.map { c in store.data.transactions.contains { $0.categoryID == c.id } } ?? false)
                }
                Section(L("Цвет")) { ColorRow(hex: $color) }
                Section(L("Иконка")) {
                    Picker("", selection: $mode) {
                        Text(L("Библиотека")).tag(0)
                        Text(L("Эмодзи")).tag(1)
                        Text(L("Своя")).tag(2)
                    }
                    .pickerStyle(.segmented)
                    switch mode {
                    case 0: symbolLibrary
                    case 1:
                        TextField(L("Введите эмодзи"), text: $emoji)
                            .font(.largeTitle)
                            .onChange(of: emoji) { _, v in
                                if let first = v.last, first.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x238C }) {
                                    icon = .emoji(String(first))
                                    if v.count > 1 { emoji = String(first) }
                                }
                            }
                        Text(L("Переключите клавиатуру на эмодзи 😀")).font(.footnote).foregroundStyle(.secondary)
                    default:
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label(L("Выбрать изображение"), systemImage: "photo.on.rectangle")
                        }
                        .onChange(of: photo) { _, item in
                            Task {
                                if let d = try? await item?.loadTransferable(type: Data.self), let ui = UIImage(data: d),
                                   let file = store.saveIcon(ui) {
                                    icon = .image(file)
                                }
                            }
                        }
                        Text(L("Картинка будет обрезана в круг и сохранена в приложении.")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(category == nil ? L("Новая категория") : L("Категория"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Сохранить"), action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("category-save")
                }
            }
            .onAppear {
                if let c = category {
                    name = c.name; color = c.colorHex; icon = c.icon
                    switch c.icon {
                    case .symbol: mode = 0
                    case .emoji(let e): mode = 1; emoji = e
                    case .image: mode = 2
                    }
                } else {
                    color = Defaults.palette[store.data.categories.count % Defaults.palette.count]
                }
            }
        }
    }

    var symbolLibrary: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L("Поиск иконки (англ.)"), text: $search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            let list = search.isEmpty ? IconLibrary.all : IconLibrary.all.filter { $0.contains(search.lowercased()) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                ForEach(list, id: \.self) { s in
                    let on = icon == .symbol(s)
                    Image(systemName: s)
                        .font(.system(size: 18))
                        .frame(width: 42, height: 42)
                        .foregroundStyle(on ? .white : Color(hex: color))
                        .background(on ? Color(hex: color) : Color(hex: color).opacity(0.15), in: Circle())
                        .onTapGesture { Haptics.select(); withAnimation(.snappy) { icon = .symbol(s) } }
                }
            }
        }
    }

    func save() {
        var c = category ?? FinCategory(name: name, kind: kind, icon: icon, colorHex: color)
        c.name = name; c.kind = kind; c.icon = icon; c.colorHex = color
        if store.perform(.upsertCategory(c), label: (category == nil ? L("Категория создана: ") : L("Категория изменена: ")) + c.name) {
            onSave(c)
            dismiss()
        }
    }
}

enum IconLibrary {
    static let all: [String] = [
        // food & drink
        "cart.fill", "basket.fill", "fork.knife", "cup.and.saucer.fill", "mug.fill", "wineglass.fill", "birthday.cake.fill",
        "carrot.fill", "fish.fill", "takeoutbag.and.cup.and.straw.fill", "popcorn.fill", "waterbottle.fill",
        // transport
        "car.fill", "car.side.fill", "bus.fill", "tram.fill", "tram.fill.tunnel", "bicycle", "scooter", "fuelpump.fill", "ev.charger.fill",
        "parkingsign.circle.fill", "airplane", "ferry.fill", "sailboat.fill", "train.side.front.car", "steeringwheel", "wrench.and.screwdriver.fill",
        // home
        "house.fill", "building.2.fill", "bed.double.fill", "sofa.fill", "lamp.desk.fill", "bolt.fill", "drop.fill", "flame.fill",
        "wifi", "phone.fill", "tv.fill", "washer.fill", "key.fill", "hammer.fill", "paintbrush.fill", "leaf.fill",
        // shopping
        "bag.fill", "tshirt.fill", "shoe.fill", "eyeglasses", "handbag.fill", "giftcard.fill", "gift.fill", "tag.fill", "barcode",
        "iphone", "laptopcomputer", "desktopcomputer", "headphones", "gamecontroller.fill", "camera.fill", "watch.analog",
        // health & beauty
        "cross.case.fill", "pills.fill", "heart.fill", "stethoscope", "bandage.fill", "figure.run", "dumbbell.fill",
        "sparkles", "comb.fill", "scissors", "mouth.fill", "brain.head.profile",
        // leisure
        "film.fill", "music.note", "ticket.fill", "theatermasks.fill", "book.fill", "books.vertical.fill", "paintpalette.fill",
        "beach.umbrella.fill", "tent.fill", "mountain.2.fill", "soccerball", "tennis.racket", "figure.pool.swim", "smoke.fill",
        "party.popper.fill", "balloon.fill", "dice.fill", "puzzlepiece.fill",
        // people & pets
        "person.fill", "person.2.fill", "figure.2.and.child.holdinghands", "stroller.fill", "graduationcap.fill", "pawprint.fill", "dog.fill", "cat.fill",
        // money & work
        "banknote.fill", "creditcard.fill", "dollarsign.circle.fill", "eurosign.circle.fill", "hryvniasign.circle.fill", "chart.line.uptrend.xyaxis",
        "briefcase.fill", "building.columns.fill", "percent", "doc.text.fill", "signature", "hand.thumbsup.fill",
        "arrow.left.arrow.right", "repeat", "lock.fill", "shield.fill", "globe", "star.fill", "ellipsis.circle.fill"
    ]
}
