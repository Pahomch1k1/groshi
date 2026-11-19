import Foundation

public enum Recurrence {
    public static func advance(_ date: Date, by f: Frequency, calendar cal: Calendar) -> Date {
        switch f {
        case .daily: return cal.date(byAdding: .day, value: 1, to: date)!
        case .weekly: return cal.date(byAdding: .day, value: 7, to: date)!
        case .monthly: return cal.date(byAdding: .month, value: 1, to: date)!
        case .yearly: return cal.date(byAdding: .year, value: 1, to: date)!
        }
    }

    /// Creates every transaction that became due up to `now` and moves each rule's `nextDate` forward.
    /// Returns the number of transactions created. Safe to call repeatedly (idempotent for a given `now`).
    @discardableResult
    public static func catchUp(_ data: inout AppData, now: Date, calendar cal: Calendar, limitPerRule: Int = 400) -> Int {
        var created = 0
        for i in data.recurring.indices where data.recurring[i].isActive {
            var rule = data.recurring[i]
            var n = 0
            while rule.nextDate <= now && n < limitPerRule {
                if let end = rule.endDate, rule.nextDate > end { rule.isActive = false; break }
                var t = rule.template
                t.id = UUID()
                t.date = rule.nextDate
                t.createdAt = now
                t.recurringID = rule.id
                // Skip silently if the template became invalid (deleted wallet/category).
                var check = data
                if (try? Mutation.addTransactions([t]).apply(to: &check)) != nil {
                    data.transactions.append(t)
                    created += 1
                }
                rule.nextDate = advance(rule.nextDate, by: rule.frequency, calendar: cal)
                n += 1
            }
            data.recurring[i] = rule
        }
        return created
    }

    /// Upcoming occurrences inside a period (for the "Scheduled" card).
    public static func upcoming(_ data: AppData, in period: Period, after now: Date, calendar cal: Calendar) -> [(rule: RecurringRule, date: Date)] {
        var out: [(RecurringRule, Date)] = []
        for r in data.recurring where r.isActive {
            var d = r.nextDate
            var n = 0
            while d < period.end && n < 400 {
                if let end = r.endDate, d > end { break }
                if d >= period.start && d > now { out.append((r, d)) }
                d = advance(d, by: r.frequency, calendar: cal)
                n += 1
            }
        }
        return out.sorted { $0.1 < $1.1 }
    }
}
