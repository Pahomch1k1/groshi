import Foundation

/// The owner's Spendee categories as seen in their screenshots: order, icon meaning and colour.
/// Used when importing a Spendee export so the categories look and sort the way they did in Spendee.
public enum SpendeeCatalog {
    public struct Entry { public let name: String; public let kind: TxKind; public let symbol: String; public let color: String }

    /// Expense categories in the exact order of the Spendee category grid (46 seen on screenshots).
    public static let expense: [Entry] = [
        e("Food", "carrot.fill", "#2DBE7E"), e("Cafe", "cup.and.saucer.fill", "#E2803A"), e("Restaurant", "fork.knife", "#4CC9C0"),
        e("Gifts", "gift.fill", "#1FAE6E"), e("Games", "gamecontroller.fill", "#5B8FD6"), e("Programs", "play.fill", "#A8C83A"),
        e("Clothes", "tshirt.fill", "#E8586E"), e("Home", "house.fill", "#B08D57"), e("Gas", "fuelpump.fill", "#3EC48A"),
        e("Pharmacy", "cross.case.fill", "#EF7C8A"), e("Education", "graduationcap.fill", "#6E8FC9"), e("Sport", "soccerball", "#34A8D8"),
        e("Beauty", "camera.macro", "#E07B39"), e("Girls", "heart.fill", "#FF9F0A"), e("Zoo", "pawprint.fill", "#1DB97A"),
        e("Cigarettes", "smoke.fill", "#5B8FD6"), e("Hospital", "cross.case.fill", "#F2A20C"), e("Veterinary", "pawprint.fill", "#8A4FD8"),
        e("Bar", "mug.fill", "#D9772B"), e("Car", "car.fill", "#1DB97A"), e("Penalty", "building.columns.fill", "#5CC2AE"),
        e("Tysa", "wineglass.fill", "#79C9A0"), e("Parking", "parkingsign.circle.fill", "#8E8EA6"), e("Haircut", "scissors", "#5CC0D6"),
        e("Yumashev", "birthday.cake.fill", "#F5C518"), e("Cinema", "film.fill", "#1FA2C4"), e("Taxi", "car.side.fill", "#F5A623"),
        e("Post", "arrow.left.arrow.right", "#D65CE3"), e("Mobile number", "iphone", "#6DC93A"), e("Comfy", "laptopcomputer", "#6A88B9"),
        e("Marketing", "tag.fill", "#8A4FD8"), e("Epicentr", "shippingbox.fill", "#F0524F"), e("Lego", "teddybear.fill", "#8BD36B"),
        e("Repair", "wrench.and.screwdriver.fill", "#8EA3BF"), e("Duty", "banknote.fill", "#8EA3BF"), e("Bus/Train/Plane", "airplane", "#3BA7DC"),
        e("Travle", "theatermasks.fill", "#E8586E"), e("Moto", "motorcycle", "#1DB97A"), e("Bicycle", "bicycle", "#6DC93A"),
        e("Business", "banknote.fill", "#1FA2C4"), e("Strikeball", "scope", "#6B7280"), e("Dental", "mouth.fill", "#3EC48A"),
        e("Plan", "diamond.fill", "#1DB97A"), e("Poker", "suit.spade.fill", "#F0524F"), e("Study", "graduationcap.fill", "#8BD36B"),
        e("Hotel", "bed.double.fill", "#6DC93A")
    ]

    /// Income categories found in the export (their order in Spendee was not visible).
    public static let income: [Entry] = [
        i("Salary", "dollarsign.circle.fill", "#27B67A"), i("Business", "banknote.fill", "#1FA2C4"), i("Gifts", "gift.fill", "#1FAE6E"),
        i("Poker", "suit.spade.fill", "#F0524F"), i("Glovo", "bicycle", "#F5C518"), i("Other", "ellipsis.circle.fill", "#8395A7")
    ]

    static func e(_ n: String, _ s: String, _ c: String) -> Entry { Entry(name: n, kind: .expense, symbol: s, color: c) }
    static func i(_ n: String, _ s: String, _ c: String) -> Entry { Entry(name: n, kind: .income, symbol: s, color: c) }

    public static func entry(named name: String, kind: TxKind) -> (entry: Entry, order: Int)? {
        let list = kind == .income ? income : expense
        let key = TextNorm.normalize(name)
        guard let idx = list.firstIndex(where: { TextNorm.normalize($0.name) == key }) else { return nil }
        return (list[idx], idx + 1)
    }
}
