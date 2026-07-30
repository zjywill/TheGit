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
        // Two columns wide, but a repo whose first commit was yesterday —
        // the caption reports the repo, not the grid.
        XCTAssertEqual(window.summary, "4 commits · 1 week")
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

    /// A repo younger than the grid's six-column floor. The columns before
    /// its first commit are prehistory — days it wasn't there for — and not
    /// weeks it sat idle, which is what they used to be indistinguishable
    /// from. The window here is Jun 22 – Aug 2; the repo starts Jul 21.
    func testPrehistoryEndsAtTheFirstCommit() {
        let cal = calendar()
        var counts: [Int: Int] = [:]
        for day in 21...31 { counts[key(String(format: "2025-07-%02d", day), cal)] = 1 }
        let window = ActivityWindow(weeks: 6, counts: counts, today: thursday, calendar: cal)

        XCTAssertTrue(window.columns[0].allSatisfy(\.isPrehistory))
        XCTAssertTrue(window.columns[3].allSatisfy(\.isPrehistory))
        // The boundary falls mid-column: Jul 20 is prehistory, Jul 21 isn't.
        XCTAssertEqual(
            window.columns[4].map(\.isPrehistory),
            [true, false, false, false, false, false, false]
        )
        XCTAssertTrue(window.columns[5].allSatisfy { !$0.isPrehistory })
    }

    /// A repo older than the window has no prehistory on screen — the flag
    /// marks padding, not the mere fact of a left edge.
    func testNoPrehistoryWhenTheRepoOutrunsTheWindow() {
        let cal = calendar()
        var counts: [Int: Int] = [:]
        for day in 1...30 { counts[key(String(format: "2025-06-%02d", day), cal)] = 1 }
        let window = ActivityWindow(weeks: 4, counts: counts, today: thursday, calendar: cal)
        XCTAssertTrue(window.columns.flatMap { $0 }.allSatisfy { !$0.isPrehistory })
    }

    /// An empty repo has no first commit to be earlier than, so none of its
    /// days are prehistory: the caption carries that news on its own.
    func testEmptyRepoHasNoPrehistory() {
        let window = ActivityWindow(weeks: 6, counts: [:], today: thursday, calendar: calendar())
        XCTAssertTrue(window.columns.flatMap { $0 }.allSatisfy { !$0.isPrehistory })
        XCTAssertEqual(window.summary, "No commits in 6 weeks")
    }

    /// The caption counts the weeks the repo has been alive for, not the
    /// columns the floor padded it out to — "6 weeks" over four columns of
    /// prehistory is the grey cells' old lie, retold in words.
    func testCaptionReportsTheRepoSpanNotTheGridWidth() {
        let cal = calendar()
        var counts: [Int: Int] = [:]
        for day in 21...31 { counts[key(String(format: "2025-07-%02d", day), cal)] = 1 }
        XCTAssertEqual(
            ActivityWindow(weeks: 6, counts: counts, today: thursday, calendar: cal).summary,
            "11 commits · 2 weeks"
        )
        // Singular where it's singular, now that one week is reachable.
        XCTAssertEqual(
            ActivityWindow(
                weeks: 6, counts: [key("2025-07-31", cal): 2], today: thursday, calendar: cal
            ).summary,
            "2 commits · 1 week"
        )
    }

    /// A window narrower than the repo still describes what's on screen.
    func testCaptionClampsToTheWindow() {
        let cal = calendar()
        var counts: [Int: Int] = [:]
        for day in 1...31 { counts[key(String(format: "2025-07-%02d", day), cal)] = 1 }
        for day in 1...30 { counts[key(String(format: "2025-06-%02d", day), cal)] = 1 }
        let window = ActivityWindow(weeks: 3, counts: counts, today: thursday, calendar: cal)
        XCTAssertTrue(window.summary.hasSuffix("· 3 weeks"))
    }

    /// Dragging the splitter must not lose a month. The grid's right edge is
    /// pinned to this week, so each column dropped slides the window a week
    /// later and shifts every month one column left — and June used to fall
    /// off exactly when that put it three columns from the leading label
    /// instead of four.
    ///
    /// Seven columns is where the sweep starts because that's the narrowest
    /// window in which June still owns three columns. Below it June is one or
    /// two columns of leftovers at the leading edge, and yielding its name is
    /// the deliberate trade — see the tail of this test.
    func testMonthLabelsSurviveEveryWidth() {
        var cal = calendar()
        cal.firstWeekday = 2 // Monday
        for weeks in 7...14 {
            let months = ActivityWindow(
                weeks: weeks, counts: [:], today: thursday, calendar: cal
            ).months.compactMap { $0 }
            XCTAssertEqual(
                months.suffix(2), [cal.shortMonthSymbols[5], cal.shortMonthSymbols[6]],
                "June and July should both be named at \(weeks) columns"
            )
        }
        // Two columns of June left in view, and the name would crowd July's.
        XCTAssertEqual(
            ActivityWindow(weeks: 6, counts: [:], today: thursday, calendar: cal)
                .months.compactMap { $0 },
            [cal.shortMonthSymbols[6]]
        )
    }

    /// The two widths from the report, spelled out. Thirteen columns opens on
    /// May 5 and has room for all three names; twelve opens on May 12, where
    /// "May" covers three columns and yields its slot to the real June.
    func testLeadingPartialMonthYieldsToTheRealOne() {
        var cal = calendar()
        cal.firstWeekday = 2 // Monday
        let wide = ActivityWindow(weeks: 13, counts: [:], today: thursday, calendar: cal)
        XCTAssertEqual(wide.months[0], cal.shortMonthSymbols[4])   // May, col 0
        XCTAssertEqual(wide.months[4], cal.shortMonthSymbols[5])   // Jun, col 4
        XCTAssertEqual(wide.months[9], cal.shortMonthSymbols[6])   // Jul, col 9

        // Three columns of clearance is enough, so May keeps its name here.
        let narrow = ActivityWindow(weeks: 12, counts: [:], today: thursday, calendar: cal)
        XCTAssertEqual(narrow.months[0], cal.shortMonthSymbols[4]) // May, col 0
        XCTAssertEqual(narrow.months[3], cal.shortMonthSymbols[5]) // Jun, col 3
        XCTAssertEqual(narrow.months[8], cal.shortMonthSymbols[6]) // Jul, col 8

        // Two is not: the window opens May 19, and the leading label goes.
        let tight = ActivityWindow(weeks: 11, counts: [:], today: thursday, calendar: cal)
        XCTAssertNil(tight.months[0])
        XCTAssertEqual(tight.months[2], cal.shortMonthSymbols[5])  // Jun, col 2
        XCTAssertEqual(tight.months[7], cal.shortMonthSymbols[6])  // Jul, col 7
    }

    /// One name per column at most, and never more names than columns.
    func testMonthsIsOnePerColumn() {
        let window = ActivityWindow(weeks: 9, counts: [:], today: thursday, calendar: calendar())
        XCTAssertEqual(window.months.count, window.columns.count)
    }

    private func day(count: Int) -> ActivityWindow.Day {
        ActivityWindow.Day(
            key: 0, count: count, isFuture: false, isPrehistory: false, summary: ""
        )
    }
}
