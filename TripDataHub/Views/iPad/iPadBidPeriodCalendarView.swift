import SwiftUI

// MARK: - Main View

struct IPadBidPeriodCalendarView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var selectedTripID: String?
    @Binding var selectedBidPeriodID: String?
    @AppStorage("pilot_qualification") private var pilotQualificationRawValue = PilotQualification.captain.rawValue
    @AppStorage("bid_transition_timeline_enabled") private var bidTransitionTimelineEnabled = true
    @AppStorage("faa_medical_expiry_date") private var faaMedicalExpiryDate = ""
    @AppStorage("passport_expiry_date") private var passportExpiryDate = ""
    @AppStorage("china_visa_expiry_date") private var chinaVisaExpiryDate = ""

    @State private var currentBidPeriod: CalendarBidPeriod? = nil
    @State private var headerBidPeriod: CalendarBidPeriod? = nil
    @State private var scrollTrigger = UUID()
    // Layout cache: keyed by BP.id. Populated by refreshCalendarLayouts().
    // selectedTripID changes do NOT invalidate the cache.
    @State private var bpLayoutCache: [String: CalendarBPLayout] = [:]
    @State private var cachedAllTrips: [CalendarTrip] = []
    @State private var dayLayerCache: [String: IPadCalendarDayLayerData] = [:]

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

    // allTrips is cached in cachedAllTrips via refreshCalendarLayouts().
    // Kept as a private helper only for on-demand fallback in the body.
    private var allTrips: [CalendarTrip] { cachedAllTrips }

    private var domicile: String {
        viewModel.verifiedIdentity?.domicile ?? DomicileSupport.defaultDomicile
    }

    private var pilotQualification: PilotQualification {
        PilotQualification(rawValue: pilotQualificationRawValue) ?? .captain
    }

    private var gridDays: [IPadCalendarGridDay] {
        guard let bp = currentBidPeriod else { return [] }
        return iPadCalendarGrid(for: bp, domicile: domicile)
    }

    /// Renders the active BP plus 1 BP before and 2 BPs after, each as its own
    /// section. BP26-07 (4-week BP) renders only its real 4 weeks — no duplicate
    /// next-BP padding rows. Header tracking updates as the user scrolls between
    /// sections.
    private var displayedBidPeriodSections: [IPadBidPeriodGridSection] {
        guard let currentBidPeriod else { return [] }
        var collected: [CalendarBidPeriod] = []

        // 1 BP before
        var cursor = currentBidPeriod
        var prevs: [CalendarBidPeriod] = []
        for _ in 0..<1 {
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
        .onChange(of: viewModel.crewAccessSchedules) { _, _ in refreshCalendarLayouts() }
        .onChange(of: viewModel.schedules) { _, _ in refreshCalendarLayouts() }
        .onChange(of: pilotQualificationRawValue) { _, _ in refreshCalendarLayouts() }
        .onChange(of: bidTransitionTimelineEnabled) { _, _ in refreshCalendarLayouts() }
        .onChange(of: faaMedicalExpiryDate) { _, _ in refreshCalendarLayouts() }
        .onChange(of: passportExpiryDate) { _, _ in refreshCalendarLayouts() }
        .onChange(of: chinaVisaExpiryDate) { _, _ in refreshCalendarLayouts() }
        .onChange(of: domicile) { _, _ in
            loadBidPeriod(for: Date())
            refreshCalendarLayouts()
        }
        .onChange(of: currentBidPeriod) { _, bp in
            selectedBidPeriodID = bp?.id
            headerBidPeriod = bp
            refreshCalendarLayouts()
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
                    scrollTrigger = UUID()
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
                // aren't yet in the rendered window. With at most 4 BP sections
                // (40 rows total) the performance cost of eager VStack is negligible.
                VStack(spacing: 0) {
                    Rectangle().fill(Color(.separator)).frame(height: 1)
                    ForEach(Array(displayedBidPeriodSections.enumerated()), id: \.element.id) { sectionIndex, section in
                        let bp = section.bidPeriod
                        let layout = bpLayoutCache[bp.id]
                        let grid = layout?.grid ?? iPadCalendarGrid(for: bp, domicile: domicile)
                        let segsByDay: [Int: [CalendarSegment]] = layout?.segmentsByDayIndex ?? {
                            let days = grid.map(\.calendarDay)
                            let trips = visibleTrips(in: bp, trips: allTrips)
                            return segmentsByDayIndex(for: trips, days: days)
                        }()
                        let tripsByID = layout?.tripsByID ?? {
                            let trips = visibleTrips(in: bp, trips: allTrips)
                            return Dictionary(uniqueKeysWithValues: trips.map { ($0.id, $0) })
                        }()
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
                                segmentsByDayIndex: segsByDay,
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
            // Surrounding BPs are rendered in displayedBidPeriodSections, so the natural
            // scroll origin would land on the oldest BP. Anchor the initial view
            // to the active (Today's) BP. Retry loop handles the race between
            // .task startup and onAppear setting currentBidPeriod.
            .task {
                for delay in [50_000_000, 100_000_000, 200_000_000, 400_000_000] as [UInt64] {
                    try? await Task.sleep(nanoseconds: delay)
                    guard let id = currentBidPeriod?.id else { continue }
                    proxy.scrollTo(id, anchor: .top)
                    return
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
            .onChange(of: scrollTrigger) { _, _ in
                guard let id = currentBidPeriod?.id else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .top)
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
        bidPeriod: CalendarBidPeriod,
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
                            let layerData = dayLayerCache[rowDays[col].calendarDay.displayDateKey]
                                ?? dayLayerData(for: rowDays[col], in: bidPeriod)
                            CalendarDayCell(
                                gridDay: rowDays[col],
                                payPeriodLabel: layerData.payPeriodLabel,
                                financialIndicator: layerData.financialIndicator,
                                personalChips: layerData.personalChips,
                                bidEventChips: layerData.bidEventChips
                            )
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
                        let x = contentFrame.minX + span.startRowFraction * contentFrame.width + CalendarDayCell.metrics.layerHorizontalInset
                        let width = max(
                            (span.endRowFraction - span.startRowFraction) * contentFrame.width - CalendarDayCell.metrics.layerHorizontalInset * 2,
                            1
                        )
                        let y = contentFrame.minY + CGFloat(span.lane) * (CalendarDayCell.metrics.laneHeight + CalendarDayCell.metrics.laneSpacing)
                        IPadTripBarSpanView(
                            label: tripBarLabel(for: trip),
                            isSelected: selectedTripID == span.tripID,
                            regressedRanges: span.regressedRanges,
                            hasRegression: span.hasRegression
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

    private func payPeriodLabel(for gridDay: IPadCalendarGridDay, in bidPeriod: CalendarBidPeriod) -> String? {
        guard !gridDay.isOverflow else { return nil }
        let index = gridDay.calendarDay.payPeriodIndex
        guard bidPeriod.days.contains(where: { $0.payPeriodIndex == index }) else { return nil }
        return resolvePayPeriodLabel(
            for: gridDay.calendarDay.dayStartUTC.addingTimeInterval(12 * 60 * 60),
            domicile: domicile
        )
    }

    private func financialIndicator(for gridDay: IPadCalendarGridDay) -> IPadCalendarFinancialIndicator? {
        guard !gridDay.isOverflow else { return nil }
        return IPadCalendarCycleData.financialIndicator(for: gridDay.calendarDay.displayDateKey)
    }

    private func bidEventChips(for gridDay: IPadCalendarGridDay) -> [IPadCalendarEventChip] {
        guard !gridDay.isOverflow, bidTransitionTimelineEnabled else { return [] }
        let dateKey = gridDay.calendarDay.displayDateKey
        return IPadCalendarCycleData.bidEventChips(for: dateKey, qualification: pilotQualification)
    }

    private func dayLayerData(for gridDay: IPadCalendarGridDay, in bidPeriod: CalendarBidPeriod) -> IPadCalendarDayLayerData {
        guard !gridDay.isOverflow else { return .empty }
        let dateKey = gridDay.calendarDay.displayDateKey
        return IPadCalendarDayLayerData(
            payPeriodLabel: payPeriodLabel(for: gridDay, in: bidPeriod),
            financialIndicator: IPadCalendarCycleData.financialIndicator(for: dateKey),
            personalChips: personalExpiryChips(for: dateKey),
            bidEventChips: bidTransitionTimelineEnabled
                ? IPadCalendarCycleData.bidEventChips(for: dateKey, qualification: pilotQualification)
                : []
        )
    }

    private func personalExpiryChips(for dateKey: String) -> [IPadCalendarEventChip] {
        [
            personalExpiryChip(
                storedDateKey: faaMedicalExpiryDate,
                dateKey: dateKey,
                title: "FAA Medical Expiry Date",
                compactTitle: "MEDICAL EXP"
            ),
            personalExpiryChip(
                storedDateKey: passportExpiryDate,
                dateKey: dateKey,
                title: "Passport Expiry Date",
                compactTitle: "PPT"
            ),
            personalExpiryChip(
                storedDateKey: chinaVisaExpiryDate,
                dateKey: dateKey,
                title: "China Visa Expiry Date",
                compactTitle: "VISA"
            )
        ]
        .compactMap { $0 }
    }

    private func personalExpiryChip(
        storedDateKey: String,
        dateKey: String,
        title: String,
        compactTitle: String
    ) -> IPadCalendarEventChip? {
        guard !storedDateKey.isEmpty, storedDateKey == dateKey else { return nil }
        let daysRemaining = IPadCalendarCycleData.daysFromToday(to: storedDateKey)
        return IPadCalendarEventChip(
            id: "personal-\(compactTitle)-\(storedDateKey)",
            title: title,
            compactTitle: compactTitle,
            layer: .personal(IPadCalendarCycleData.personalWarningState(daysRemaining: daysRemaining))
        )
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

    private func loadBidPeriod(for date: Date) {
        currentBidPeriod = bidPeriod(for: date, domicile: domicile)
        headerBidPeriod = currentBidPeriod
        // refreshCalendarLayouts fires via onChange(of: currentBidPeriod)
    }

    /// Rebuilds layout cache for all displayed BP sections.
    /// Called on schedule change, BP navigation, or initial load.
    /// selectedTripID changes do NOT call this — segments are independent of selection.
    private func refreshCalendarLayouts() {
        let trips = normalizeCalendarTrips(from: viewModel.crewAccessSchedules)
        cachedAllTrips = trips
        var cache: [String: CalendarBPLayout] = [:]
        for section in displayedBidPeriodSections {
            let bp = section.bidPeriod
            let grid = iPadCalendarGrid(for: bp, domicile: domicile)
            let days = grid.map(\.calendarDay)
            let bpTrips = visibleTrips(in: bp, trips: trips)
            let segs = segmentsByDayIndex(for: bpTrips, days: days)
            let byID = Dictionary(uniqueKeysWithValues: bpTrips.map { ($0.id, $0) })
            cache[bp.id] = CalendarBPLayout(grid: grid, segmentsByDayIndex: segs, tripsByID: byID)
        }
        bpLayoutCache = cache
        dayLayerCache = buildDayLayerCache(from: cache)
    }

    private func buildDayLayerCache(from layoutCache: [String: CalendarBPLayout]) -> [String: IPadCalendarDayLayerData] {
        var cache: [String: IPadCalendarDayLayerData] = [:]
        for section in displayedBidPeriodSections {
            let bp = section.bidPeriod
            let grid = layoutCache[bp.id]?.grid ?? iPadCalendarGrid(for: bp, domicile: domicile)
            for gridDay in grid where !gridDay.isOverflow {
                cache[gridDay.calendarDay.displayDateKey] = dayLayerData(for: gridDay, in: bp)
            }
        }
        return cache
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
    /// True when any segment of this span has a local-time regression.
    /// Used to paint the trailing portion of the bar orange when the
    /// normalised regressedRanges collapse to zero width (a known edge case
    /// where arrival == span end, making both bounds equal after clamping).
    let hasRegression: Bool
}

private enum IPadCalendarFinancialIndicator {
    case smallCheck
    case bigCheck
}

private struct IPadCalendarDayLayerData {
    let payPeriodLabel: String?
    let financialIndicator: IPadCalendarFinancialIndicator?
    let personalChips: [IPadCalendarEventChip]
    let bidEventChips: [IPadCalendarEventChip]

    static let empty = IPadCalendarDayLayerData(
        payPeriodLabel: nil,
        financialIndicator: nil,
        personalChips: [],
        bidEventChips: []
    )
}

private struct IPadCalendarEventChip: Identifiable, Equatable {
    enum Layer: Equatable {
        case bid
        case personal(IPadCalendarPersonalWarningState)
        case operational
    }

    let id: String
    let title: String
    let compactTitle: String
    let layer: Layer
}

private enum IPadCalendarPersonalWarningState: Equatable {
    case normal
    case yellow
    case orange
    case red
    case expired
}

private enum IPadCalendarCycleData {
    private static let smallCheckBase = "2025-12-29"
    private static let bigCheckBase = "2026-01-12"

    private static let bidPackageOutByBP: [(String, String)] = [
        ("2025-12-25", "BP26-02"),
        ("2026-02-19", "BP26-03"),
        ("2026-04-16", "BP26-04"),
        ("2026-06-11", "BP26-05"),
        ("2026-08-06", "BP26-06"),
        ("2026-10-01", "BP26-07"),
        ("2026-10-29", "BP27-01"),
        ("2026-12-24", "BP27-02")
    ]

    private static let caBidCloseByBP: [(String, String)] = [
        ("2026-01-01", "BP26-02"),
        ("2026-02-26", "BP26-03"),
        ("2026-04-23", "BP26-04"),
        ("2026-06-18", "BP26-05"),
        ("2026-08-13", "BP26-06"),
        ("2026-10-08", "BP26-07"),
        ("2026-11-05", "BP27-01"),
        ("2026-12-31", "BP27-02")
    ]

    static func financialIndicator(for dateKey: String) -> IPadCalendarFinancialIndicator? {
        if isRepeatingDate(dateKey, from: smallCheckBase, everyDays: 28) {
            return .smallCheck
        }
        if isRepeatingDate(dateKey, from: bigCheckBase, everyDays: 28) {
            return .bigCheck
        }
        return nil
    }

    static func bidEventChips(for dateKey: String, qualification: PilotQualification) -> [IPadCalendarEventChip] {
        var chips: [IPadCalendarEventChip] = []

        for (eventDate, bp) in bidPackageOutByBP where eventDate == dateKey {
            chips.append(bidChip(id: "bid-package-\(bp)", title: "Bid Package Out \(bp)", compactTitle: "BID PACKAGE OUT"))
        }

        for (caCloseDate, bp) in caBidCloseByBP {
            appendDerivedBidEvents(
                fromCAClose: caCloseDate,
                bidPeriod: bp,
                targetDateKey: dateKey,
                qualification: qualification,
                into: &chips
            )
        }

        return chips
    }

    static func daysFromToday(to dateKey: String) -> Int? {
        guard let target = date(from: dateKey) else { return nil }
        let todayKey = dateFormatter.string(from: Date())
        guard let today = date(from: todayKey) else { return nil }
        return calendar.dateComponents([.day], from: today, to: target).day
    }

    static func personalWarningState(daysRemaining: Int?) -> IPadCalendarPersonalWarningState {
        guard let daysRemaining else { return .normal }
        if daysRemaining < 0 { return .expired }
        if daysRemaining < 30 { return .red }
        if daysRemaining < 60 { return .orange }
        if daysRemaining <= 90 { return .yellow }
        return .normal
    }

    private static func appendDerivedBidEvents(
        fromCAClose caCloseDate: String,
        bidPeriod: String,
        targetDateKey: String,
        qualification: PilotQualification,
        into chips: inout [IPadCalendarEventChip]
    ) {
        let events: [(Int, String, String, String)]
        switch qualification {
        case .captain:
            events = [
                (0, "CA Schedule Bid Close", "CA BID CLOSE", "ca-bid-close"),
                (10, "CA VTO Published", "CA VTO", "ca-vto-published"),
                (12, "CA VTO Bid Close", "CA VTO CLOSE", "ca-vto-close"),
                (18, "CA LITT Accepted", "CA LITT", "ca-litt")
            ]
        case .firstOfficer:
            events = [
                (4, "FO Schedule Bid Close", "FO BID CLOSE", "fo-bid-close"),
                (11, "FO VTO Published", "FO VTO", "fo-vto-published"),
                (13, "FO VTO Bid Close", "FO VTO CLOSE", "fo-vto-close"),
                (20, "FO LITT Accepted", "FO LITT", "fo-litt")
            ]
        }

        for (offset, title, compactTitle, idPrefix) in events {
            guard let date = dateKey(byAddingDays: offset, to: caCloseDate), date == targetDateKey else { continue }
            chips.append(bidChip(
                id: "\(idPrefix)-\(bidPeriod)",
                title: "\(title) \(bidPeriod)",
                compactTitle: compactTitle
            ))
        }
    }

    private static func bidChip(id: String, title: String, compactTitle: String) -> IPadCalendarEventChip {
        IPadCalendarEventChip(
            id: id,
            title: title,
            compactTitle: compactTitle,
            layer: .bid
        )
    }

    private static func isRepeatingDate(_ dateKey: String, from baseKey: String, everyDays interval: Int) -> Bool {
        guard let targetDate = date(from: dateKey), let base = date(from: baseKey) else { return false }
        let dayDelta = calendar.dateComponents([.day], from: base, to: targetDate).day ?? Int.min
        return dayDelta >= 0 && dayDelta % interval == 0
    }

    private static func dateKey(byAddingDays days: Int, to baseKey: String) -> String? {
        guard let base = date(from: baseKey),
              let result = calendar.date(byAdding: .day, value: days, to: base)
        else { return nil }
        return dateFormatter.string(from: result)
    }

    private static func date(from key: String) -> Date? {
        dateFormatter.date(from: key)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
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
    var current: (tripID: String, lane: Int, startDay: CalendarDay, endDay: CalendarDay, start: Double, end: Double, ranges: [ClosedRange<Double>], hasRegression: Bool)?

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
            regressedRanges: normalizedRanges,
            hasRegression: current.hasRegression
        ))
    }

    for segment in sorted {
        guard let day = dayByIndex[segment.dayIndex] else { continue }
        let segmentRanges: [ClosedRange<Double>] = segment.regressedRange.map {
            rowFraction(day: day, fraction: $0.lowerBound)...rowFraction(day: day, fraction: $0.upperBound)
        }.map { [$0] } ?? []

        let segmentHasRegression = segment.hasLocalTimeRegression

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
                existing.ranges + segmentRanges,
                existing.hasRegression || segmentHasRegression
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
                segmentRanges,
                segmentHasRegression
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
    let payPeriodLabel: String?
    let financialIndicator: IPadCalendarFinancialIndicator?
    let personalChips: [IPadCalendarEventChip]
    let bidEventChips: [IPadCalendarEventChip]

    @State private var isShowingPayPeriodPopover = false
    @State private var isShowingEventPopover = false

    struct Metrics {
        let dateHeaderHeight: CGFloat = 28
        let laneHeight: CGFloat = 18
        let laneSpacing: CGFloat = 1
        let barTopPadding: CGFloat = 7
        let layerHorizontalInset: CGFloat = 5
        let eventStackBottomPadding: CGFloat = 2.5
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
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = .gmt
        let cell = utcCal.dateComponents([.year, .month, .day], from: dayDate)
        let local = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return cell.year == local.year && cell.month == local.month && cell.day == local.day
    }
    private var isSunday: Bool { gridDay.calendarDay.weekdayIndex == 0 }
    private var isSaturday: Bool { gridDay.calendarDay.weekdayIndex == 6 }
    private var isFirstOfMonth: Bool {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return utc.component(.day, from: dayDate) == 1
    }
    private var isPayPeriodStart: Bool {
        !gridDay.isOverflow && gridDay.calendarDay.index % 28 == 0
    }
    private var eventStackChips: [IPadCalendarEventChip] {
        bidEventChips + personalChips
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            cellBackground

            if isPayPeriodStart, let payPeriodLabel {
                payPeriodRibbon(label: payPeriodLabel)
            }

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
                    Text(Self.monthFormatter.string(from: dayDate).uppercased())
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 5)
            .padding(.top, 3)

            if let financialIndicator {
                financialBadge(financialIndicator)
                    .padding(.top, 5)
                    .padding(.trailing, 6)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
            }

            if !eventStackChips.isEmpty {
                eventStack
                    .padding(.horizontal, Self.metrics.layerHorizontalInset)
                    .padding(.bottom, Self.metrics.eventStackBottomPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
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

    private func payPeriodRibbon(label: String) -> some View {
        Button {
            isShowingPayPeriodPopover = true
        } label: {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "#FCB900"),
                            Color(hex: "#301504")
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pay Period starts: \(label)")
        .popover(isPresented: $isShowingPayPeriodPopover, arrowEdge: .leading) {
            Text(label)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func financialBadge(_ indicator: IPadCalendarFinancialIndicator) -> some View {
        let isBigCheck = indicator == .bigCheck
        return Image(systemName: isBigCheck ? "dollarsign.circle.fill" : "dollarsign.circle")
            .font(.system(size: isBigCheck ? 15 : 13, weight: isBigCheck ? .semibold : .medium))
            .foregroundStyle(isBigCheck ? Color(hex: "#FCB900") : Color(hex: "#B8871B"))
            .shadow(color: isBigCheck ? Color(hex: "#FCB900").opacity(0.28) : .clear, radius: 4)
            .accessibilityLabel(isBigCheck ? "Big check payday" : "Small check payday")
    }

    private var personalStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(personalChips) { chip in
                personalChipView(chip)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func personalChipView(_ chip: IPadCalendarEventChip) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(eventColor(for: chip.layer))
                .frame(width: 5, height: 5)
            Text(chip.compactTitle)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(eventForegroundColor(for: chip.layer))
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(eventFillColor(for: chip.layer))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(eventColor(for: chip.layer).opacity(0.28), lineWidth: 0.7)
        )
        .accessibilityLabel(chip.title)
    }

    private var eventStack: some View {
        Button {
            if eventStackChips.count > 1 {
                isShowingEventPopover = true
            }
        } label: {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color(.separator).opacity(0.35))
                    .frame(height: 0.7)

                HStack(spacing: 5) {
                    if let chip = eventStackChips.first {
                        eventChipView(chip)
                    }

                    if eventStackChips.count > 1 {
                        Text("+\(eventStackChips.count - 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(eventForegroundColor(for: eventStackChips.first?.layer ?? .bid))
                            .frame(height: 15)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .center)
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity, alignment: .bottom)
            .background(Color(.secondarySystemBackground).opacity(0.74))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(eventStackChips.map(\.title).joined(separator: ", "))
        .popover(isPresented: $isShowingEventPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(eventStackChips) { chip in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(eventColor(for: chip.layer))
                            .frame(width: 8, height: 8)
                        Text(chip.title)
                            .font(.system(size: 13, weight: .medium))
                    }
                }
            }
            .padding(12)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func eventChipView(_ chip: IPadCalendarEventChip) -> some View {
        Text(chip.compactTitle)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(eventForegroundColor(for: chip.layer))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(height: 15)
    }

    private func eventColor(for layer: IPadCalendarEventChip.Layer) -> Color {
        switch layer {
        case .bid:
            return Color(hex: "#B8871B")
        case .personal(let state):
            switch state {
            case .normal:
                return .teal
            case .yellow:
                return .yellow
            case .orange:
                return .orange
            case .red, .expired:
                return .red
            }
        case .operational:
            return .cyan
        }
    }

    private func eventFillColor(for layer: IPadCalendarEventChip.Layer) -> Color {
        switch layer {
        case .personal(.expired):
            return .red.opacity(0.24)
        case .bid, .personal(_), .operational:
            return eventColor(for: layer).opacity(0.14)
        }
    }

    private func eventForegroundColor(for layer: IPadCalendarEventChip.Layer) -> Color {
        switch layer {
        case .personal(.expired):
            return .red
        case .bid, .personal(_), .operational:
            return eventColor(for: layer)
        }
    }
}

// MARK: - Layout cache type

/// Pre-computed layout for one Bid Period. Independent of selectedTripID.
private struct CalendarBPLayout {
    let grid: [IPadCalendarGridDay]
    let segmentsByDayIndex: [Int: [CalendarSegment]]
    let tripsByID: [String: CalendarTrip]
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double
        switch cleaned.count {
        case 6:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        default:
            red = 0
            green = 0
            blue = 0
        }

        self.init(red: red, green: green, blue: blue)
    }
}

#Preview {
    IPadBidPeriodCalendarView(
        selectedTripID: .constant(nil),
        selectedBidPeriodID: .constant(nil)
    )
    .environmentObject(AppViewModel.shared)
    .frame(height: 600)
}
