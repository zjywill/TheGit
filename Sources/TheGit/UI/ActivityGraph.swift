import SwiftUI

/// GitHub's contribution grid, scoped to one repository: a column per week,
/// a cell per day, brighter the more commits landed that day.
///
/// Three things differ from GitHub's, all because this is a 200–360pt panel
/// and not a 900pt profile page:
///
/// - **The grid is sized from the width it's offered, never from its own
///   content.** That's what the outer GeometryReader is for. Measuring the
///   content instead (a GeometryReader in `.background`) latches: cells
///   fitted for a wide sidebar overflow a narrow one, the overflowed width
///   is what gets measured, and the grid never shrinks back — it just hangs
///   off both edges of the pane.
/// - **The window is as long as the panel can hold, capped at half a year.**
///   Not as long as the repo: a grid sized to each repo's own history makes
///   a young one a stub beside its neighbours, and six columns where the
///   panel has room for twelve reads as a grid that got cut off. The cap is
///   what the sidebar can spare the ink for — 52 columns down here is 2pt a
///   week. A young repo therefore opens on empty cells, and the caption
///   (see `ActivityWindow.summary`) is what says how much of the window the
///   repo has actually been alive for.
/// - **The shading is relative to how busy this repo actually is** (see
///   `ActivityWindow.Day.level`). Fixed thresholds looked right on a solo
///   repo and collapsed on a shared one — at 4000 commits a quarter every
///   cell pinned to the darkest step and the grid stopped saying anything.
struct ActivityGraph: View {
    /// Commits per day, keyed as `ActivityDay.key`.
    let counts: [Int: Int]

    @Environment(\.uiZoom) private var zoom
    @Environment(\.colorScheme) private var scheme

    /// Half a year, and one week inside what `ActivityDay.windowWeeks`
    /// reads — the grid must never draw a column the histogram doesn't
    /// cover, or missing data would render as a quiet week.
    private static let maxWeeks = 26

    /// Fixed, all three of them: the block's height must be declared up
    /// front (see `height`), and a lattice with a horizontal gap that
    /// absorbs slack and a vertical one that doesn't isn't a lattice.
    private var cell: CGFloat { 11 * zoom }
    private var gap: CGFloat { 2 * zoom }
    /// The weekday column: "Mon" at 9pt, trailing-aligned against the grid.
    private var labelWidth: CGFloat { 20 * zoom }
    /// Between the grid and each of its two label lines. Larger than the
    /// grid's own gap, so the three bands read as three bands.
    private var band: CGFloat { 4 * zoom }
    private var monthRow: CGFloat { 12 * zoom }
    private var captionRow: CGFloat { 14 * zoom }

    /// Declared rather than measured — the GeometryReader below has no
    /// intrinsic size of its own, so this is the one number that has to
    /// agree with the stack inside it.
    private var height: CGFloat {
        monthRow + band + (7 * cell + 6 * gap) + band + captionRow
    }

    /// As many columns as the panel can hold, and no fewer for a young repo
    /// than for an old one: two repos side by side in the same sidebar draw
    /// the same grid, and the difference between them is what's *in* it.
    /// Sizing the window to each repo's own history instead made the young
    /// one a stub — the same panel, the same cells, an unexplained six
    /// columns where its neighbour has twelve, which reads as a truncated
    /// grid rather than a short history.
    ///
    /// Floored at one rather than at a handful of weeks: the floor exists so
    /// a vanishing panel doesn't ask for zero columns, and a floor higher
    /// than `fits` would push the grid off the edge it was measured against.
    private func columns(for width: CGFloat) -> Int {
        let available = width - labelWidth - gap
        let fits = Int((available + gap) / (cell + gap))
        return max(1, min(Self.maxWeeks, fits))
    }

    private func blockWidth(_ columns: Int) -> CGFloat {
        labelWidth + gap + CGFloat(columns) * cell + CGFloat(columns - 1) * gap
    }

