import SwiftUI

// MARK: - Main View

struct IPadBidPeriodCalendarView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var selectedTripID: String?
    @Binding var selectedBidPeriodID: String?
    @Binding var isFriendsOverlayEnabled: Bool

    @State private var currentBidPeriod: CalendarBidPeriod? = nil
    @State private var headerBidPeriod: CalendarBidPeriod? = nil

    // BP date range labels (e.g. "May 17 – Jul 11, 2026") must render the BP's UTC calendar
    // dates verbatim. Without an explicit UTC timezone, the device's local timezone shifts the
    // formatter output (e.g. ANC at UTC-8 turns May 17 00:00 UTC into May 16 16:00 AKDT, so the
    // label would show "May 16"). Pinning to UTC keeps the label consistent with the BP grid.
    private static let dateRangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "MMM d"
        return f
    }()

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy"
        return f
    }()

    // MARK: Derived data

    private var allTrips: [CalendarTrip] {
        mergedCalendarTrips(crewAccess: viewModel.crewAccessSchedules, supplemental: viewModel.schedules)
    }

    private var domicile: String {
        viewModel.verifiedIdentity?.domicile ?? DomicileSupport.defaultDomicile
    }

    private var gridDays: [IPadCalendarGridDay] {
        guard let bp = currentBidPeriod else { return [] }
        return iPadCalendarGrid(for: bp, domicile: domicile)
    }

    /// Renders the active BP plus 2 BPs before and 2 BPs after, each as its own
    /// section. BP26-07 (4-week BP) renders only its real 4 weeks — no duplicate
    /// next-BP padding rows. Header tracking updates as the user scrolls between
    /// sections.
    private var displayedBidPeriodSections: [IPadBidPeriodGridSection] {
        guard let currentBidPeriod else { return [] }
        var collected: [CalendarBidPeriod] = []

        // 2 BPs before
        var cursor = currentBidPeriod
        var prevs: [CalendarBidPeriod] = []
        for _ in 0..<2 {
            guard let prev = bidPeriod(for: cursor.startDateUTC.addingTimeInterval(-1), domicile: domicile) else { break }
            prevs.append(prev)
            cursor = prev
        }
        collected.append(contentsOf: prevs.reversed())

        // Active
        collected.append(currentBidPeriod)

        // 2 BPs after
        cursor = currentBidPeriod
        for _ in 0..<2 {
            guard let next = bidPeriod(for: cursor.endDateUTC, domicile: domicile) else { break }
            collected.append(next)
            cursor = next
        }

        return collected.map { bp in
            IPadBidPeriodGridSection(bidPeriod: bp, rowRange: 0..<activeRowCount(for: bp))
        }
    }

    private func activeRowCount(for bidPeriod: CalendarBidPeriod) -> Int {
        max(1, min(8, Int(ceil(Double(bidPeriod.days.count) / 7.0))))
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headerView
            dowHeaderView
            // Row height is derived from the calendar viewport so that the active
            // 8-week BP fills the visible grid area without scrolling on iPad Pro
            // 11-inch landscape. ±2 BPs are reachable by scrolling.
            GeometryReader { geo in
                let rowHeight = max(72, geo.size.height / 8)
                gridScrollView(rowHeight: rowHeight)
            }
            .background(Color(.systemBackground))
        }
        .background(Color(.secondarySystemBackground).ignoresSafeArea(edges: .top))
        .onAppear { loadBidPeriod(for: Date()) }
        .onChange(of: viewModel.crewAccessSchedules) { _, _ in /* segments recomputed */ }
        .onChange(of: viewModel.schedules) { _, _ in /* segments recomputed */ }
        .onChange(of: currentBidPeriod) { _, bp in
            selectedBidPeriodID = bp?.id
            headerBidPeriod = bp
        }
    }

    // MARK: Header

    private var headerView: some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(activeHeaderBidPeriod?.id ?? "—")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                Text(bidPeriodRangeLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)

            Spacer()

            if hasFriendsForOverlay {
                Button {
                    isFriendsOverlayEnabled.toggle()
                } label: {
                    Label(
                        isFriendsOverlayEnabled ? "Friends On" : "Friends",
                        systemImage: isFriendsOverlayEnabled ? "person.2.fill" : "person.2"
                    )
                    .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .tint(isFriendsOverlayEnabled ? .accentColor : .secondary)
            }

            HStack(spacing: 6) {
                Button {
                    navigateToPreviousBP()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text(previousBPLabel)
                            .font(.system(size: 12, weight: .bold))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(currentBidPeriod == nil)

                Button("Today") {
                    loadBidPeriod(for: Date())
                }
                .buttonStyle(.borderedProminent)
                .font(.system(size: 12, weight: .medium))

                Button {
                    navigateToNextBP()
                } label: {
                    HStack(spacing: 4) {
                        Text(nextBPLabel)
                            .font(.system(size: 12, weight: .bold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(currentBidPeriod == nil)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: Day-of-Week Header

    private static let dowLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private var dowHeaderView: some View {
        HStack(spacing: 0) {
            ForEach(Self.dowLabels, id: \.self) { label in
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
        }
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Grid

    private func gridScrollView(rowHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Not LazyVStack: lazy stacks don't materialize views that are
                // off-screen, so scrollTo(bp.id) fails silently for BPs that
                // aren't yet in the rendered window. With at most 5 BP sections
                // (40 rows total) the performance cost of eager VStack is negligible.
                VStack(spacing: 0) {
                    Rectangle().fill(Color(.separator)).frame(height: 1)
                    ForEach(Array(displayedBidPeriodSections.enumerated()), id: \.element.id) { sectionIndex, section in
                        let bp = section.bidPeriod
                        let grid = iPadCalendarGrid(for: bp, domicile: domicile)
                        let days = grid.map(\.calendarDay)
                        let trips = visibleTrips(in: bp, trips: allTrips)
                        let segmentsByDayIndex = segmentsByDayIndex(for: trips, days: days)
                        let tripsByID = Dictionary(uniqueKeysWithValues: trips.map { ($0.id, $0) })
                        // Thick divider between BP sections (thicker than PP boundary).
                        if sectionIndex > 0 {
                            Rectangle()
                                .fill(Color(.separator))
                                .frame(height: 4)
                        }
                        // VStack (not lazy) guarantees this anchor is always
                        // materialized, so proxy.scrollTo(bp.id) reliably lands
                        // at the top of this BP section.
                        Color.clear.frame(height: 0).id(bp.id)
                        ForEach(Array(section.rowRange), id: \.self) { row in
                            rowView(
                                bidPeriod: bp,
                                gridDays: grid,
                                segmentsByDayIndex: segmentsByDayIndex,
                                tripsByID: tripsByID,
                                weekIndex: row,
                                rowHeight: rowHeight
                            )
                            .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: IPadVisibleBidPeriodPreferenceKey.self,
                                    value: [IPadVisibleBidPeriod(id: bp.id, minY: proxy.frame(in: .named("ipadCalendarScroll")).minY)]
                                )
                            }
                        )
                        if row < section.rowRange.upperBound - 1 {
                            let isPayPeriodBoundary = hasPayPeriodBoundary(after: row, in: grid)
                            Divider()
                                .frame(height: isPayPeriodBoundary ? 2 : 1)
                                .background(isPayPeriodBoundary ? Color(.separator) : Color.clear)
                        }
                    }
                    Rectangle().fill(Color(.separator)).frame(height: 1)
                }
            }
        }
            .coordinateSpace(name: "ipadCalendarScroll")
            .onPreferenceChange(IPadVisibleBidPeriodPreferenceKey.self) { values in
                guard let currentBidPeriod else { return }
                let visible = values
                    .filter { $0.minY <= 8 }
                    .max { $0.minY < $1.minY }
                    ?? values.min { abs($0.minY) < abs($1.minY) }
                if let visible,
                   let bp = displayedBidPeriodSections.map(\.bidPeriod).first(where: { $0.id == visible.id }),
                   headerBidPeriod?.id != bp.id {
                    headerBidPeriod = bp
                    selectedBidPeriodID = bp.id
                } else if values.isEmpty {
                    headerBidPeriod = currentBidPeriod
                }
            }
            // ±2 BPs are rendered in displayedBidPeriodSections, so the natural
            // scroll origin would land on the oldest BP. Anchor the initial view
            // and any current-BP changes to the active BP at top. Use a Task
            // with a small delay because LazyVStack may not have laid out the
            // anchor IDs by the time .onAppear fires (see TimelineTabView's
            // autoScrollToFocusDay for the same pattern).
            .task {
                guard let id = currentBidPeriod?.id else { return }
                for _ in 0..<3 {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    proxy.scrollTo(id, anchor: .top)
                }
            }
            .onChange(of: currentBidPeriod?.id) { _, newID in
                guard let newID else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newID, anchor: .top)
                    }
                }
            }
        }
    }

    private func segmentsByDayIndex(for trips: [CalendarTrip], days: [CalendarDay]) -> [Int: [CalendarSegment]] {
        guard !days.isEmpty else { return [:] }
        let allSegments = trips.flatMap { buildSegments(trip: $0, days: days) }
        let withLanes = assignLanes(to: allSegments)
        return Dictionary(grouping: withLanes, by: \.dayIndex)
    }

    private func rowView(
        bidPeriod _: CalendarBidPeriod,
        gridDays: [IPadCalendarGridDay],
        segmentsByDayIndex: [Int: [CalendarSegment]],
        tripsByID: [String: CalendarTrip],
        weekIndex: Int,
        rowHeight: CGFloat
    ) -> some View {
        let rowDays = (0..<7).compactMap { col -> IPadCalendarGridDay? in
            let absoluteIndex = weekIndex * 7 + col
            guard absoluteIndex < gridDays.count else { return nil }
            return gridDays[absoluteIndex]
        }
        let rowSegments = rowDays.flatMap { gridDay -> [CalendarSegment] in
            guard !gridDay.isOverflow else { return [] }
            return segmentsByDayIndex[gridDay.calendarDay.index] ?? []
        }
        let spans = rowTripSpans(from: rowSegments, gridDays: rowDays)

        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        if col < rowDays.count {
                            CalendarDayCell(gridDay: rowDays[col])
                                .frame(maxWidth: .infinity)
                            if col < 6 { Divider() }
                        }
                    }
                }

                let contentFrame = CGRect(
                    x: 0,
                    y: CalendarDayCell.metrics.dateHeaderHeight + CalendarDayCell.metrics.barTopPadding,
                    width: geo.size.width,
                    height: geo.size.height - CalendarDayCell.metrics.dateHeaderHeight - CalendarDayCell.metrics.barTopPadding
                )

                ForEach(spans) { span in
                    if let trip = tripsByID[span.tripID] {
                        let x = contentFrame.minX + span.startRowFraction * contentFrame.width
                        let width = max((span.endRowFraction - span.startRowFraction) * contentFrame.width, 1)
                        let y = contentFrame.minY + CGFloat(span.lane) * (CalendarDayCell.metrics.laneHeight + CalendarDayCell.metrics.laneSpacing)
                        IPadTripBarSpanView(
                            label: tripBarLabel(for: trip),
                            isSelected: selectedTripID == span.tripID,
                            regressedRanges: span.regressedRanges
                        ) {
                            selectedTripID = selectedTripID == span.tripID ? nil : span.tripID
                        }
                        .frame(width: width, height: CalendarDayCell.metrics.laneHeight)
                        .offset(x: x, y: y)
                    }
                }
            }
        }
        .frame(height: rowHeight)
    }

    private func hasPayPeriodBoundary(after row: Int, in gridDays: [IPadCalendarGridDay]) -> Bool {
        let lastIndex = row * 7 + 6
        let nextIndex = lastIndex + 1
        guard gridDays.indices.contains(lastIndex),
              gridDays.indices.contains(nextIndex) else {
            return false
        }
        let current = gridDays[lastIndex]
        let next = gridDays[nextIndex]
        guard current.isOverflow == next.isOverflow else {
            return false
        }
        return current.calendarDay.payPeriodIndex != next.calendarDay.payPeriodIndex
    }

    // MARK: Navigation helpers

    private var bidPeriodRangeLabel: String {
        guard let bp = activeHeaderBidPeriod else { return "" }
        // `startDateUTC` / `endDateUTC` are operational 03:00 ANC boundaries. The
        // header describes the visible 4/8-week calendar grid, so use the first
        // and last rendered UTC date cells instead of the exclusive boundary.
        let startDateUTC = bp.days.first?.dayStartUTC ?? bp.startDateUTC
        let endDateUTC = bp.days.last?.dayStartUTC ?? bp.endDateUTC
        let start = Self.dateRangeFormatter.string(from: startDateUTC)
        let end = Self.dateRangeFormatter.string(from: endDateUTC)
        let year = Self.yearFormatter.string(from: endDateUTC)
        return "\(start) – \(end), \(year)"
    }

    private var previousBPLabel: String {
        guard let bp = activeHeaderBidPeriod,
              let prev = bidPeriod(for: bp.startDateUTC.addingTimeInterval(-1), domicile: domicile) else {
            return "Prev"
        }
        return prev.id
    }

    private var nextBPLabel: String {
        guard let bp = activeHeaderBidPeriod,
              let next = bidPeriod(for: bp.endDateUTC, domicile: domicile) else {
            return "Next"
        }
        return next.id
    }

    private var hasFriendsForOverlay: Bool {
        viewModel.friendConnections.contains { $0.status == .accepted }
    }

    private func loadBidPeriod(for date: Date) {
        currentBidPeriod = bidPeriod(for: date, domicile: domicile)
        headerBidPeriod = currentBidPeriod
    }

    private func navigateToPreviousBP() {
        guard let bp = activeHeaderBidPeriod,
              let prev = bidPeriod(for: bp.startDateUTC.addingTimeInterval(-1), domicile: domicile) else { return }
        currentBidPeriod = prev
        headerBidPeriod = prev
    }

    private func navigateToNextBP() {
        guard let bp = activeHeaderBidPeriod,
              let next = bidPeriod(for: bp.endDateUTC, domicile: domicile) else { return }
        currentBidPeriod = next
        headerBidPeriod = next
    }

    private var activeHeaderBidPeriod: CalendarBidPeriod? {
        headerBidPeriod ?? currentBidPeriod
    }
}

