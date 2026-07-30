import XCTest
@testable import TheGit

/// The heatmap's arithmetic: which days the grid covers, and which step each
/// one shades to. Both are easy to get subtly wrong and impossible to check
/// by eye — a grid off by one day still looks like a grid.
final class ActivityTests: XCTestCase {
    /// A fixed Thursday, so the trailing week is always a partial one:
    /// five days behind it, two still to come.
    private let thursday = Date(timeIntervalSince1970: 1_753_920_000) // 2025-07-31 UTC

    private func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 1 // Sunday
        return cal
    }

    private func key(_ date: String, _ cal: Calendar) -> Int {
        let parts = date.split(separator: "-").map { Int($0)! }
        return ActivityDay.key(year: parts[0], month: parts[1], day: parts[2])
    }

    /// The grid is exactly `weeks` columns of seven, ending in the week that
    /// contains today.
    func testWindowShape() {
        let cal = calendar()
        let window = ActivityWindow(weeks: 5, counts: [:], today: thursday, calendar: cal)
        XCTAssertEqual(window.columns.count, 5)
        XCTAssertEqual(Set(window.columns.map(\.count)), [7])
        XCTAssertEqual(window.columns.last?[4].key, key("2025-07-31", cal))
    }

    /// Today is not in the future; the rest of its week is. This is what
    /// keeps the trailing column from claiming four idle days.
    func testFutureDays() {
        let cal = calendar()
        let window = ActivityWindow(weeks: 2, counts: [:], today: thursday, calendar: cal)
        let last = window.columns.last!
        XCTAssertEqual(last.map(\.isFuture), [false, false, false, false, false, true, true])
        XCTAssertFalse(window.columns.first!.contains { $0.isFuture })
    }

    /// Counts land on the day they belong to, and only there.
    func testCountsLandOnTheirDay() {
        let cal = calendar()
        let counts = [key("2025-07-30", cal): 3, key("2025-07-31", cal): 1]
        let window = ActivityWindow(weeks: 2, counts: counts, today: thursday, calendar: cal)
        let last = window.columns.last!
        XCTAssertEqual(last.map(\.count), [0, 0, 0, 3, 1, 0, 0])
        XCTAssertEqual(window.summary, "4 commits · 2 weeks")
    }

    /// Every day with work in it shades at least one step, however busy the
    /// repo is around it — the regression that made a shared repo's grid one
    /// flat colour was a day with commits rendering as empty.
    func testAnyWorkIsVisible() {
        XCTAssertEqual(day(count: 1).level(peak: 4), 1)
        XCTAssertEqual(day(count: 1).level(peak: 400), 1)
        XCTAssertEqual(day(count: 0).level(peak: 4), 0)
    }

    /// A repo with a steady one commit a day is a repo with a steady one
    /// commit a day — the floor under the peak keeps it on the first step
    /// instead of shading every active cell as busy as this repo ever gets.
    func testQuietRepoStaysQuiet() {
        let cal = calendar()
        var counts: [Int: Int] = [:]
        for day in 20...31 { counts[key(String(format: "2025-07-%02d", day), cal)] = 1 }
        let window = ActivityWindow(weeks: 4, counts: counts, today: thursday, calendar: cal)
        XCTAssertEqual(window.peak, 4)
        let active = window.columns.flatMap { $0 }.filter { $0.count > 0 }
        XCTAssertEqual(Set(active.map { $0.level(peak: window.peak) }), [1])
    }

    /// Quartiles of the peak, clamped at the top.
    func testLevelsSpanTheScale() {
        XCTAssertEqual([1, 10, 11, 20, 21, 30, 31, 40, 4000].map { day(count: $0).level(peak: 40) },
                       [1, 1, 2, 2, 3, 3, 4, 4, 4])
    }

    /// The peak is the 90th percentile of active days, not the maximum: one
    /// enormous merge day must not flatten the whole grid to step 1.
    func testPeakIgnoresOneOutlier() {
        let cal = calendar()
        var counts: [Int: Int] = [:]
        for day in 1...10 { counts[key(String(format: "2025-07-%02d", day), cal)] = 4 }
        counts[key("2025-07-21", cal)] = 900
        let window = ActivityWindow(weeks: 6, counts: counts, today: thursday, calendar: cal)
        XCTAssertEqual(window.peak, 4)
        // A typical day therefore still reads as busy, and the outlier is
        // simply pinned to the top step.
        XCTAssertEqual(day(count: 4).level(peak: window.peak), 4)
    }

    /// An empty repo says so rather than drawing a plausible quiet quarter.
    func testEmptyWindow() {
        let window = ActivityWindow(weeks: 4, counts: [:], today: thursday, calendar: calendar())
        XCTAssertEqual(window.peak, 4)
        XCTAssertEqual(window.summary, "No commits in 4 weeks")
        XCTAssertTrue(window.columns.flatMap { $0 }.allSatisfy { $0.level(peak: window.peak) == 0 })
    }

    /// Weekday labels are rotated to the locale's own first weekday, so the
    /// row a label names is the row it sits on.
    func testWeekdayRotation() {
        var cal = calendar()
        cal.firstWeekday = 2 // Monday
        let window = ActivityWindow(weeks: 2, counts: [:], today: thursday, calendar: cal)
        XCTAssertEqual(window.weekdayNames.first, cal.shortWeekdaySymbols[1])
        XCTAssertEqual(window.weekdayNames.last, cal.shortWeekdaySymbols[0])
    }

    /// Narrowing the panel drops the OLDEST weeks and keeps the recent
    /// ones; widening it reveals further back. Both fall out of the window
    /// being anchored to today at its trailing edge, which is the property
    /// this test pins down: a narrow grid is exactly the tail of a wide one,
    /// column for column.
    func testNarrowGridIsTheTailOfTheWideOne() {
        let cal = calendar()
        var counts: [Int: Int] = [:]
        for day in 1...31 { counts[key(String(format: "2025-07-%02d", day), cal)] = day }
        for day in 1...30 { counts[key(String(format: "2025-06-%02d", day), cal)] = day }

        let wide = ActivityWindow(weeks: 12, counts: counts, today: thursday, calendar: cal)
        let narrow = ActivityWindow(weeks: 4, counts: counts, today: thursday, calendar: cal)

        XCTAssertEqual(
            narrow.columns.map { $0.map(\.key) },
            wide.columns.suffix(4).map { $0.map(\.key) }
        )
        // And the trailing column is the current week in both.
        XCTAssertEqual(narrow.columns.last?.map(\.key), wide.columns.last?.map(\.key))
    }

    /// The grid may be shorter than the panel but never longer than the
    /// repo: a week-old repo drawn over half a year is nineteen columns of
    /// empty cells with four green ones in the corner.
    func testWeeksOfHistory() {
        let cal = calendar()
        // Today only.
        XCTAssertEqual(
            ActivityWindow.weeksOfHistory(
                counts: [key("2025-07-31", cal): 2], today: thursday, calendar: cal
            ), 1
        )
        // Eight days back is two weeks of history, rounded up.
        XCTAssertEqual(
            ActivityWindow.weeksOfHistory(
                counts: [key("2025-07-23", cal): 1, key("2025-07-31", cal): 1],
                today: thursday, calendar: cal
            ), 2
        )
        // Nothing recorded — the caller falls back to its own floor.
        XCTAssertEqual(
            ActivityWindow.weeksOfHistory(counts: [:], today: thursday, calendar: cal), 0
        )
    }

    /// A day whose count is zero doesn't extend the history — the histogram
    /// only ever carries days with work in them, but a stray zero must not
    /// stretch the grid back over an empty half-year.
    func testZeroCountsDoNotExtendHistory() {
        let cal = calendar()
        let counts = [key("2025-02-01", cal): 0, key("2025-07-29", cal): 5]
        XCTAssertEqual(
            ActivityWindow.weeksOfHistory(counts: counts, today: thursday, calendar: cal), 1
        )
    }

    private func day(count: Int) -> ActivityWindow.Day {
        ActivityWindow.Day(key: 0, count: count, isFuture: false, summary: "")
    }
}
