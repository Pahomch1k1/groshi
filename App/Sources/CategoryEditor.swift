import SwiftUI
import PhotosUI
import GroshiCore

/// "Create New Category": preview, rounded name field, colour row, 5-column icon grid; plus emoji and own image.
struct CategoryEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let category: FinCategory?
    var onSave: (FinCategory) -> Void

    @State private var name = ""
    @State private var kind: TxKind
    @State private var color = "#6CC644"
    @State private var icon: CategoryIcon = .symbol("tag.fill")
    @State private var emoji = ""
    @State private var photo: PhotosPickerItem?
    @State private var showEmoji = false
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    static let colors = ["#6CC644", "#F25C54", "#FF9F0A", "#F5C518", "#1FA2C4", "#FF6FB5", "#2E86DE", "#8A4FD8",
                         "#1BC47D", "#E07B39", "#B08D57", "#5CC0D6", "#8E8EA6", "#E8586E", "#3BA7DC", "#576574"]

    init(category: FinCategory?, kind: TxKind, onSave: @escaping (FinCategory) -> Void) {
        self.category = category
        self.onSave = onSave
        _kind = State(initialValue: category?.kind ?? kind)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Palette.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    CircleButton(systemImage: "xmark") { dismiss() }
                    Spacer()
                    Text(category == nil ? L("Новая категория") : L("Категория")).font(.system(size: 19, weight: .semibold))
                    Spacer()
                    CircleButton(systemImage: "checkmark") { save() }
                        .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                        .accessibilityIdentifier("category-save")
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        preview
                            .frame(maxWidth: .infinity)
                            .padding(.top, 18)

                        HStack {
                            Text(L("Название")).font(.system(size: 16)).foregroundStyle(Palette.textSecondary)
                            TextField(L("Название категории"), text: $name)
                                .font(.system(size: 18))
                                .multilineTextAlignment(.trailing)
                                .focused($nameFocused)
                                .accessibilityIdentifier("category-name")
                        }
                        .padding(.horizontal, 22).frame(height: 64)
                        .background(Palette.card, in: Capsule())
                        .shadow(color: Palette.shadow, radius: 10, y: 3)
                        .padding(.top, 26)

                        if category.map({ c in store.data.transactions.contains { $0.categoryID == c.id } }) != true {
                            KindSegment(kind: $kind, haptics: store.data.settings.haptics)
                                .padding(.top, 14)
                        }

                        Text(L("Цвет категории")).font(.system(size: 16)).foregroundStyle(Palette.textSecondary)
                            .padding(.top, 22)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Self.colors, id: \.self) { c in
                                    ZStack {
                                        Circle().fill(color == c ? Color(hex: c) : Palette.card)
                                            .shadow(color: Palette.shadow, radius: 4, y: 2)
                                        if color != c { Circle().fill(Color(hex: c)).frame(width: 16, height: 16) }
                                    }
                                    .frame(width: 54, height: 54)
                                    .onTapGesture { Haptics.select(); withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { color = c } }
                                }
                                ColorPicker("", selection: Binding(get: { Color(hex: color) }, set: { color = $0.hexString }), supportsOpacity: false)
                                    .labelsHidden().frame(width: 54, height: 54)
                            }
                            .padding(.vertical, 8).padding(.horizontal, 2)
                        }
                        .padding(.top, 6)

                        HStack {
                            Text(L("Иконка категории")).font(.system(size: 16)).foregroundStyle(Palette.textSecondary)
                            Spacer()
                            Button { showEmoji = true } label: { Chip(text: "😀 " + L("Эмодзи")) }.buttonStyle(.plain)
                            PhotosPicker(selection: $photo, matching: .images) { Chip(text: L("Своя"), systemImage: "photo") }
                        }
                        .padding(.top, 18)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 12) {
                            ForEach(IconLibrary.all, id: \.self) { s in
                                let on = icon == .symbol(s)
                                Image(systemName: s)
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(on ? Color(hex: color) : Color(hex: "#9AA7B4"))
                                    .frame(width: 62, height: 62)
                                    .background(on ? Palette.pastel(color, 0.22) : Palette.card, in: Circle())
                                    .overlay(Circle().strokeBorder(on ? Color(hex: color) : .clear, lineWidth: 2))
                                    .scaleEffect(on ? 1.06 : 1)
                                    .onTapGesture { Haptics.select(); withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { icon = .symbol(s) } }
                            }
                        }
                        .padding(.top, 12)

                        if let c = category {
                            Button(role: .destructive) { confirmDelete = true } label: {
                                Text(L("Удалить категорию")).font(.system(size: 17, weight: .medium))
                                    .frame(maxWidth: .infinity).frame(height: 54)
                                    .background(Palette.card, in: Capsule())
                            }
                            .padding(.top, 24)
                            .sheet(isPresented: $confirmDelete) { DeleteCategorySheet(category: c).presentationDetents([.medium]) }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .presentationCornerRadius(38)
        .onAppear {
            if let c = category {
                name = c.name; color = c.colorHex; icon = c.icon
            } else {
                color = Self.colors[store.data.categories.count % Self.colors.count]
                nameFocused = true
            }
        }
        .onChange(of: photo) { _, item in
            Task {
                if let d = try? await item?.loadTransferable(type: Data.self), let ui = UIImage(data: d), let file = store.saveIcon(ui) {
                    withAnimation(.spring) { icon = .image(file) }
                }
            }
        }
        .alert(L("Эмодзи"), isPresented: $showEmoji) {
            TextField("😀", text: $emoji)
            Button(L("Отмена"), role: .cancel) {}
            Button(L("Готово")) {
                if let ch = emoji.last, ch.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x238C }) {
                    withAnimation(.spring) { icon = .emoji(String(ch)) }
                }
                emoji = ""
            }
        } message: { Text(L("Переключите клавиатуру на эмодзи 😀")) }
    }

    var preview: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hex: color).opacity(0.35), Color(hex: color).opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
            CategoryIconView(icon: icon, colorHex: color, size: 104)
                .opacity(icon == .symbol("tag.fill") && category == nil ? 0.0 : 1)
        }
        .frame(width: 104, height: 104)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: icon)
        .animation(.easeInOut(duration: 0.25), value: color)
    }

    func save() {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { Haptics.error(); return }
        var c = category ?? FinCategory(name: clean, kind: kind, icon: icon, colorHex: color)
        c.name = clean; c.kind = kind; c.icon = icon; c.colorHex = color
        if store.perform(.upsertCategory(c), label: (category == nil ? L("Категория создана: ") : L("Категория изменена: ")) + c.name) {
            onSave(c)
            dismiss()
        }
    }
}