private struct IPadVisibleBidPeriod: Equatable {
    let id: String
    let minY: CGFloat
}

private struct IPadBidPeriodGridSection: Identifiable {
    let bidPeriod: CalendarBidPeriod
    let rowRange: Range<Int>

    var id: String { bidPeriod.id }
}

private struct IPadVisibleBidPeriodPreferenceKey: PreferenceKey {
    static var defaultValue: [IPadVisibleBidPeriod] = []

    static func reduce(value: inout [IPadVisibleBidPeriod], nextValue: () -> [IPadVisibleBidPeriod]) {
        value.append(contentsOf: nextValue())
    }
}

private struct IPadRowTripSpan: Identifiable {
    let id: String
    let tripID: String
    let lane: Int
    let startRowFraction: Double
    let endRowFraction: Double
    let regressedRanges: [ClosedRange<Double>]
}

private func rowTripSpans(
    from rowSegments: [CalendarSegment],
    gridDays: [IPadCalendarGridDay]
) -> [IPadRowTripSpan] {
    let dayByIndex = Dictionary(uniqueKeysWithValues: gridDays.map { ($0.calendarDay.index, $0.calendarDay) })
    let sorted = rowSegments.sorted { lhs, rhs in
        if lhs.tripID != rhs.tripID { return lhs.tripID < rhs.tripID }
        if lhs.lane != rhs.lane { return lhs.lane < rhs.lane }
        if lhs.dayIndex != rhs.dayIndex { return lhs.dayIndex < rhs.dayIndex }
        return lhs.startFraction < rhs.startFraction
    }

    var spans: [IPadRowTripSpan] = []
    var current: (tripID: String, lane: Int, startDay: CalendarDay, endDay: CalendarDay, start: Double, end: Double, ranges: [ClosedRange<Double>])?

    func rowFraction(day: CalendarDay, fraction: Double) -> Double {
        (Double(day.weekdayIndex) + fraction) / 7
    }

    func appendCurrent() {
        guard let current else { return }
        let start = rowFraction(day: current.startDay, fraction: current.start)
        let end = rowFraction(day: current.endDay, fraction: current.end)
        guard end > start else { return }
        let normalizedRanges = current.ranges.compactMap { range -> ClosedRange<Double>? in
            let lower = (range.lowerBound - start) / (end - start)
            let upper = (range.upperBound - start) / (end - start)
            let clampedLower = min(max(lower, 0), 1)
            let clampedUpper = min(max(upper, 0), 1)
            guard clampedUpper > clampedLower else { return nil }
            return clampedLower...clampedUpper
        }
        spans.append(IPadRowTripSpan(
            id: "\(current.tripID)-\(current.lane)-\(current.startDay.index)-\(current.endDay.index)",
            tripID: current.tripID,
            lane: current.lane,
            startRowFraction: start,
            endRowFraction: end,
            regressedRanges: normalizedRanges
        ))
    }

    for segment in sorted {
        guard let day = dayByIndex[segment.dayIndex] else { continue }
        let segmentRanges: [ClosedRange<Double>] = segment.regressedRange.map {
            rowFraction(day: day, fraction: $0.lowerBound)...rowFraction(day: day, fraction: $0.upperBound)
        }.map { [$0] } ?? []

        if let existing = current,
           existing.tripID == segment.tripID,
           existing.lane == segment.lane,
           existing.endDay.index + 1 == day.index,
           abs(existing.end - 1) < 0.000001,
           abs(segment.startFraction) < 0.000001 {
            current = (
                existing.tripID,
                existing.lane,
                existing.startDay,
                day,
                existing.start,
                segment.endFraction,
                existing.ranges + segmentRanges
            )
        } else {
            appendCurrent()
            current = (
                segment.tripID,
                segment.lane,
                day,
                day,
                segment.startFraction,
                segment.endFraction,
                segmentRanges
            )
        }
    }

    appendCurrent()
    return spans.sorted { lhs, rhs in
        if lhs.lane != rhs.lane { return lhs.lane < rhs.lane }
        if lhs.startRowFraction != rhs.startRowFraction { return lhs.startRowFraction < rhs.startRowFraction }
        return lhs.tripID < rhs.tripID
    }
}

