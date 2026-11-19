import Foundation

public enum PeriodKind: String, Codable, CaseIterable, Hashable {
    case day, week, month, year, all, custom
}

/// A half-open date interval [start, end).
public struct Period: Hashable {
    public var kind: PeriodKind
    public var start: Date
    public var end: Date

    public init(kind: PeriodKind, start: Date, end: Date) {
        self.kind = kind; self.start = start; self.end = end
    }

    public static func calendar(firstWeekday: Int = 2, timeZone: TimeZone = .current) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = firstWeekday
        c.timeZone = timeZone
        return c
    }

    public static func containing(_ date: Date, kind: PeriodKind, calendar cal: Calendar) -> Period {
        switch kind {
        case .day:
            let s = cal.startOfDay(for: date)
            return Period(kind: kind, start: s, end: cal.date(byAdding: .day, value: 1, to: s)!)
        case .week:
            let s = cal.dateInterval(of: .weekOfYear, for: date)!.start
            return Period(kind: kind, start: s, end: cal.date(byAdding: .day, value: 7, to: s)!)
        case .month:
            let s = cal.dateInterval(of: .month, for: date)!.start
            return Period(kind: kind, start: s, end: cal.date(byAdding: .month, value: 1, to: s)!)
        case .year:
            let s = cal.dateInterval(of: .year, for: date)!.start
            return Period(kind: kind, start: s, end: cal.date(byAdding: .year, value: 1, to: s)!)
        case .all, .custom:
            return Period(kind: .all, start: Date.distantPast, end: Date.distantFuture)
        }
    }

    public static func custom(from: Date, to: Date, calendar cal: Calendar) -> Period {
        let s = cal.startOfDay(for: min(from, to))
        let e = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(from, to)))!
        return Period(kind: .custom, start: s, end: e)
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    public var canStep: Bool { kind != .all && kind != .custom }

    public func shifted(by n: Int, calendar cal: Calendar) -> Period {
        let comp: Calendar.Component
        switch kind {
        case .day: comp = .day
        case .week: comp = .weekOfYear
        case .month: comp = .month
        case .year: comp = .year
        case .all, .custom: return self
        }
        let s = cal.date(byAdding: comp, value: n, to: start)!
        return Period.containing(s, kind: kind, calendar: cal)
    }

    /// The previous period of the same length (for comparisons).
    public func previous(calendar cal: Calendar) -> Period { shifted(by: -1, calendar: cal) }
}
