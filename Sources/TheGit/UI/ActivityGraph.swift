import SwiftUI

/// GitHub's contribution grid: a column per week, a cell per day, brighter
/// the more commits landed that day. The sidebar draws one repository's
/// (half a year of it, in 200–360pt), the Dashboard draws every open
/// repository's summed together (a year of it, across the window).
///
/// Three things differ from GitHub's, all because this has to survive being
/// a narrow panel and not just a 900pt profile page:
///
/// - **The grid is sized from the width it's offered, never from its own
///   content.** That's what the outer GeometryReader is for. Measuring the
///   content instead (a GeometryReader in `.background`) latches: cells
///   fitted for a wide sidebar overflow a narrow one, the overflowed width
///   is what gets measured, and the grid never shrinks back — it just hangs
///   off both edges of the pane.
/// - **The window is as long as the space can hold, capped at `maxWeeks`.**
///   Not as long as the repo: a grid sized to each repo's own history makes
///   a young one a stub beside its neighbours, and six columns where the
///   panel has room for twelve reads as a grid that got cut off. The cap is
///   what the surface can spare the ink for — 52 columns in a sidebar is
///   2pt a week. A young repo therefore opens on empty cells, and the
///   caption (see `ActivityWindow.summary`) is what says how much of the
///   window the repo has actually been alive for.
/// - **The shading is relative to how busy this repo actually is** (see
///   `ActivityWindow.Day.level`). Fixed thresholds looked right on a solo
///   repo and collapsed on a shared one — at 4000 commits a quarter every
///   cell pinned to the darkest step and the grid stopped saying anything.
struct ActivityGraph: View {
    /// Commits per day, keyed as `ActivityDay.key`.
    let counts: [Int: Int]

    /// The most columns to draw. Must stay inside the window `counts` was
    /// read over — the grid must never draw a column the histogram doesn't
    /// cover, or missing data would render as a quiet week. The default
    /// pairs with `ActivityDay.windowWeeks`, the Dashboard's 52 with
    /// `ActivityDay.yearWeeks`.
    var maxWeeks: Int = 26

    /// Extra tooltip line per day, keyed as `ActivityDay.key` — the
    /// Dashboard's grid names the repositories behind a day's count, which
    /// is the one thing a summed grid can't say in colour.
    ///
    /// A table rather than a closure because `.help` is built for every one
    /// of the grid's ~360 cells on every pass through `body`.
    var detail: [Int: String] = [:]

    /// Overrides the line under the grid. The default (`nil`) is the
    /// window's own summary, which is the right one for a single repo:
    /// commits, and how much of the window that repo has existed for. A
    /// summed grid has no such span — the oldest of a dozen repos always
    /// outruns the window — so the Dashboard passes its own, or `""` when it
    /// states the total beside the grid instead and leaves this row to the
    /// legend.
    var caption: String?

    /// The scale key, at the trailing end of the caption row.
    ///
    /// Off in the sidebar, and not because the key is useless: at 300pt it
    /// was taking a third of the only line the block has to say anything on,
    /// to make a point ("darker is more") that four steps of one hue already
    /// make. In a Dashboard-width block that line is mostly empty, so the
    /// trade goes the other way — and the stat column next to it names the
    /// busiest day, which is the number the relative ramp can't put on the
    /// key itself.
    var showsLegend = false

    /// Cell edge in points, before zoom.
    ///
    /// An input rather than a constant, because the two callers have
    /// opposite problems: the sidebar has less width than a year needs and
    /// drops columns to fit, while the Dashboard has more width than 52
    /// columns can spend and grows its squares instead — see
    /// `cellSize(fitting:in:)`. Either way it's the caller's number, since
    /// the block's height has to be known before its width is (see
    /// `height`).
    var cellSize: CGFloat = 11

    @Environment(\.uiZoom) private var zoom
    @Environment(\.colorScheme) private var scheme

    /// The gap and the weekday column don't move with the cell: a lattice
    /// with a horizontal gap that absorbs slack and a vertical one that
    /// doesn't isn't a lattice, and "Mon" at 9pt is 20pt wide however big
    /// the squares next to it are.
    private static let gapPoints: CGFloat = 2
    private static let labelPoints: CGFloat = 20

    private var cell: CGFloat { cellSize * zoom }
    private var gap: CGFloat { Self.gapPoints * zoom }
    private var labelWidth: CGFloat { Self.labelPoints * zoom }

    /// What a `weeks`-column block measures at a given cell size, in points
    /// before zoom. Everything in it that isn't a cell: the weekday column,
    /// the gap after it, and one between each pair of columns.
    static func blockWidth(weeks: Int, cellSize: CGFloat) -> CGFloat {
        labelPoints + (gapPoints + cellSize) * CGFloat(weeks)
    }

