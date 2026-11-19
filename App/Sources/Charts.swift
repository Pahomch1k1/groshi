import SwiftUI
import GroshiCore

// MARK: Grouped bars (Home cash flow, Overview cash flow)

struct BarGroup: Identifiable, Equatable {
    let id: Date
    var top: String       // "Jun"
    var bottom: String    // "2026"
    var income: Int64
    var expense: Int64
    var selected: Bool
}

/// Green/red bar pairs with a light grid and compact axis labels, drawn by hand (not Swift Charts).
struct GroupedBarsChart: View {
    var groups: [BarGroup]
    var currency: String
    var showLabels = true
    var onSelect: ((BarGroup) -> Void)? = nil
    @State private var grow: CGFloat = 0

    var body: some View {
        let maxV = max(1, groups.map { max($0.income, $0.expense) }.max() ?? 1)
        let top = niceMax(maxV)
        GeometryReader { geo in
            let labelH: CGFloat = showLabels ? 34 : 0
            let plotH = geo.size.height - labelH
            let n = max(groups.count, 1)
            let slot = geo.size.width / CGFloat(n)
            let barW = min(18, max(3, slot * 0.28))
            ZStack(alignment: .topLeading) {
                // Grid lines with values at their left end.
                ForEach([0, 0.5, 1.0], id: \.self) { f in
                    let y = plotH - plotH * f
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }
                        .stroke(Palette.textTertiary.opacity(0.25), lineWidth: 0.6)
                    Text(f == 0 ? "0" : Fmt.compact(Int64(Double(top) * f), currency))
                        .font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
                        .position(x: 16, y: max(7, y - 8))
                }
                ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                    let cx = slot * (CGFloat(i) + 0.5)
                    let hi = plotH * CGFloat(Double(g.income) / Double(top)) * grow
                    let he = plotH * CGFloat(Double(g.expense) / Double(top)) * grow
                    bar(Palette.income, h: hi, w: barW)
                        .position(x: cx - barW / 2 - 1.5, y: plotH - hi / 2)
                    bar(Palette.expense, h: he, w: barW)
                        .position(x: cx + barW / 2 + 1.5, y: plotH - he / 2)
                    if showLabels {
                        VStack(spacing: 0) {
                            Text(g.top)
                            Text(g.bottom)
                        }
                        .font(.system(size: 12, weight: g.selected ? .bold : .regular))
                        .foregroundStyle(g.selected ? Color.primary : Palette.textTertiary)
                        .position(x: cx, y: plotH + labelH / 2 + 2)
                    }
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .frame(width: slot, height: geo.size.height)
                        .position(x: cx, y: geo.size.height / 2)
                        .onTapGesture { onSelect?(g) }
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: groups)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) { grow = 1 } }
    }

    func bar(_ c: Color, h: CGFloat, w: CGFloat) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: min(5, w / 2), bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: min(5, w / 2), style: .continuous)
            .fill(c)
            .frame(width: w, height: max(h, h > 0 ? 2 : 0))
    }

    /// 82 000 → 100 000; 251 000 → 251 000-ish rounded to a pleasant step.
    func niceMax(_ v: Int64) -> Int64 {
        let d = Double(v)
        let mag = pow(10, floor(log10(d)))
        let steps: [Double] = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]
        let m = steps.first { $0 * mag >= d } ?? 10
        return Int64(m * mag)
    }
}

// MARK: Donut with category icons around it

struct DonutSlice: Identifiable, Equatable {
    let id: UUID
    var value: Int64
    var colorHex: String
    var icon: CategoryIcon
    var percent: String
    var basisPoints: Int
}

/// Thick ring with gaps; icons and percentages sit outside each segment and are nudged apart so they never overlap.
struct DonutWithIcons: View {
    var slices: [DonutSlice]
    var onTap: ((UUID) -> Void)? = nil
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let rOuter = side * 0.27
            let thickness = rOuter * 0.46
            let rIcon = rOuter + 30
            let rText = rOuter + 66
            let total = Double(max(1, slices.reduce(0) { $0 + $1.value }))
            let arcs = arcs(total: total)
            let labels = layoutLabels(arcs: arcs, rIcon: rIcon)