    var body: some View {
        GeometryReader { geo in
            let columns = columns(for: geo.size.width)
            let window = ActivityWindow(weeks: columns, counts: counts)
            VStack(alignment: .leading, spacing: band) {
                months(window)
                HStack(alignment: .top, spacing: gap) {
                    weekdays(window)
                    ForEach(Array(window.columns.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: gap) {
                            ForEach(week) { day in
                                square(day, peak: window.peak)
                            }
                        }
                    }
                }
                caption(window, width: blockWidth(columns))
            }
            // One width for all three bands, so the month names, the cells
            // and the scale key line up on the same two edges — and the
            // whole block centres in the panel as a unit. Leftover is at
            // most one column, split evenly, rather than left as a hole at
            // the trailing edge.
            .frame(width: blockWidth(columns))
            .frame(maxWidth: .infinity, alignment: .center)
            // One element, not 180 unlabelled cells to swipe through — and
            // inside the reader, so the spoken total is the one on screen.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Commit activity")
            .accessibilityValue(window.summary)
        }
        .frame(height: height)
    }

    /// Month names over the column each month opens in. A label is dropped
    /// when it would sit within three columns of the one before it: at these
    /// cell sizes "Feb" is wider than its own column, and a name overhanging
    /// the next name says less than one name alone.
    @ViewBuilder
    private func months(_ window: ActivityWindow) -> some View {
        HStack(alignment: .bottom, spacing: gap) {
            Spacer().frame(width: labelWidth)
            ForEach(Array(window.months.enumerated()), id: \.offset) { _, name in
                // The name can't be laid out in the flow — it's wider than
                // the column it belongs to, and it would push every later
                // column out of line with its own cells. It hangs off a
                // cell-wide marker instead.
                Color.clear
                    .frame(width: cell, height: monthRow)
                    .overlay(alignment: .leading) {
                        if let name {
                            Text(name)
                                .zoomFont(9, weight: .medium)
                                // Small type wants a little positive
                                // tracking; the same 9pt at 0 reads cramped.
                                .tracking(0.2)
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                        }
                    }
            }
        }
    }

