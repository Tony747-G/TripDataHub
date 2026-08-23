import SwiftUI

struct IPadTimelineSidebarView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var selectedTripID: String?
    @Binding var scrollToDefaultTrigger: UUID
    /// When set ("payPeriod|pairing"), the view renders only that trip's legs —
    /// no "Timeline" header, no next-report strip, no row selection or delete.
    /// Used by the calendar's trip popup.
    var focusedTripID: String? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var tripDataByTripID: [String: CrewAccessTripSummary] = [:]
    @State private var deleteTripConfirmPairing: String? = nil
    @State private var friendScheduleMatches: FriendScheduleMatches = .empty
    @State private var friendMatchAlert: FriendMatchPresentation? = nil
    @State private var selectedManualOperationalEvent: ManualOperationalEvent?
    @State private var selectedFlightLeg: TripLeg?
    // Cached per-schedule-update data — computed once in refreshLegData(), not on every body eval.
    @State private var legData = TimelineLegData(schedules: [])
    @State private var cachedTripStartLegIDs: Set<UUID> = []
    @State private var tripDataKeyByLegID: [UUID: String] = [:]
    @State private var firstRowIDByTripID: [String: String] = [:]
    @State private var firstTripSummaryIDByTripID: [String: String] = [:]

    private var dateHeaderTextColor: Color {
        ScheduleColors.timelineDateHeaderText(for: colorScheme)
    }

    private var tripCardBackground: Color {
        if colorScheme == .light {
            return Color(red: 0.82, green: 0.82, blue: 0.84)
        }
        return Color(red: 0.16, green: 0.16, blue: 0.18)
    }

    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    @AppStorage("timeline_clock_display") private var timelineClockDisplayRawValue = TimelineClockDisplay.lcl.rawValue
    @AppStorage(OperationalSettings.crewBaseKey) private var crewDomicileRawValue = OperationalSettings.defaultCrewBase.rawValue

    private var selectedClockDisplay: TimelineClockDisplay {
        TimelineClockDisplay(rawValue: timelineClockDisplayRawValue) ?? .lcl
    }

    private var selectedCrewDomicile: CrewBase {
        CrewBase(rawValue: crewDomicileRawValue) ?? OperationalSettings.defaultCrewBase
    }

    private var selectedDomicileTimeZone: TimeZone {
        selectedCrewDomicile.timeZone
    }

    private var fontScale: CGFloat {
        (AppFontSizeOption(rawValue: appFontSizeOptionRawValue) ?? .medium).scaleFactor
    }

    private var timelineFontScale: CGFloat {
        fontScale * 0.78
    }

    private var sidebarSchedules: [PayPeriodSchedule] {
        // Match iPhone Timeline semantics: only explicitly imported CrewAccess
        // trips appear in Timeline. TripBoard/BidPro schedules are not import
        // files and should not surface here as unexpected future trips.
        guard let focusedTripID else { return viewModel.crewAccessSchedules }
        return viewModel.crewAccessSchedules.compactMap { schedule in
            let legs = schedule.legs.filter { "\($0.payPeriod)|\($0.pairing)" == focusedTripID }
            guard !legs.isEmpty else { return nil }
            return PayPeriodSchedule(
                id: schedule.id,
                label: schedule.label,
                tripCount: 1,
                legCount: legs.count,
                openTimeCount: 0,
                updatedAt: schedule.updatedAt,
                legs: legs,
                openTimeTrips: []
            )
        }
    }

    /// Section (day) IDs that contain at least one leg of the selected trip.
    /// Depends only on cached `legData` (stable) + `selectedTripID`.
    private var selectedSectionIDs: Set<String> {
        guard let selected = selectedTripID else { return [] }
        return Set(
            legData.daySections
                .filter { section in section.legs.contains { "\($0.payPeriod)|\($0.pairing)" == selected } }
                .map(\.id)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if focusedTripID == nil {
                sidebarHeader
                nextReportCountdownStrip
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(legData.daySections) { section in
                            Section {
                                ForEach(section.entries) { entry in
                                    switch entry {
                                    case .leg(let leg):
                                        let tripID = "\(leg.payPeriod)|\(leg.pairing)"
                                        let rowID = "\(tripID)|\(leg.leg)|\(leg.id.uuidString)"
                                        let isSelected = focusedTripID == nil && selectedTripID == tripID

                                        let isHighlighted = deleteTripConfirmPairing == leg.pairing
                                        let flightMatches = friendScheduleMatches.flightMatchesByLegID[leg.id] ?? []
                                        let hasFlightMatch = !flightMatches.isEmpty
                                        if cachedTripStartLegIDs.contains(leg.id) {
                                            tripSummaryCard(for: leg, isPast: section.isPast, isHighlighted: isHighlighted)
                                                .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                                                .overlay(alignment: .leading) {
                                                    if isSelected {
                                                        Rectangle().fill(Color.accentColor).frame(width: 3)
                                                    }
                                                }
                                                .id("ipad.tripdata.\(leg.id.uuidString)")
                                                .simultaneousGesture(
                                                    LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                                        guard focusedTripID == nil else { return }
                                                        deleteTripConfirmPairing = leg.pairing
                                                    }
                                                )
                                        }
                                        Group {
                                            TimelineFlightRow(
                                                leg: leg,
                                                isPast: leg.isCompleted || isPastFlightRow(leg),
                                                fontScale: timelineFontScale,
                                                timeRangeText: timeRangeText(for: leg),
                                                dayDiff: dayShift(for: leg),
                                                blockConnectionDisplay: blockConnectionDisplay(for: leg),
                                                iconColor: hasFlightMatch ? friendMatchAmber : .primary,
                                                // Selection and highlight are transient UI state and must win over the
                                                // schedule-state tint. Passing them in keeps both backgrounds in the same
                                                // layer; applying the highlight outside the row let the row's own amber /
                                                // gray fill paint over the selection indicator.
                                                backgroundOverride: isHighlighted
                                                    ? Color.red.opacity(0.10)
                                                    : (isSelected ? Color.accentColor.opacity(0.12) : nil),
                                                onFriendMatchTap: hasFlightMatch ? {
                                                    friendMatchAlert = flightMatchPresentation(for: leg, matches: flightMatches)
                                                } : nil,
                                                onFlightTap: {
                                                    // Select, never deselect. Toggling here meant that opening the Flight
                                                    // Log for the already-selected trip also cleared the selection.
                                                    if focusedTripID == nil {
                                                        selectedTripID = tripID
                                                    }
                                                    selectedFlightLeg = leg
                                                }
                                            )
                                            .overlay(alignment: .leading) {
                                                if isSelected {
                                                    Rectangle()
                                                        .fill(Color.accentColor)
                                                        .frame(width: 3)
                                                }
                                            }
                                            .simultaneousGesture(
                                                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                                    guard focusedTripID == nil else { return }
                                                    deleteTripConfirmPairing = leg.pairing
                                                }
                                            )

                                            if shouldShowLayover(leg: leg) {
                                                let station = leg.layoverStation ?? leg.arrAirport
                                                let hotel = leg.layoverHotelName
                                                    ?? tripDataByTripID[tripDataKeyByLegID[leg.id] ?? Self.fileKey(for: leg)]?.hotelByStation[CrewAccessTripSummaryStore.stationKey(station)]
                                                    ?? tripDataByTripID[leg.pairing]?.hotelByStation[CrewAccessTripSummaryStore.stationKey(station)]
                                                    ?? ""
                                                let restOverlaps = friendScheduleMatches.restOverlapsByArrivalLegID[leg.id] ?? []
                                                let hasRestOverlap = !restOverlaps.isEmpty
                                                TimelineView(.periodic(from: Date(), by: 60)) { context in
                                                    TimelineLayoverCard(
                                                        station: station,
                                                        hotel: hotel,
                                                        durationText: TimelineLayoverSupport.durationText(
                                                            arrDate: LegConnectionTextBuilder.parseUTC(leg.arrUTC),
                                                            nextLeg: legData.nextLegByID[leg.id],
                                                            fallbackDuration: leg.layoverDuration
                                                        ),
                                                        remainingText: TimelineLayoverSupport.remainingText(
                                                            arrDate: LegConnectionTextBuilder.parseUTC(leg.arrUTC),
                                                            nextLeg: legData.nextLegByID[leg.id],
                                                            now: context.date
                                                        ),
                                                        arrLocalDateLabel: arrivalLocalDateLabel(for: leg),
                                                        isPast: TimelineLayoverSupport.isPastLayover(
                                                            arrDate: LegConnectionTextBuilder.parseUTC(leg.arrUTC),
                                                            nextLeg: legData.nextLegByID[leg.id]
                                                        ),
                                                        fontScale: timelineFontScale,
                                                        iconColor: hasRestOverlap ? friendMatchAmber : .primary,
                                                        onFriendMatchTap: hasRestOverlap ? {
                                                            friendMatchAlert = restOverlapPresentation(station: station, overlaps: restOverlaps)
                                                        } : nil
                                                    )
                                                    .background(isHighlighted ? Color.red.opacity(0.10) : (isSelected ? Color.accentColor.opacity(0.12) : Color.clear))
                                                    .overlay(alignment: .leading) {
                                                        if isSelected {
                                                            Rectangle().fill(Color.accentColor).frame(width: 3)
                                                        }
                                                    }
                                                }
                                                .id("ipad.layover.\(leg.id.uuidString)")
                                                .simultaneousGesture(
                                                    LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                                        guard focusedTripID == nil else { return }
                                                        deleteTripConfirmPairing = leg.pairing
                                                    }
                                                )
                                            }
                                        }
                                        .id(rowID)
                                    case .manualOperational(let event):
                                        TimelineManualOperationalRow(
                                            event: event,
                                            isPast: event.endUTC < Date(),
                                            fontScale: timelineFontScale,
                                            timeRangeText: manualOperationalTimeRangeText(for: event),
                                            dayDiff: manualOperationalDayShift(for: event)
                                        )
                                        .id("ipad.manual-operational.\(event.id.uuidString)")
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectedManualOperationalEvent = event
                                        }
                                        .simultaneousGesture(
                                            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                                selectedManualOperationalEvent = event
                                            }
                                        )
                                    }
                                }
                            } header: {
                                let isSectionSelected = selectedSectionIDs.contains(section.id)
                                let headerBg = ScheduleColors.dayHeaderBackground(for: colorScheme)
                                Text(section.label)
                                    .appScaledFont(.subheadline, weight: .bold, scale: timelineFontScale)
                                    .foregroundStyle(ScheduleColors.timelineDateHeaderText(for: colorScheme))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(headerBg)
                                    .overlay(isSectionSelected ? Color.accentColor.opacity(0.10) : Color.clear)
                                    .overlay(alignment: .leading) {
                                        if isSectionSelected {
                                            Rectangle().fill(Color.accentColor).frame(width: 3)
                                        }
                                    }
                            }
                        }
                    }
                    .background {
                        if focusedTripID != nil {
                            GeometryReader { contentGeo in
                                Color.clear.preference(
                                    key: FocusedTimelineContentHeightKey.self,
                                    value: contentGeo.size.height
                                )
                            }
                        }
                    }
                }
                .onChange(of: selectedTripID) { _, newID in
                    if let id = newID,
                       let targetID = selectedTripScrollTargetID(for: id) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(targetID, anchor: .top)
                        }
                    }
                }
                // On appear: if a trip is already selected (portrait sheet opened
                // from a calendar tap), scroll to that trip first. Otherwise fall
                // back to the next upcoming event.
                .task {
                    guard focusedTripID == nil else { return }
                    let initialTarget: String? = selectedTripID.flatMap { selectedTripScrollTargetID(for: $0) }
                        ?? nextScrollTargetID()
                    if let rowID = initialTarget { proxy.scrollTo(rowID, anchor: .top) }
                    for delay in [100_000_000, 200_000_000, 400_000_000] as [UInt64] {
                        try? await Task.sleep(nanoseconds: delay)
                        let target = selectedTripID.flatMap { selectedTripScrollTargetID(for: $0) }
                            ?? nextScrollTargetID()
                        if let rowID = target {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(rowID, anchor: .top)
                            }
                        }
                    }
                }
                .onChange(of: scrollToDefaultTrigger) { _, _ in
                    guard focusedTripID == nil else { return }
                    Task {
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        if let rowID = nextScrollTargetID() {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(rowID, anchor: .top)
                            }
                        }
                    }
                }
                .onChange(of: viewModel.scheduleDataRevision) { _, _ in
                    guard focusedTripID == nil else { return }
                    Task {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        if let rowID = nextScrollTargetID() {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(rowID, anchor: .top)
                            }
                        }
                    }
                }
                .onChange(of: viewModel.manualOperationalEvents) { _, _ in
                    refreshLegData()
                    guard focusedTripID == nil else { return }
                    Task {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        if let rowID = nextScrollTargetID() {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(rowID, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(.systemBackground))
        .onAppear {
            refreshLegData()
            refreshTripDataCards()
            refreshFriendScheduleMatches()
        }
        .onChange(of: viewModel.scheduleDataRevision) { _, _ in
            refreshLegData()
            refreshTripDataCards()
            refreshFriendScheduleMatches()
        }
        .onChange(of: selectedClockDisplay) { _, _ in
            refreshLegData()
        }
        .onChange(of: crewDomicileRawValue) { _, _ in
            refreshLegData()
        }
        .onChange(of: viewModel.friendConnectionsRevision) { _, _ in
            refreshFriendScheduleMatches()
        }
        .sheet(item: $friendMatchAlert) { presentation in
            FriendMatchPresentationView(presentation: presentation)
        }
        .confirmationDialog(
            deleteTripConfirmPairing.map { "Delete Trip \($0)?" } ?? "Delete Trip?",
            isPresented: Binding(
                get: { deleteTripConfirmPairing != nil },
                set: { if !$0 { deleteTripConfirmPairing = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Trip", role: .destructive) {
                if let pairing = deleteTripConfirmPairing {
                    let ids = Set(
                        viewModel.crewAccessSchedules
                            .filter { $0.legs.contains { $0.pairing == pairing } }
                            .map(\.id)
                    )
                    Task { await viewModel.deleteCrewAccessTrips(ids: ids) }
                }
                deleteTripConfirmPairing = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTripConfirmPairing = nil
            }
        } message: {
            Text("This will remove the trip from Timeline and synced devices.")
        }
        .sheet(item: $selectedManualOperationalEvent) { event in
            ManualEventDetailSheet(operationalEvent: event)
                .environmentObject(viewModel)
        }
        .sheet(item: $selectedFlightLeg) { leg in
            FlightLegDetailSheet(leg: leg) { registration in
                try await viewModel.updateCrewAccessRegistration(
                    for: leg,
                    registration: registration
                )
            }
        }
    }

    /// Layover中→Layoverカード、Trip先頭（未開始）→Trip summaryカード、
    /// それ以外→フライト行へのスクロールID。
    private func nextScrollTargetID() -> String? {
        let now = Date()
        let sortedLegs = legData.allLegs.sorted { lhs, rhs in
            if lhs.depLocal == rhs.depLocal { return lhs.flight < rhs.flight }
            return lhs.depLocal < rhs.depLocal
        }

        // 1. 現在 Layover 中か判定（到着 ≤ now < duty start）
        for leg in sortedLegs {
            guard shouldShowLayover(leg: leg),
                  let arr = LegConnectionTextBuilder.parseUTC(leg.arrUTC),
                  let nextLeg = legData.nextLegByID[leg.id]
            else { continue }
            let layoverEnd = TimelineLayoverSupport.restInfo(arrDate: arr, nextLeg: nextLeg)?.dutyStartUTC
                ?? LegConnectionTextBuilder.parseUTC(nextLeg.depUTC).map { $0.addingTimeInterval(-90 * 60) }
            guard let end = layoverEnd else { continue }
            if arr <= now && now < end {
                return "ipad.layover.\(leg.id.uuidString)"
            }
        }

        // 2. 現在飛行中または次のフライトを探す
        let target = sortedLegs.first { leg in
            guard let dep = LegConnectionTextBuilder.parseUTC(leg.depUTC) else { return false }
            if let arr = LegConnectionTextBuilder.parseUTC(leg.arrUTC),
               dep <= now,
               now < arr {
                return true
            }
            return dep >= now
        }
        guard let target else { return nil }

        // 3. そのレグがTrip先頭でsummaryカードがある場合はそちらへ
        if cachedTripStartLegIDs.contains(target.id) {
            return "ipad.tripdata.\(target.id.uuidString)"
        }

        // 4. フライト行へ
        let tripID = "\(target.payPeriod)|\(target.pairing)"
        return "\(tripID)|\(target.leg)|\(target.id.uuidString)"
    }

    private func selectedTripScrollTargetID(for tripID: String) -> String? {
        firstTripSummaryIDByTripID[tripID] ?? firstRowIDByTripID[tripID]
    }

    // MARK: Header

    private var sidebarHeader: some View {
        Text("Timeline")
            .appScaledFont(.headline, weight: .bold, scale: fontScale)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 24)
            .padding(.trailing, 16)
            .frame(height: 44)
            .background(Color(.secondarySystemBackground))
            .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Timeline-only next Trip report countdown

    @ViewBuilder
    private var nextReportCountdownStrip: some View {
        TimelineNextReportCountdownView(
            windows: TimelineNextReportCountdownBuilder.build(
                schedules: sidebarSchedules,
                domicileAirportCode: selectedCrewDomicile.reportAirportCode
            ),
            displayTimeZone: selectedClockDisplay == .utc
                ? TimeZone(secondsFromGMT: 0)!
                : selectedDomicileTimeZone,
            zoneCode: selectedClockDisplay == .utc ? "UTC" : selectedCrewDomicile.displayName,
            fontScale: timelineFontScale,
            normalCountdownColor: dateHeaderTextColor
        )
    }

    // MARK: Trip summary card

    /// Compact `Trip Id: ... / Credit: ...` row shown above each trip's first leg.
    /// Keyed by `{depLocalDate}_{pairing}` (payPeriod granularity) so that the
    /// same pairing in different pay periods resolves to the correct credit value.
    @ViewBuilder
    private func tripSummaryCard(for startLeg: TripLeg, isPast: Bool, isHighlighted: Bool = false) -> some View {
        let summary = tripDataByTripID[Self.fileKey(for: startLeg)]
        let creditText = Self.formattedDurationLabel(
            summary?.creditTime ?? fallbackCreditHHMM(forPayPeriod: startLeg.payPeriod, pairing: startLeg.pairing)
        ) ?? "--"
        let textColor: Color = isPast ? .gray : dateHeaderTextColor
        HStack(spacing: 8) {
            Text("Trip Id: \(startLeg.pairing)")
                .appScaledFont(.caption2, scale: timelineFontScale)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Text("Credit: \(creditText)")
                .appScaledFont(.caption2, scale: timelineFontScale)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background {
            ZStack {
                tripCardBackground
                if isHighlighted { Color.red.opacity(0.18) }
            }
        }
    }

    private func fallbackCreditHHMM(forPayPeriod payPeriod: String, pairing: String) -> String? {
        let totalMinutes = legData.allLegs
            .filter { $0.pairing == pairing && $0.payPeriod == payPeriod }
            .reduce(0) { partial, leg in partial + Self.parseDurationMinutes(leg.block) }
        guard totalMinutes > 0 else { return nil }
        return "\(totalMinutes / 60):\(String(format: "%02d", totalMinutes % 60))"
    }

    /// Lookup key matching the file format `{depLocalDate}_{pairing}` (upper-cased).
    /// Aligns tripDataByTripID lookups with the payPeriod|pairing granularity of
    /// the calendar selection key.
    /// Returns the tripDataByTripID lookup key for a given leg.
    private static func fileKey(for leg: TripLeg) -> String {
        let datePrefix = String(leg.depLocal.prefix(10))
        return "\(datePrefix)_\(leg.pairing)".uppercased()
    }

    private static func parseDurationMinutes(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2,
              let hh = Int(parts[0]),
              let mm = Int(parts[1]),
              hh >= 0,
              (0...59).contains(mm) else { return 0 }
        return hh * 60 + mm
    }

    private static func formattedDurationLabel(_ hhmm: String?) -> String? {
        guard let hhmm,
              let parts = Optional(hhmm.split(separator: ":")),
              parts.count == 2,
              let hh = Int(parts[0]),
              let mm = Int(parts[1]),
              hh >= 0,
              (0...59).contains(mm) else { return nil }
        return "\(hh)h\(String(format: "%02d", mm))m"
    }

    // MARK: Helpers

    private func timeRangeText(for leg: TripLeg) -> String {
        if selectedClockDisplay == .utc {
            guard let depUTC = LegConnectionTextBuilder.parseUTC(leg.depUTC),
                  let arrUTC = LegConnectionTextBuilder.parseUTC(leg.arrUTC) else {
                return "UTC MISSING"
            }
            return "\(Self.utcTimeFormatter.string(from: depUTC)) - \(Self.utcTimeFormatter.string(from: arrUTC))"
        }
        guard let depUTC = LegConnectionTextBuilder.parseUTC(leg.depUTC),
              let arrUTC = LegConnectionTextBuilder.parseUTC(leg.arrUTC) else {
            return "LCL MISSING"
        }
        guard let depTimeZoneID = IATATimeZoneResolver.shared.resolve(leg.depAirport),
              let arrTimeZoneID = IATATimeZoneResolver.shared.resolve(leg.arrAirport) else {
            return "LCL MISSING"
        }
        return "\(Self.localTimeFormatter(for: depTimeZoneID).string(from: depUTC)) - \(Self.localTimeFormatter(for: arrTimeZoneID).string(from: arrUTC))"
    }

    private func dayShift(for leg: TripLeg) -> Int {
        if selectedClockDisplay == .utc {
            guard let depUTC = LegConnectionTextBuilder.parseUTC(leg.depUTC),
                  let arrUTC = LegConnectionTextBuilder.parseUTC(leg.arrUTC) else {
                return 0
            }
            let depDayKey = SharedDateFormatters.utcDayOnly.string(from: depUTC)
            let arrDayKey = SharedDateFormatters.utcDayOnly.string(from: arrUTC)
            guard let depDay = SharedDateFormatters.utcDayOnly.date(from: depDayKey),
                  let arrDay = SharedDateFormatters.utcDayOnly.date(from: arrDayKey) else {
                return 0
            }
            return Calendar(identifier: .gregorian).dateComponents([.day], from: depDay, to: arrDay).day ?? 0
        }

        guard let depUTC = LegConnectionTextBuilder.parseUTC(leg.depUTC),
              let arrUTC = LegConnectionTextBuilder.parseUTC(leg.arrUTC),
              let depTimeZoneID = IATATimeZoneResolver.shared.resolve(leg.depAirport),
              let arrTimeZoneID = IATATimeZoneResolver.shared.resolve(leg.arrAirport),
              let depDay = SharedDateFormatters.utcDayOnly.date(from: Self.localDayKeyFormatter(for: depTimeZoneID).string(from: depUTC)),
              let arrDay = SharedDateFormatters.utcDayOnly.date(from: Self.localDayKeyFormatter(for: arrTimeZoneID).string(from: arrUTC)) else {
            return 0
        }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: depDay, to: arrDay).day ?? 0
    }

    private func manualOperationalTimeRangeText(for event: ManualOperationalEvent) -> String {
        if selectedClockDisplay == .utc {
            return "\(Self.utcTimeFormatter.string(from: event.startUTC)) - \(Self.utcTimeFormatter.string(from: event.endUTC))"
        }
        let formatter = Self.localTimeFormatter(for: selectedDomicileTimeZone.identifier)
        return "\(formatter.string(from: event.startUTC)) - \(formatter.string(from: event.endUTC))"
    }

    private func manualOperationalDayShift(for event: ManualOperationalEvent) -> Int {
        if selectedClockDisplay == .utc {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            let startDay = calendar.startOfDay(for: event.startUTC)
            let endDay = calendar.startOfDay(for: event.endUTC)
            return calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        }
        let formatter = Self.localDayKeyFormatter(for: selectedDomicileTimeZone.identifier)
        guard let startDay = SharedDateFormatters.utcDayOnly.date(from: formatter.string(from: event.startUTC)),
              let endDay = SharedDateFormatters.utcDayOnly.date(from: formatter.string(from: event.endUTC))
        else {
            return 0
        }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: startDay, to: endDay).day ?? 0
    }

    private static func localTimeFormatter(for tzID: String) -> DateFormatter {
        if let cached = localTimeFormatters[tzID] { return cached }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: tzID)
        formatter.dateFormat = "HH:mm"
        localTimeFormatters[tzID] = formatter
        return formatter
    }

    private static func localDayKeyFormatter(for tzID: String) -> DateFormatter {
        if let cached = localDayKeyFormatters[tzID] { return cached }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: tzID)
        formatter.dateFormat = "yyyy-MM-dd"
        localDayKeyFormatters[tzID] = formatter
        return formatter
    }

    private static var localTimeFormatters: [String: DateFormatter] = [:]
    private static var localDayKeyFormatters: [String: DateFormatter] = [:]

    private static let utcTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func blockConnectionDisplay(for leg: TripLeg) -> BlockConnectionDisplay {
        let display = LegConnectionTextBuilder.blockAndConnectionDisplay(
            for: leg,
            nextLegByID: legData.nextLegByID
        )
        if shouldShowLayover(leg: leg) {
            return display.blockOnly
        }
        return display.mappingConnection {
            $0.replacingOccurrences(of: "Layover at ", with: "LO at ")
                .replacingOccurrences(of: "Layover:", with: "LO:")
        }
    }

    private func arrivalLocalDateLabel(for leg: TripLeg) -> String {
        guard let arrUTC = LegConnectionTextBuilder.parseUTC(leg.arrUTC),
              let tzID = IATATimeZoneResolver.shared.resolve(leg.arrAirport),
              let timeZone = TimeZone(identifier: tzID) else {
            return ""
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, MMM d yyyy"
        return formatter.string(from: arrUTC)
    }

    private func shouldShowLayover(leg: TripLeg) -> Bool {
        let nextLeg = legData.nextLegByID[leg.id]
        return TimelineLayoverSupport.shouldShow(
            arrDate: LegConnectionTextBuilder.parseUTC(leg.arrUTC),
            nextDepDate: nextLeg.flatMap { LegConnectionTextBuilder.parseUTC($0.depUTC) },
            samePairing: nextLeg?.pairing == leg.pairing
        )
    }

    private func isPastLeg(_ leg: TripLeg) -> Bool {
        if shouldShowLayover(leg: leg) {
            return TimelineLayoverSupport.isPastLayover(
                arrDate: LegConnectionTextBuilder.parseUTC(leg.arrUTC),
                nextLeg: legData.nextLegByID[leg.id]
            )
        }
        // INV-001: UTC preferred. Local time used as fallback only when UTC is absent.
        let reference = LegConnectionTextBuilder.parseUTC(leg.arrUTC)
            ?? Self.parseLocalDateTime(leg.arrLocal)
            ?? LegConnectionTextBuilder.parseUTC(leg.depUTC)
            ?? Self.parseLocalDateTime(leg.depLocal)
        return reference.map { $0 < Date() } ?? false
    }

    private func isPastFlightRow(_ leg: TripLeg) -> Bool {
        TimelinePastStateSupport.isPastFlightRow(
            arrivalUTC: LegConnectionTextBuilder.parseUTC(leg.arrUTC),
            departureUTC: LegConnectionTextBuilder.parseUTC(leg.depUTC),
            fallbackArrival: Self.parseLocalDateTime(leg.arrLocal),
            fallbackDeparture: Self.parseLocalDateTime(leg.depLocal)
        )
    }

    private static func parseLocalDateTime(_ text: String) -> Date? {
        localDateTimeFormatter.date(from: text)
    }

    private static let localDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current  // best-effort fallback; UTC preferred via isPastLeg
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// Recomputes legData and all derived caches in one pass.
    /// Call this whenever `crewAccessSchedules` changes or on first appear.
    private func refreshLegData() {
        let schedules = sidebarSchedules
        let data = TimelineLegData(
            schedules: schedules,
            manualOperationalEvents: focusedTripID == nil ? viewModel.manualOperationalEvents : [],
            displayTimeZone: selectedClockDisplay == .utc ? (TimeZone(secondsFromGMT: 0) ?? .gmt) : selectedDomicileTimeZone
        )
        legData = data

        // Pre-compute first leg of each trip (allLegs is already sorted by depLocal).
        var firstLegByTripKey: [String: TripLeg] = [:]
        for leg in data.allLegs {
            let key = "\(leg.payPeriod)|\(leg.pairing)"
            if firstLegByTripKey[key] == nil { firstLegByTripKey[key] = leg }
        }

        // Map every leg to its trip's fileKey (for hotel lookup without per-row O(n) search).
        tripDataKeyByLegID = data.allLegs.reduce(into: [:]) { map, leg in
            let key = "\(leg.payPeriod)|\(leg.pairing)"
            map[leg.id] = firstLegByTripKey[key].map { Self.fileKey(for: $0) }
                ?? Self.fileKey(for: leg)
        }

        // Trip summary must be attached to the actual first chronological leg.
        // Rendering it at the section level moves a late-starting trip above
        // earlier flights that happen to share the same local calendar day.
        let startIDs = TimelineTripStartSupport.startLegIDs(in: data.allLegs)
        cachedTripStartLegIDs = startIDs

        // Pre-compute first row ID per trip (used for scroll + portrait sheet focus).
        var rowMap: [String: String] = [:]
        var summaryMap: [String: String] = [:]
        for section in data.daySections {
            for leg in section.legs {
                let tripID = "\(leg.payPeriod)|\(leg.pairing)"
                if summaryMap[tripID] == nil, startIDs.contains(leg.id) {
                    summaryMap[tripID] = "ipad.tripdata.\(leg.id.uuidString)"
                }
                if rowMap[tripID] == nil {
                    rowMap[tripID] = "\(tripID)|\(leg.leg)|\(leg.id.uuidString)"
                }
            }
        }
        firstRowIDByTripID = rowMap
        firstTripSummaryIDByTripID = summaryMap

    }

    private func refreshTripDataCards() {
        Task.detached(priority: .utility) {
            let result = CrewAccessTripSummaryStore.load()
            await MainActor.run {
                tripDataByTripID = result.byFileKey.merging(result.byTripID) { fileKeyValue, _ in
                    fileKeyValue
                }
            }
        }
    }

    private func refreshFriendScheduleMatches() {
        guard AppEnvironment.isFriendSharingVisible else {
            friendScheduleMatches = .empty
            return
        }
        let mySchedules = sidebarSchedules
        let friendSchedules = viewModel.acceptedFriendConnections.map {
            (gemsID: $0.employeeID, schedules: $0.sharedSchedules)
        }
        friendScheduleMatches = FriendScheduleMatchDetector.detect(
            mySchedules: mySchedules,
            friendSchedules: friendSchedules
        )
    }

    private var friendMatchAmber: Color {
        Color(red: 0.95, green: 0.58, blue: 0.12)
    }

    private func flightMatchPresentation(for leg: TripLeg, matches: [FriendFlightMatch]) -> FriendMatchPresentation {
        FriendMatchPresentation(
            title: "Friends on \(leg.displayFlightNumberText)",
            friends: matches.map { match in
                friendMatchPerson(
                    gemsID: match.friendGEMSID,
                    subtitle: "\(match.departureAirport)-\(match.arrivalAirport)"
                )
            }
        )
    }

    private func restOverlapPresentation(station: String, overlaps: [FriendRestOverlap]) -> FriendMatchPresentation {
        FriendMatchPresentation(
            title: "Friends at \(station)",
            friends: overlaps.map { overlap in
                friendMatchPerson(
                    gemsID: overlap.friendGEMSID,
                    subtitle: "\(durationText(minutes: overlap.overlapMinutes)) overlap"
                )
            }
        )
    }

    private func friendMatchPerson(gemsID: String, subtitle: String) -> FriendMatchPerson {
        let normalized = GEMSIDNormalizer.normalize(gemsID)
        let friend = viewModel.acceptedFriendConnections.first {
            GEMSIDNormalizer.normalize($0.employeeID) == normalized
        }
        return FriendMatchPerson(
            id: normalized,
            displayName: friend?.displayName ?? normalized,
            subtitle: subtitle,
            avatarImageData: friend?.avatarImageData
        )
    }

    private func durationText(minutes: Int) -> String {
        let safeMinutes = max(0, minutes)
        return "\(safeMinutes / 60)h \(safeMinutes % 60)m"
    }

}

/// Reports the focused trip's timeline content height up to the popup so it can
/// size to fit short trips.
fileprivate struct FocusedTimelineContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Screen-centered popup showing a single trip's timeline. Presented when a trip
/// bar is tapped on the calendar (iPhone and iPad portrait). Titled by the Trip Id
/// — deliberately no generic "Timeline" header.
struct CalendarTripTimelinePopup: View {
    @EnvironmentObject private var viewModel: AppViewModel

    /// "payPeriod|pairing" — same identifier the calendar trip bars use.
    let tripID: String
    let onDismiss: () -> Void

    @State private var scrollTrigger = UUID()
    @State private var unusedSelection: String?
    @State private var timelineContentHeight: CGFloat?
    @State private var tripJSONExportOutput: TripJSONExportOutput?
    @State private var tripJSONExportErrorMessage: String?
    @State private var isExportingTripJSON = false

    private static let maxTimelineHeight: CGFloat = 530

    private var tripDisplayID: String {
        tripID.split(separator: "|").last.map(String.init) ?? tripID
    }

    /// Hug short trips; cap (and scroll) long ones.
    private var timelineHeight: CGFloat {
        guard let measured = timelineContentHeight, measured > 0 else {
            return Self.maxTimelineHeight
        }
        return min(max(measured, 120), Self.maxTimelineHeight)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                HStack {
                    Text("Trip Id: \(tripDisplayID)")
                        .font(.system(size: 16, weight: .bold))
                    Spacer()
                    Button {
                        Task { await exportTripJSON() }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(isExportingTripJSON)
                    .accessibilityLabel("Export Trip JSON")
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 21))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()

                IPadTimelineSidebarView(
                    selectedTripID: $unusedSelection,
                    scrollToDefaultTrigger: $scrollTrigger,
                    focusedTripID: tripID
                )
                .environmentObject(viewModel)
                .onPreferenceChange(FocusedTimelineContentHeightKey.self) { height in
                    timelineContentHeight = height
                }
                .frame(height: timelineHeight)
            }
            .frame(maxWidth: 460)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.24), radius: 20, y: 8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
        }