            ZStack {
                // Segments
                ForEach(arcs, id: \.slice.id) { a in
                    let gap = slices.count > 1 ? 0.012 : 0
                    RingSegment(start: a.start + gap / 2, end: a.start + (a.end - a.start) * Double(progress) - gap / 2, thickness: thickness)
                        .fill(Color(hex: a.slice.colorHex))
                        .frame(width: rOuter * 2, height: rOuter * 2)
                        .position(center)
                        .onTapGesture { onTap?(a.slice.id) }
                    // Inner darker band like Spendee's two-tone ring.
                    RingSegment(start: a.start + gap / 2, end: a.start + (a.end - a.start) * Double(progress) - gap / 2, thickness: thickness * 0.22)
                        .fill(Color.black.opacity(0.08))
                        .frame(width: (rOuter - thickness * 0.78) * 2, height: (rOuter - thickness * 0.78) * 2)
                        .position(center)
                        .allowsHitTesting(false)
                }
                // Icons and percentages
                ForEach(labels, id: \.slice.id) { l in
                    let ip = point(center, rIcon, l.angle)
                    let tp = point(center, rText, l.angle)
                    CategoryIconView(icon: l.slice.icon, colorHex: l.slice.colorHex, size: 32)
                        .position(ip)
                        .onTapGesture { onTap?(l.slice.id) }
                    Text(l.slice.percent)
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color(hex: l.slice.colorHex))
                        .position(tp)
                }
                .opacity(Double(progress))
            }
        }
        .onAppear { progress = 0; withAnimation(.spring(response: 0.9, dampingFraction: 0.85)) { progress = 1 } }
        .onChange(of: slices) { _, _ in progress = 0.0001; withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) { progress = 1 } }
    }

    struct Arc { let slice: DonutSlice; let start: Double; let end: Double }
    struct Label { let slice: DonutSlice; var angle: Double }

    /// Angles in radians, starting at 12 o'clock, clockwise.
    func arcs(total: Double) -> [Arc] {
        var a = -Double.pi / 2
        return slices.map { s in
            let sweep = Double(s.value) / total * 2 * .pi
            defer { a += sweep }
            return Arc(slice: s, start: a, end: a + sweep)
        }
    }

    func layoutLabels(arcs: [Arc], rIcon: CGFloat) -> [Label] {
        // Minimum angle between neighbours so 32pt icons (plus air) don't touch.
        let minSep = 2 * asin(min(1, 40 / (2 * Double(rIcon))))
        let capacity = max(1, Int((2 * .pi) / minSep))
        // Show the biggest slices that fit; tiny ones (<2%) get no label.
        let shown = arcs.filter { $0.slice.basisPoints >= 200 }
            .sorted { $0.slice.value > $1.slice.value }
            .prefix(capacity)
        var labels = shown.map { Label(slice: $0.slice, angle: ($0.start + $0.end) / 2) }.sorted { $0.angle < $1.angle }
        guard labels.count > 1 else { return labels }
        // Relax: push apart forward, then backward, a few times.
        for _ in 0..<6 {
            for i in 1..<labels.count where labels[i].angle - labels[i - 1].angle < minSep {
                labels[i].angle = labels[i - 1].angle + minSep
            }
            let wrap = labels[0].angle + 2 * .pi
            if wrap - labels[labels.count - 1].angle < minSep { labels[labels.count - 1].angle = wrap - minSep }
            for i in stride(from: labels.count - 2, through: 0, by: -1) where labels[i + 1].angle - labels[i].angle < minSep {
                labels[i].angle = labels[i + 1].angle - minSep
            }
        }
        return labels
    }

    func point(_ c: CGPoint, _ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
    }
}

/// Ring segment between two angles (radians), drawn inside its frame.
struct RingSegment: Shape {
    var start: Double
    var end: Double
    var thickness: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start, end) }
        set { start = newValue.first; end = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard end > start else { return p }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        p.addArc(center: c, radius: r, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        p.addArc(center: c, radius: r - thickness, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        p.closeSubpath()
        return p
    }
}