enum IconLibrary {
    /// Ordered like Spendee's picker: the most common meanings first.
    static let all: [String] = [
        "car.fill", "airplane", "fork.knife", "person.fill", "banknote.fill",
        "theatermasks.fill", "house.fill", "bolt.fill", "bag.fill", "bed.double.fill",
        "cross.case.fill", "shippingbox.fill", "tshirt.fill", "tram.fill", "carrot.fill",
        "wineglass.fill", "soccerball", "pawprint.fill", "graduationcap.fill", "film.fill",
        "heart.fill", "train.side.front.car", "building.columns.fill", "music.note", "wallet.pass.fill",
        "gift.fill", "dumbbell.fill", "iphone", "cup.and.saucer.fill", "mug.fill",
        "cart.fill", "basket.fill", "takeoutbag.and.cup.and.straw.fill", "birthday.cake.fill", "fish.fill",
        "bus.fill", "car.side.fill", "bicycle", "motorcycle", "fuelpump.fill",
        "parkingsign.circle.fill", "wrench.and.screwdriver.fill", "hammer.fill", "paintbrush.fill", "scissors",
        "pills.fill", "stethoscope", "mouth.fill", "camera.macro", "sparkles",
        "gamecontroller.fill", "play.fill", "laptopcomputer", "tv.fill", "headphones",
        "book.fill", "ticket.fill", "beach.umbrella.fill", "tent.fill", "mountain.2.fill",
        "teddybear.fill", "figure.2.and.child.holdinghands", "stroller.fill", "dog.fill", "cat.fill",
        "creditcard.fill", "dollarsign.circle.fill", "hryvniasign.circle.fill", "chart.line.uptrend.xyaxis", "briefcase.fill",
        "percent", "doc.text.fill", "tag.fill", "diamond.fill", "suit.spade.fill",
        "smoke.fill", "scope", "wifi", "phone.fill", "drop.fill",
        "flame.fill", "leaf.fill", "lock.fill", "shield.fill", "globe",
        "arrow.left.arrow.right", "repeat", "star.fill", "party.popper.fill", "ellipsis.circle.fill"
    ]
}