#if canImport(UIKit)
        .sheet(item: $tripJSONExportOutput, onDismiss: removeTripJSONExportFile) { output in
            ActivityView(activityItems: [output.url]) { _ in
                TripJSONExportService.removeTemporaryFiles(for: output)
                tripJSONExportOutput = nil
            }
        }
#endif
        .alert("Unable to Export JSON", isPresented: Binding(
            get: { tripJSONExportErrorMessage != nil },
            set: { if !$0 { tripJSONExportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { tripJSONExportErrorMessage = nil }
        } message: {
            Text(tripJSONExportErrorMessage ?? "The trip could not be exported.")
        }
    }

    @MainActor
    private func exportTripJSON() async {
        guard !isExportingTripJSON else { return }
        guard let schedule = exportSchedule else {
            tripJSONExportErrorMessage = TripJSONExportError.tripDataUnavailable.localizedDescription
            return
        }
        isExportingTripJSON = true
        defer { isExportingTripJSON = false }

        do {
            removeTripJSONExportFile()
            tripJSONExportOutput = try await viewModel.prepareCrewAccessTripJSONExport(for: schedule)
        } catch {
            tripJSONExportErrorMessage = error.localizedDescription
        }
    }

    private var exportSchedule: PayPeriodSchedule? {
        let matchingSchedules = viewModel.crewAccessSchedules.filter { schedule in
            schedule.legs.contains { leg in
                "\(leg.payPeriod)|\(leg.pairing)" == tripID
            }
        }
        let legs = matchingSchedules.flatMap(\.legs).filter {
            "\($0.payPeriod)|\($0.pairing)" == tripID
        }
        guard !legs.isEmpty else { return nil }
        return PayPeriodSchedule(
            id: tripID,
            label: legs[0].payPeriod,
            tripCount: 1,
            legCount: legs.count,
            openTimeCount: 0,
            updatedAt: matchingSchedules.map(\.updatedAt).max() ?? .distantPast,
            legs: legs,
            openTimeTrips: []
        )
    }

    private func removeTripJSONExportFile() {
        guard let output = tripJSONExportOutput else { return }
        TripJSONExportService.removeTemporaryFiles(for: output)
        tripJSONExportOutput = nil
    }
}

#Preview {
    IPadTimelineSidebarView(selectedTripID: .constant(nil), scrollToDefaultTrigger: .constant(UUID()))
        .environmentObject(AppViewModel.shared)
        .frame(width: 420)
}
