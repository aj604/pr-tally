import Foundation

/// The calendar month containing a date, in the user's time zone.
public struct MonthWindow: Sendable, Equatable {
    public let start: Date
    /// First instant of the next month (exclusive).
    public let end: Date
    public let calendar: Calendar

    public init(containing date: Date, calendar: Calendar = .current) {
        let start = calendar.dateInterval(of: .month, for: date)!
        self.start = start.start
        self.end = start.end
        self.calendar = calendar
    }

    public var dayCount: Int {
        calendar.range(of: .day, in: .month, for: start)!.count
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    /// Zero-based day of the month, or nil when the date is outside this month.
    public func dayIndex(of date: Date) -> Int? {
        guard contains(date) else { return nil }
        return calendar.component(.day, from: date) - 1
    }

    /// Portion of the month that has passed, from 0 to 1.
    public func elapsedFraction(at now: Date) -> Double {
        let fraction = now.timeIntervalSince(start) / end.timeIntervalSince(start)
        return min(max(fraction, 0), 1)
    }

    /// Calendar days left in the month, counting today.
    public func daysRemaining(at now: Date) -> Int {
        guard now < end else { return 0 }
        guard let today = dayIndex(of: now) else { return dayCount }
        return dayCount - today
    }
}