    /// The inverse: the cell size at which `weeks` columns exactly fill
    /// `width`. Both in points before zoom, and the answer clamped by the
    /// caller to a range it's willing to draw.
    ///
    /// Only the caller knows how much of its width the grid is meant to
    /// have, which is why this is arithmetic it can run rather than
    /// something the block does to itself.
    static func cellSize(fitting weeks: Int, in width: CGFloat) -> CGFloat {
        guard weeks > 0 else { return 0 }
        return (width - (labelPoints + gapPoints * CGFloat(weeks))) / CGFloat(weeks)
    }
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
        return max(1, min(maxWeeks, fits))
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
                footer(caption ?? window.summary, width: blockWidth(columns))
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
            // Never the empty caption: a caller that keeps its total in a
            // stat column has still left VoiceOver with nothing to say about
            // the grid, and the window's own summary is that.
            .accessibilityValue(caption?.isEmpty == false ? caption! : window.summary)
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
            .help(day.isOffRecord ? "" : tooltip(day))
    }

    /// The day's count and date, plus whatever the caller can add about it.
    private func tooltip(_ day: ActivityWindow.Day) -> String {
        guard let extra = detail[day.key], day.count > 0 else { return day.summary }
        return "\(day.summary) · \(extra)"
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

    /// The line under the block: what the grid says about itself at one end,
    /// the scale key at the other — see `caption` and `showsLegend` for who
    /// decides whether either is there.
    ///
    /// Text never truncated: a clipped "87 commits" reads as a smaller
    /// number, so it keeps its intrinsic width and overhangs a panel too
    /// narrow for it rather than losing a digit. With no key beside it the
    /// line is the only thing on its row, and it centres — ranged left under
    /// a centred grid it hangs off one corner.
    @ViewBuilder
    private func footer(_ text: String, width: CGFloat) -> some View {
        // The key has a hard minimum width — two words and five squares, none
        // of which can shrink — so a block narrower than that drops it rather
        // than hanging it off the edge of the panel it's explaining.
        let keyFits = showsLegend && width >= 130 * zoom
        HStack(spacing: 6 * zoom) {
            if !text.isEmpty {
                Text(text)
                    .zoomFont(10)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if keyFits {
                Spacer(minLength: 0)
                legend
            }
        }
        .frame(width: width, height: captionRow, alignment: keyFits ? .leading : .center)
    }

    /// Five swatches: the empty tint and the four steps above it, so the
    /// colour a quiet day gets is named too rather than left looking like a
    /// hole in the lattice. Cells at grid size, so the key reads as a row
    /// lifted out of the grid it explains.
    @ViewBuilder
    private var legend: some View {
        HStack(spacing: 3 * zoom) {
            Text("Less").zoomFont(9).foregroundStyle(.tertiary).fixedSize()
            ForEach(0..<5, id: \.self) { step in
                RoundedRectangle(cornerRadius: 2.5 * zoom, style: .continuous)
                    .fill(step == 0 ? Color.primary.opacity(0.09) : Self.ramp(scheme)[step - 1])
                    .frame(width: cell, height: cell)
            }
            Text("More").zoomFont(9).foregroundStyle(.tertiary).fixedSize()
        }
        // One element: five unlabelled swatches are five stops nobody wants
        // to swipe through, and what they mean is one sentence.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scale: lighter is fewer commits, darker is more")
    }
}

/// One repository's year as an area under a line, a point per week.
///
/// The shape, not the size: every line is scaled to its own busiest week, so
/// a quiet repo still shows when it was busy rather than flattening into the
/// floor beside a loud one. What it costs is comparability between rows,
/// which is why the row it sits in states the repo's total in figures.
///
/// It stretches to whatever width it's given, which is the point of it being
/// a line and not the grid: the summed heatmap is 52 columns wide at any
/// window size, and this is what can actually use a wide one.
struct ActivitySparkline: View {
    /// Commits per week, oldest first — see `ActivityStats.weeklyTotals`.
    let values: [Int]
    let tint: Color

    @Environment(\.uiZoom) private var zoom

    var body: some View {
        GeometryReader { geo in
            let peak = CGFloat(max(1, values.max() ?? 1))
            let width = geo.size.width
            let height = geo.size.height
            // The last point sits on the trailing edge, so the line spans the
            // row rather than stopping a step short of it.
            let step = values.count > 1 ? width / CGFloat(values.count - 1) : width
            let point = { (index: Int) in
                CGPoint(
                    x: CGFloat(index) * step,
                    y: height - height * CGFloat(values[index]) / peak
                )
            }
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    for index in values.indices { path.addLine(to: point(index)) }
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.closeSubpath()
                }
                .fill(tint.opacity(0.28))
                Path { path in
                    for index in values.indices {
                        index == 0 ? path.move(to: point(index)) : path.addLine(to: point(index))
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.2 * zoom, lineJoin: .round))
            }
        }
        // A shape, not a control: the row around it says whose year it is and
        // how many commits are in it, and a line has nothing to add to that.
        .accessibilityHidden(true)
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

/// The four things the Dashboard says beside its grid, none of which a
/// shaded cell can: how much work there was, on how many days, whether it's
/// still going, and how big a day gets.
///
/// Measured over a fixed window rather than over the columns actually drawn.
/// The grid's own caption reports what's on screen — it sits *under* the
/// cells, so it has to — but these sit beside them as a headline, and a
/// headline number that drops every time the window is narrowed by a column
/// is a number nobody can quote.
struct ActivityStats {
    let total: Int
    /// Days with at least one commit. The counterweight to the total: 300
    /// commits is a different year on 40 days than on 200.
    let activeDays: Int
    /// Days in a row with work, counting back from today.
    ///
    /// Today is allowed to be empty and still continue the streak — it isn't
    /// over yet — so a streak ends the morning after the last commit rather
    /// than at midnight, which is when the app would otherwise announce that
    /// a habit of eleven days had just been broken.
    let streak: Int
    /// The busiest single day, and its short date. The one number the ramp
    /// can't show anywhere: the steps are relative (see
    /// `ActivityWindow.Day.level`), so "More" has no value attached to it on
    /// the key or beside it.
    let busiest: (count: Int, label: String)?

    /// 52 weeks — the year the Dashboard's grid draws.
    static let windowDays = 364

    /// The window's days, newest first.
    ///
    /// Handed out because several histograms have to be summed over exactly
    /// the same days: the headline total and the per-repo breakdown beside it
    /// are the same year seen two ways, and they have to add up. Building the
    /// list once also keeps a wall of nine repos to one walk of the calendar
    /// instead of nine.
    static func windowKeys(
        days: Int = ActivityStats.windowDays,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [Int] {
        let start = calendar.startOfDay(for: today)
        var keys: [Int] = []
        keys.reserveCapacity(max(0, days))
        for offset in 0..<max(0, days) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: start) else { break }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            keys.append(ActivityDay.key(
                year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1
            ))
        }
        return keys
    }

    /// One histogram's commits over the given days, and nothing outside them:
    /// the histograms run a week wider than the window (see
    /// `ActivityDay.yearWeeks`), so a plain sum of one would quietly exceed
    /// the headline it's meant to break down.
    static func total(of counts: [Int: Int], over keys: [Int]) -> Int {
        keys.reduce(0) { $0 + (counts[$1] ?? 0) }
    }

    /// The same window in seven-day buckets, oldest first — 52 of them for a
    /// year, which is a sparkline's worth of points and the same resolution
    /// the grid's columns have.
    ///
    /// Binned by days-ago rather than by calendar week, so the last bucket is
    /// "the last seven days" and not "this week so far". A calendar-week
    /// version would agree with the grid's columns to the day, which would
    /// matter if the line sat under them — it sits in the tile next door, at
    /// 17pt tall, where a phase shift of a few days is not a visible fact.
    ///
    /// `keys` runs newest first (see `windowKeys`), so the arithmetic here is
    /// what turns "days ago" back into left-to-right time.
    static func weeklyTotals(of counts: [Int: Int], over keys: [Int]) -> [Int] {
        guard !keys.isEmpty else { return [] }
        let buckets = (keys.count + 6) / 7
        var weeks = [Int](repeating: 0, count: buckets)
        for (offset, key) in keys.enumerated() {
            guard let commits = counts[key] else { continue }
            weeks[buckets - 1 - offset / 7] += commits
        }
        return weeks
    }

    init(
        counts: [Int: Int],
        days: Int = ActivityStats.windowDays,
        today: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.init(
            counts: counts,
            keys: Self.windowKeys(days: days, today: today, calendar: calendar),
            calendar: calendar
        )
    }

    /// The same, over a window someone else has already walked.
    init(counts: [Int: Int], keys: [Int], calendar: Calendar = .current) {
        let shortMonths = calendar.shortMonthSymbols
        var total = 0
        var activeDays = 0
        var streak = 0
        var streakOpen = true
        var busiest: (count: Int, label: String)?
        for (offset, key) in keys.enumerated() {
            // The day is in the key — 20260729 is the 29th of month 7 — so
            // the calendar doesn't have to be asked twice for what it has
            // already been asked once.
            let month = (key / 100) % 100
            let day = key % 100
            let count = counts[key] ?? 0
            if count > 0 {
                total += count
                activeDays += 1
                if streakOpen { streak += 1 }
                // Strictly greater, walking backwards from today, so a tie
                // reports the most recent of the two — the older one is the
                // less interesting answer to "how big does a day get".
                if count > (busiest?.count ?? 0), (1...12).contains(month) {
                    busiest = (count, "\(shortMonths[month - 1]) \(day)")
                }
            } else if offset > 0 {
                streakOpen = false
            }
        }
        self.total = total
        self.activeDays = activeDays
        self.streak = streak
        self.busiest = busiest
    }
}
