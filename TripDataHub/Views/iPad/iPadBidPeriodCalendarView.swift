import SwiftUI

// MARK: - Main View

struct IPadBidPeriodCalendarView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var selectedTripID: String?
    @Binding var selectedBidPeriodID: String?
    @Binding var isFriendsOverlayEnabled: Bool

    @State private var currentBidPeriod: CalendarBidPeriod? = nil

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

    private var gridDays: [IPadCalendarGridDay] {
        guard let bp = currentBidPeriod else { return [] }
        return iPadCalendarGrid(for: bp)
    }

    private var calendarDays: [CalendarDay] {
        gridDays.map(\.calendarDay)
    }

    private var visibleTripList: [CalendarTrip] {
        guard let bp = currentBidPeriod else { return [] }
        return visibleTrips(in: bp, trips: allTrips)
    }

    private var segmentsByDayIndex: [Int: [CalendarSegment]] {
        guard !calendarDays.isEmpty else { return [:] }
        let allSegments = visibleTripList.flatMap { buildSegments(trip: $0, days: calendarDays) }
        let withLanes = assignLanes(to: allSegments)
        return Dictionary(grouping: withLanes, by: \.dayIndex)
    }

    private var tripsByID: [String: CalendarTrip] {
        Dictionary(uniqueKeysWithValues: visibleTripList.map { ($0.id, $0) })
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headerView
            dowHeaderView
            GeometryReader { geo in
                gridView(totalHeight: geo.size.height)
            }
        }
        .background(Color(.systemBackground))
        .onAppear { loadBidPeriod(for: Date()) }
        .onChange(of: viewModel.crewAccessSchedules) { _, _ in /* segments recomputed */ }
        .onChange(of: viewModel.schedules) { _, _ in /* segments recomputed */ }
        .onChange(of: currentBidPeriod) { _, bp in
            selectedBidPeriodID = bp?.id
        }
    }

    // MARK: Header

    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentBidPeriod?.id ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(bidPeriodRangeLabel)
                    .font(.system(size: 15, weight: .medium))
            }

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
                            .font(.system(size: 11, weight: .semibold))
                        Text(previousBPLabel)
                            .font(.system(size: 12, weight: .medium))
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
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(currentBidPeriod == nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

    private func gridView(totalHeight: CGFloat) -> some View {
        let rowHeight = totalHeight / 8
        return VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { row in
                rowView(weekIndex: row, rowHeight: rowHeight)
                if row < 7 { Divider() }
            }
        }
    }

    private func rowView(weekIndex: Int, rowHeight: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { col in
                let absoluteIndex = weekIndex * 7 + col
                if absoluteIndex < gridDays.count {
                    let gridDay = gridDays[absoluteIndex]
                    // Overflow cells render as date-only in Phase 1 — see iPadCalendarGrid(for:)
                    // for why we cannot key segments by `calendarDay.index` for overflow rows
                    // (the next BP's days share index values 0..27 with the current BP).
                    let daySegs: [CalendarSegment] = gridDay.isOverflow
                        ? []
                        : (segmentsByDayIndex[gridDay.calendarDay.index] ?? [])
                    CalendarDayCell(
                        gridDay: gridDay,
                        segments: daySegs,
                        tripsByID: tripsByID,
                        selectedTripID: $selectedTripID,
                        rowHeight: rowHeight
                    )
                    .frame(maxWidth: .infinity)
                    if col < 6 { Divider() }
                }
            }
        }
        .frame(height: rowHeight)
    }

    // MARK: Navigation helpers

    private var bidPeriodRangeLabel: String {
        guard let bp = currentBidPeriod else { return "" }
        let start = Self.dateRangeFormatter.string(from: bp.startDateUTC)
        let end = Self.dateRangeFormatter.string(from: bp.endDateUTC)
        let year = Self.yearFormatter.string(from: bp.endDateUTC)
        return "\(start) – \(end), \(year)"
    }

    private var previousBPLabel: String {
        guard let bp = currentBidPeriod,
              let prev = bidPeriod(for: bp.startDateUTC.addingTimeInterval(-1)) else {
            return "Prev"
        }
        return prev.id
    }

    private var nextBPLabel: String {
        guard let bp = currentBidPeriod,
              let next = bidPeriod(for: bp.endDateUTC) else {
            return "Next"
        }
        return next.id
    }

    private var hasFriendsForOverlay: Bool {
        viewModel.friendConnections.contains { $0.status == .accepted }
    }

    private func loadBidPeriod(for date: Date) {
        currentBidPeriod = bidPeriod(for: date)
    }

    private func navigateToPreviousBP() {
        guard let bp = currentBidPeriod,
              let prev = bidPeriod(for: bp.startDateUTC.addingTimeInterval(-1)) else { return }
        currentBidPeriod = prev
    }

    private func navigateToNextBP() {
        guard let bp = currentBidPeriod,
              let next = bidPeriod(for: bp.endDateUTC) else { return }
        currentBidPeriod = next
    }
}

// MARK: - Day Cell

private struct CalendarDayCell: View {
    let gridDay: IPadCalendarGridDay
    let segments: [CalendarSegment]
    let tripsByID: [String: CalendarTrip]
    @Binding var selectedTripID: String?
    let rowHeight: CGFloat

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
    private var isWeekend: Bool {
        let col = gridDay.calendarDay.weekdayIndex
        return col == 0 || col == 6
    }
    private var isFirstOfMonth: Bool {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return utc.component(.day, from: dayDate) == 1
    }

    private let dateHeaderHeight: CGFloat = 22
    private let laneHeight: CGFloat = 14
    private let laneSpacing: CGFloat = 1
    private let barTopPadding: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Background
                cellBackground

                // Date header
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Group {
                        if isToday {
                            Text(Self.dayFormatter.string(from: dayDate))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.accentColor))
                        } else {
                            Text(Self.dayFormatter.string(from: dayDate))
                                .font(.system(size: 11, weight: gridDay.isOverflow ? .light : .regular))
                                .foregroundStyle(gridDay.isOverflow ? .tertiary : .primary)
                                .frame(width: 20, height: 20)
                        }
                    }
                    if isFirstOfMonth || gridDay.calendarDay.index == 0 {
                        Text(Self.monthFormatter.string(from: dayDate))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 4)
                .padding(.top, 2)

                // Trip bars
                let cellFrame = CGRect(origin: .zero, size: geo.size)
                let adjustedFrame = CGRect(
                    x: cellFrame.minX,
                    y: dateHeaderHeight + barTopPadding,
                    width: cellFrame.width,
                    height: cellFrame.height - dateHeaderHeight - barTopPadding
                )

                ForEach(segments, id: \.tripID) { segment in
                    if let trip = tripsByID[segment.tripID] {
                        let frame = frameForSegment(
                            segment,
                            dayFrame: adjustedFrame,
                            laneHeight: laneHeight,
                            laneSpacing: laneSpacing
                        )
                        IPadTripBarView(
                            segment: segment,
                            trip: trip,
                            isSelected: selectedTripID == segment.tripID
                        ) {
                            selectedTripID = segment.tripID
                        }
                        .frame(width: max(frame.width, 1), height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
            .opacity(gridDay.isOverflow ? 0.35 : 1)
        }
    }

    @ViewBuilder
    private var cellBackground: some View {
        if isWeekend {
            Color(.systemFill)
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