    /// Every other weekday, GitHub-style. Seven stacked 9pt labels is a wall
    /// of text beside the thing it's labelling, and the row a cell sits in
    /// is legible from one anchor in three.
    @ViewBuilder
    private func weekdays(_ window: ActivityWindow) -> some View {
        VStack(spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(row % 2 == 1 ? window.weekdayNames[row] : "")
                    .zoomFont(9)
                    .tracking(0.2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: labelWidth, height: cell, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func square(_ day: ActivityWindow.Day, peak: Int) -> some View {
        RoundedRectangle(cornerRadius: 2.5 * zoom, style: .continuous)
            .fill(fill(day, peak: peak))
            .frame(width: cell, height: cell)
            // No tooltip on a day outside the repo's life — there's no fact
            // about it to report.
            .help(day.isOffRecord ? "" : day.summary)
    }

    /// Empty days are a visible tint, not nothing: the grid is read as a
    /// lattice, and cells that vanish into the panel leave the green ones
    /// floating in space with no rows or columns to sit on. Days that
    /// haven't happened get half of that tint — the rectangle stays whole
    /// while the trailing week still reads as unfinished rather than idle.
    private func fill(_ day: ActivityWindow.Day, peak: Int) -> Color {
        if day.isFuture { return Color.primary.opacity(0.04) }
        let level = day.level(peak: peak)
        guard level > 0 else { return Color.primary.opacity(0.09) }
        return Self.ramp(scheme)[level - 1]
    }

    /// Four steps up one hue, evenly spaced in OKLCH lightness — the same
    /// construction as the graph's lane palette, at the lane green's hue
    /// (150°) so the two surfaces read as one family.
    ///
    /// The two ramps are not each other's inverse. On a dark panel the steps
    /// climb (L 0.36 → 0.76) and on a light one they descend (0.89 → 0.53);
    /// either ramp on the wrong background loses its first two steps into
    /// the surface behind it. Chroma runs at 60–72% of each step's sRGB
    /// maximum, held back at the pale end where full chroma turns mint.
    static func ramp(_ scheme: ColorScheme) -> [Color] {
        scheme == .dark
            ? [
                Color(red: 0.143, green: 0.274, blue: 0.173),  // L 0.36
                Color(red: 0.216, green: 0.447, blue: 0.274),  // L 0.50
                Color(red: 0.287, green: 0.619, blue: 0.374),  // L 0.63
                Color(red: 0.377, green: 0.797, blue: 0.487),  // L 0.76
            ]
            : [
                Color(red: 0.701, green: 0.923, blue: 0.742),  // L 0.89
                Color(red: 0.484, green: 0.821, blue: 0.560),  // L 0.79
                Color(red: 0.318, green: 0.658, blue: 0.405),  // L 0.66
                Color(red: 0.220, green: 0.488, blue: 0.290),  // L 0.53
            ]
    }

    /// The total, and nothing else, centred under the block.
    ///
    /// No scale key. All four swatches could ever say is "darker is more",
    /// which four steps of one hue say on their own, and the number a step
    /// actually stands for isn't on the key either — the steps are relative
    /// to the repo, so that number lives in the per-day tooltips and nowhere
    /// a legend could put it. It was spending a third of the line to
    /// restate the obvious.
    ///
    /// Centred rather than ranged left, because with the key gone the line
    /// is the only thing on its row: left-aligned under a centred grid it
    /// hangs off one corner. Never truncated — a clipped "87 commits" reads
    /// as a smaller number — so it keeps its intrinsic width and overhangs a
    /// panel too narrow for it rather than losing a digit.
    @ViewBuilder
    private func caption(_ window: ActivityWindow, width: CGFloat) -> some View {
        Text(window.summary)
            .zoomFont(10)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
            .frame(width: width, height: captionRow, alignment: .center)
    }
}

/// The grid's days, and the labels that go around them.
struct ActivityWindow {
    struct Day: Identifiable {
        let key: Int
        let count: Int
        let isFuture: Bool
        /// Before the repo's first commit. Only ever true when the grid's
        /// floor is holding columns open that the repo is too young to
        /// fill — a repo older than the window has no prehistory in view.
        let isPrehistory: Bool
        let summary: String

        var id: Int { key }

        /// The two ends of the same fact: the repo wasn't there. Emptiness
        /// on a recorded day is a fact about the repo and shades like one;
        /// emptiness on either side of its life is a fact about the
        /// calendar, and the grid should stop claiming otherwise.
        var isOffRecord: Bool { isFuture || isPrehistory }

        /// Quartiles of `peak`, GitHub's own scheme — but with a peak that
        /// is the 90th percentile of the repo's *active* days rather than
        /// its busiest single day. Both alternatives fail on real repos: an
        /// absolute scale pins a shared repo to one colour, and the plain
        /// maximum lets one 300-commit merge day flatten every other day to
        /// step 1. Any day with work in it is at least step 1 — "something
        /// happened here" is the distinction that matters most.
        func level(peak: Int) -> Int {
            guard count > 0 else { return 0 }
            return min(4, max(1, Int(ceil(Double(count) * 4 / Double(max(1, peak))))))
        }
    }

    /// Oldest week first, each column running top-to-bottom by weekday.
    let columns: [[Day]]
    /// One entry per column: the month it opens, or nil.
    let months: [String?]
    let weekdayNames: [String]
    /// The count that maps to the darkest step — see `Day.level`.
    let peak: Int
    let summary: String

    /// Whole weeks from the repo's oldest recorded day to today, which is
    /// the longest window worth drawing: a grid may be shorter than the
    /// panel, but it must never be longer than the repo.
    static func weeksOfHistory(
        counts: [Int: Int],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        guard let oldest = counts.filter({ $0.value > 0 }).keys.min() else { return 0 }
        var parts = DateComponents()
        parts.year = oldest / 10_000
        parts.month = (oldest / 100) % 100
        parts.day = oldest % 100
        guard let from = calendar.date(from: parts) else { return 0 }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: today)
        ).day ?? 0
        return max(1, Int(ceil(Double(days + 1) / 7)))
    }

    /// Columns of clearance a month name needs before the next one. At the
    /// grid's cell size a name is about twice the width of the column it
    /// belongs to, so three columns leaves it a comfortable margin and two
    /// would have "Jun" and "Jul" touching in the locales with the widest
    /// abbreviations.
    private static let labelGap = 3

    /// Which columns get a month name.
    ///
    /// Real month starts are never a problem: the shortest month is 28 days,
    /// so consecutive first-of-the-months always land four or five columns
    /// apart and always both fit. Every crowded pair involves the *first*
    /// column, which is recorded as an opening whatever week of the month it
    /// lands in — a window starting May 11 labels "May" over three columns of
    /// a month that's nearly over.
    ///
    /// That borrowed label used to win, and the genuine month start behind it
    /// was dropped. Worse, which one you got depended on the panel width: the
    /// grid's right edge is pinned to this week, so every column the splitter
    /// takes away slides the window a week later and shifts every month one
    /// column left. At thirteen columns June opened at column 4 and was
    /// labelled; at twelve it opened at column 3 and vanished. Same repo,
    /// same month, one drag of the splitter.
    ///
    /// So the real month start is the one that stays, and the leading label
    /// yields to it. Since the gap only ever closes at the leading edge,
    /// dropping that one entry is enough — nothing behind it can cascade.
    static func label(_ openings: [(column: Int, name: String)], weeks: Int) -> [String?] {
        var openings = openings
        if openings.count > 1, openings[0].column == 0,
           openings[1].column - openings[0].column < labelGap {
            openings.removeFirst()
        }
        var months = [String?](repeating: nil, count: weeks)
        var lastLabelled = -labelGap
        for opening in openings where opening.column - lastLabelled >= labelGap {
            months[opening.column] = opening.name
            lastLabelled = opening.column
        }
        return months
    }

    init(
        weeks: Int,
        counts: [Int: Int],
        today: Date = Date(),
        calendar: Calendar = .current
    ) {
        let start = calendar.startOfDay(for: today)
        // The last column is the current, part-finished week, so the grid
        // runs left-to-now the way a calendar does.
        let intoWeek = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let first = calendar.date(
            byAdding: .day, value: -(intoWeek + 7 * (weeks - 1)), to: start
        ) ?? start
        let shortMonths = calendar.shortMonthSymbols
        // The repo's own beginning, which is the boundary the padded columns
        // sit before. Nil for a repo with nothing recorded at all: there is
        // no first commit to be earlier than, and an all-outline grid would
        // say "this repo doesn't exist" where the caption already says the
        // true and narrower thing.
        let born = counts.filter { $0.value > 0 }.keys.min()

        var columns: [[Day]] = []
        var openings: [(column: Int, name: String)] = []
        var active: [Int] = []
        var total = 0
        var previousMonth = 0
        for column in 0..<weeks {
            var days: [Day] = []
            for row in 0..<7 {
                let date = calendar.date(byAdding: .day, value: column * 7 + row, to: first) ?? first
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                let month = parts.month ?? 1
                let day = parts.day ?? 1
                let key = ActivityDay.key(year: parts.year ?? 0, month: month, day: day)
                let count = counts[key] ?? 0
                total += count
                if count > 0 { active.append(count) }
                days.append(Day(
                    key: key,
                    count: count,
                    isFuture: date > start,
                    isPrehistory: born.map { key < $0 } ?? false,
                    summary: "\(count) commit\(count == 1 ? "" : "s") · \(shortMonths[month - 1]) \(day)"
                ))
                // A month opens in the column its first row falls in. The
                // first column always counts as an opening, whatever week of
                // the month it lands in — which the pass below is what
                // accounts for.
                if row == 0 {
                    if month != previousMonth {
                        openings.append((column, shortMonths[month - 1]))
                    }
                    previousMonth = month
                }
            }
            columns.append(days)
        }

        self.columns = columns
        self.months = Self.label(openings, weeks: weeks)
        // Rotated to the locale's own first weekday, so the row a label
        // names is the row it actually sits on in every region.
        self.weekdayNames = (0..<7).map { row in
            calendar.shortWeekdaySymbols[(calendar.firstWeekday - 1 + row) % 7]
        }
        active.sort()
        // Floored at four, so the scale always spans a real day's work. A
        // repo whose 90th percentile is one commit a day would otherwise
        // put every active cell on the darkest step and shout about a habit
        // of one commit a day.
        self.peak = max(4, active.isEmpty
            ? 1
            : active[min(active.count - 1, Int(Double(active.count) * 0.9))])
        // Weeks the repo has been alive for, never the number of columns
        // drawn: the floor pads a two-week-old repo out to six, and a caption
        // reading "6 weeks" over four columns of prehistory is the same lie
        // the grey cells used to tell, in words. Clamped by the window too,
        // so a long-lived repo in a narrow panel still reports what's on
        // screen rather than its whole life.
        let span = max(1, min(weeks, Self.weeksOfHistory(
            counts: counts, today: today, calendar: calendar
        )))
        self.summary = total == 0
            ? "No commits in \(weeks) weeks"
            : "\(total.formatted()) commit\(total == 1 ? "" : "s") · "
                + "\(span) week\(span == 1 ? "" : "s")"
    }
}