// MARK: - Day Cell

private struct CalendarDayCell: View {
    let gridDay: IPadCalendarGridDay

    struct Metrics {
        let dateHeaderHeight: CGFloat = 28
        let laneHeight: CGFloat = 14
        let laneSpacing: CGFloat = 1
        let barTopPadding: CGFloat = 2
    }

    static let metrics = Metrics()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "d"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "MMM"
        return f
    }()

    private var dayDate: Date { gridDay.calendarDay.dayStartUTC }
    private var isToday: Bool {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return utc.isDateInToday(dayDate)
    }
    private var isSunday: Bool { gridDay.calendarDay.weekdayIndex == 0 }
    private var isSaturday: Bool { gridDay.calendarDay.weekdayIndex == 6 }
    private var isFirstOfMonth: Bool {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return utc.component(.day, from: dayDate) == 1
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            cellBackground

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Group {
                    if isToday {
                        Text(Self.dayFormatter.string(from: dayDate))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.accentColor))
                    } else {
                        Text(Self.dayFormatter.string(from: dayDate))
                            .font(.system(size: 16, weight: gridDay.isOverflow ? .light : .semibold))
                            .foregroundStyle(gridDay.isOverflow ? .tertiary : .primary)
                            .frame(width: 26, height: 26)
                    }
                }
                if isFirstOfMonth || gridDay.calendarDay.index == 0 {
                    Text(Self.monthFormatter.string(from: dayDate))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 5)
            .padding(.top, 3)
        }
        .opacity(gridDay.isOverflow ? 0.35 : 1)
    }

    @ViewBuilder
    private var cellBackground: some View {
        if isSunday {
            Color.red.opacity(0.10)
        } else if isSaturday {
            Color.blue.opacity(0.08)
        } else {
            Color.clear
        }
    }
}

#Preview {
    IPadBidPeriodCalendarView(
        selectedTripID: .constant(nil),
        selectedBidPeriodID: .constant(nil),
        isFriendsOverlayEnabled: .constant(false)
    )
    .environmentObject(AppViewModel.shared)
    .frame(height: 600)
}
