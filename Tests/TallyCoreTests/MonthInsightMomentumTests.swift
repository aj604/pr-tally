import Foundation
import Testing
@testable import TallyCore

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ day: Int, hour: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
}

private let window = MonthWindow(containing: date(1), calendar: calendar)

/// A month whose full days (day 1 on) opened `daily[i]` PRs each, read at noon on the day after the last one,
/// through the same pipeline the popover uses.
func momentumReading(daily: [Int], goal: Int) -> (outlook: MonthInsightOutlook?, gap: MonthInsightPaceGap?, momentum: MonthInsightMomentum?) {
    let now = date(daily.count + 1, hour: 12)
    let opened = daily.enumerated().flatMap { offset, count in
        (0..<count).map { index in
            PullRequest(
                id: "\(offset)-\(index)", title: "A change", url: URL(string: "https://github.com/me/app/pull/1")!,
                createdAt: date(offset + 1, hour: 12), mergedAt: nil, repository: .init(nameWithOwner: "me/app")
            )
        }
    }
    let snapshot = MonthSnapshot(
        login: "me", window: window, opened: opened, merged: [], totalContributions: 0, fetchedAt: now
    )
    let pace = Pace(goal: goal, count: opened.count, window: window, at: now)
    let outlook = snapshot.projection(for: .opened, at: now).flatMap { MonthInsightOutlook(projection: $0, goal: goal) }
    let gap = MonthInsightPaceGap(
        pace: pace, today: 0, activity: MonthInsightActivity(snapshot: snapshot, metric: .opened, at: now)
    )
    return (outlook, gap, MonthInsightMomentum(outlook: outlook, gap: gap))
}

@Suite struct MonthInsightMomentumTests {
    // Read at noon on day 18. Ten steady 9-a-day days, then a quiet week (0, 0, 0, 0, 1, 0, 2).
    private let quietLately = [10, 9, 9, 8, 8, 8, 10, 10, 9, 9, 0, 0, 0, 0, 1, 0, 2]
    // Three PRs a day for ten days, then a busy week of 8 and 9 a day.
    private let busyLately = [3, 1, 3, 1, 1, 1, 3, 3, 2, 3, 8, 9, 8, 9, 9, 9, 10]

    @Test func aMonthThatReachesTheGoalBeforeAQuietWeekIsSlowing() throws {
        let reading = momentumReading(daily: quietLately, goal: 128)
        #expect(reading.outlook == .likelyToReach)
        #expect(try #require(reading.gap).verdict == .steepClimb)
        #expect(reading.momentum == .slowing)
    }

    @Test func aMonthThatFallsShortBeforeABusyWeekIsCatchingUp() throws {
        let reading = momentumReading(daily: busyLately, goal: 186)
        #expect(reading.outlook == .outOfReach)
        #expect(try #require(reading.gap).verdict == .covered)
        #expect(reading.momentum == .catchingUp)
    }

    @Test func agreeingReadingsSayNothing() {
        // The same weeks against goals both readings call easy, or both call hopeless.
        #expect(momentumReading(daily: quietLately, goal: 60).momentum == nil)
        #expect(momentumReading(daily: busyLately, goal: 2000).momentum == nil)
    }

    @Test func aGoalInsideTheRangeIsNeverCalledADisagreement() {
        for goal in stride(from: 60, through: 400, by: 2) {
            let reading = momentumReading(daily: quietLately, goal: goal)
            if reading.outlook == .withinRange { #expect(reading.momentum == nil, "goal \(goal)") }
        }
    }

    @Test func nothingIsSaidOnceTheGoalIsReachedOrBeforeThereAreEnoughDays() {
        // 93 counted: a goal of 93 is reached, and so is a lower one.
        #expect(momentumReading(daily: quietLately, goal: 93).momentum == nil)
        #expect(momentumReading(daily: quietLately, goal: 60).momentum == nil)
        #expect(MonthInsightMomentum(outlook: nil, gap: nil) == nil)
        #expect(momentumReading(daily: [5, 5], goal: 100).momentum == nil)
    }

    @Test func bothKindsOfDisagreementShowUpAcrossGeneratedMonths() {
        var slowing = 0, catchingUp = 0
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        for _ in 0..<1500 {
            let length = 10 + next(15)
            let early = next(12), late = next(12)
            let daily = (0..<length).map { max(($0 < length - 7 ? early : late) + next(3) - 1, 0) }
            let total = daily.reduce(0, +)
            let goal = max(total / 2 + next(max(total * 2, 1)), 1)
            let reading = momentumReading(daily: daily, goal: goal)
            // Whatever the pipeline produces, a named momentum is exactly the one pairing of the two readings.
            switch reading.momentum {
            case .slowing?:
                slowing += 1
                #expect(reading.outlook == .likelyToReach && reading.gap?.verdict != .covered)
            case .catchingUp?:
                catchingUp += 1
                #expect(reading.outlook == .outOfReach && reading.gap?.verdict == .covered)
            case nil:
                #expect(!(reading.outlook == .likelyToReach && reading.gap?.verdict != nil && reading.gap?.verdict != .covered))
                #expect(!(reading.outlook == .outOfReach && reading.gap?.verdict == .covered))
            }
        }
        #expect(slowing > 0 && catchingUp > 0)
    }
}
