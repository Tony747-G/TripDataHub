import SwiftUI

private struct FriendMatchAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct TimelineTabView: View {
    let scrollTrigger: Int
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    @AppStorage("timeline_clock_display") private var timelineClockDisplayRawValue = TimelineClockDisplay.lcl.rawValue
    @AppStorage(OperationalSettings.crewBaseKey) private var crewDomicileRawValue = OperationalSettings.defaultCrewBase.rawValue
    @State private var legData = TimelineLegData(schedules: [])
    @State private var tripDataByTripID: [String: CrewAccessTripSummary] = [:]
    @State private var importedUTCTimesByTripAndSequence: [String: CrewAccessLegUTCTimes] = [:]
    @State private var friendMatchAlert: FriendMatchAlert?
    @State private var friendScheduleMatches: FriendScheduleMatches = .empty
    @State private var deleteTripConfirmPairing: String? = nil
    @State private var showingAddEvent = false
    @State private var selectedManualOperationalEvent: ManualOperationalEvent?
    // Caches updated in refreshLegData() — avoids recomputing expensive values on every body eval.
    @State private var cachedReportWindows: [NextReportTripWindow] = []
    @State private var cachedDaySections: [TimelineDaySection] = []
    @State private var cachedTripBoundaryAfterLegIDs: Set<UUID> = []
    @State private var cachedTripStartLegByBoundaryLegID: [UUID: TripLeg] = [:]
    private static let utcHeaderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd  HH:mm"
        return formatter
    }()

    private static let localDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let utcDayHeaderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, MMM d yyyy"
        return formatter
    }()

    private static let utcTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    // Formatters cached per timezone identifier — avoids mutating shared static state.
    private static var localTimeFormatters: [String: DateFormatter] = [:]
    private static var localDayKeyFormatters: [String: DateFormatter] = [:]
    private static var localHeaderFormatters: [String: DateFormatter] = [:]
    private static var reportTimestampFormatters: [String: DateFormatter] = [:]

    private static func localHeaderFormatter(for tzID: String) -> DateFormatter {
        if let cached = localHeaderFormatters[tzID] { return cached }
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd  HH:mm"
        fmt.timeZone = TimeZone(identifier: tzID)
        localHeaderFormatters[tzID] = fmt
        return fmt
    }

    private static func reportTimestampFormatter(for tzID: String) -> DateFormatter {
        if let cached = reportTimestampFormatters[tzID] { return cached }
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "EEE, MMM d yyyy  HH:mm"
        fmt.timeZone = TimeZone(identifier: tzID)
        reportTimestampFormatters[tzID] = fmt
        return fmt
    }

    private static func localTimeFormatter(for tzID: String) -> DateFormatter {
        if let cached = localTimeFormatters[tzID] { return cached }
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm"
        fmt.timeZone = TimeZone(identifier: tzID)
        localTimeFormatters[tzID] = fmt
        return fmt
    }

    private static func localDayKeyFormatter(for tzID: String) -> DateFormatter {
        if let cached = localDayKeyFormatters[tzID] { return cached }
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: tzID)
        localDayKeyFormatters[tzID] = fmt
        return fmt
    }

    private var selectedClockDisplay: TimelineClockDisplay {
        TimelineClockDisplay(rawValue: timelineClockDisplayRawValue) ?? .lcl
    }

    private var selectedCrewDomicile: CrewBase {
        CrewBase(rawValue: crewDomicileRawValue) ?? OperationalSettings.defaultCrewBase
    }

    private var selectedDomicileTimeZone: TimeZone {
        selectedCrewDomicile.timeZone
    }

    private var currentTimelineSchedules: [PayPeriodSchedule] {
        viewModel.displaySchedules(filter: .crewAccess)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    timelineTopBar
                    importSummaryBanner
                    if shouldShowNextReportCardOnTop {
                        nextReportCard
                    }
                    timelineContent
                    if !shouldShowNextReportCardOnTop {
                        nextReportCard
                    }
                    Color.gray.opacity(0.10)
                        .frame(height: 10)
                }
                addEventButton
            }
            .onAppear {
                viewModel.lastImportSummaryMessage = nil
                refreshLegData()
                refreshTripDataCards()
                refreshFriendScheduleMatches()
            }
            .alert(item: $friendMatchAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
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
            .sheet(isPresented: $showingAddEvent) {
                ManualEventAddSheet()
                    .environmentObject(viewModel)
            }
            .sheet(item: $selectedManualOperationalEvent) { event in
                ManualEventDetailSheet(operationalEvent: event)
                    .environmentObject(viewModel)
            }
        }
    }

    private var addEventButton: some View {
        Button {
            showingAddEvent = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(Color(.tertiarySystemFill))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Event")
        .padding(.trailing, 18)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var timelineContent: some View {
        ScrollViewReader { proxy in
            let connectionMap = legData.nextLegByID
            let tripBoundaryAfterLegs = cachedTripBoundaryAfterLegIDs
            let tripStartLegAfterBoundary = cachedTripStartLegByBoundaryLegID
            ScrollView {
                if cachedDaySections.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(emptyStateTitle)
                            .appScaledFont(.subheadline, weight: .bold, scale: fontScale)

                        Text(emptyStateDescription)
                            .appScaledFont(.footnote, scale: fontScale)
                            .foregroundStyle(.secondary)

                        if let hint = emptyStateHint {
                            Text(hint)
                                .appScaledFont(.footnote, scale: fontScale)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(cachedDaySections) { section in
                            Text(section.label)
                                .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                                .foregroundStyle(section.isPast ? .gray : dateHeaderTextColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 5)
                                .background(dateCardBackground)
                                .id(daySectionScrollID(section.id))
                                .accessibilityIdentifier("timeline.dayHeader.\(section.id)")

                            ForEach(section.entries) { entry in
                                switch entry {
                                case .leg(let leg):
                                    let isHighlighted = deleteTripConfirmPairing == leg.pairing
                                    timelineRow(leg: leg, nextLegByID: connectionMap)
                                        .id("\(leg.id.uuidString)|\(selectedClockDisplay.rawValue)")
                                        .background(isHighlighted ? Color.red.opacity(0.10) : Color.clear)
                                        .simultaneousGesture(
                                            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                                deleteTripConfirmPairing = leg.pairing
                                            }
                                        )
                                    // レイオーバーカード（接続時間 > 3h かつ同一ステーション）
                                    if shouldShowLayover(leg: leg, connectionMap: connectionMap) {
                                        TimelineView(.periodic(from: Date(), by: 60)) { context in
                                            layoverCard(for: leg, connectionMap: connectionMap, now: context.date)
                                        }
                                        .id(layoverScrollID(leg.id))
                                        .background(isHighlighted ? Color.red.opacity(0.10) : Color.clear)
                                        .simultaneousGesture(
                                            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                                deleteTripConfirmPairing = leg.pairing
                                            }
                                        )
                                    }
                                    if tripBoundaryAfterLegs.contains(leg.id) {
                                        if let nextTripStartLeg = tripStartLegAfterBoundary[leg.id] {
                                            let nextHighlighted = deleteTripConfirmPairing == nextTripStartLeg.pairing
                                            tripDataCard(
                                                forTripID: nextTripStartLeg.pairing,
                                                isPast: isPastTrip(nextTripStartLeg.pairing),
                                                isHighlighted: nextHighlighted
                                            )
                                            .id(tripDataScrollID(leg.id))
                                            .simultaneousGesture(
                                                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                                    deleteTripConfirmPairing = nextTripStartLeg.pairing
                                                }
                                            )
                                        } else {
                                            Rectangle()
                                                .fill(isPastLeg(leg, nextLeg: connectionMap[leg.id]) ? Color.gray : dateHeaderTextColor)
                                                .frame(height: 4)
                                        }
                                    } else {
                                        Divider()
                                    }
                                case .manualOperational(let event):
                                    manualOperationalRow(event)
                                        .id("manual-operational.\(event.id.uuidString)|\(selectedClockDisplay.rawValue)")
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectedManualOperationalEvent = event
                                        }
                                        .simultaneousGesture(
                                            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                                selectedManualOperationalEvent = event
                                            }
                                        )
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .onAppear {
                refreshLegData()
                refreshTripDataCards()
                refreshFriendScheduleMatches()
            }
            .onChange(of: viewModel.schedules) { _, _ in
                refreshLegData()
                refreshTripDataCards()
                refreshFriendScheduleMatches()
            }
            .onChange(of: viewModel.manualOperationalEvents) { _, _ in
                refreshLegData()
            }
            .onChange(of: viewModel.friendConnections) { _, _ in
                refreshFriendScheduleMatches()
            }
            .onChange(of: selectedClockDisplay) { _, _ in
                refreshLegData()
            }
            .onChange(of: crewDomicileRawValue) { _, _ in
                refreshLegData()
            }
            .task(id: focusScrollContextKey) {
                await autoScrollToFocusDay(using: proxy)
            }
        }
    }

    private var nextReportCard: some View {
        Group {
            TimelineView(.periodic(from: Date(), by: 60)) { _ in
                if let info = nextReportInfo {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("NEXT REPORT")
                                .appScaledFont(.caption, weight: .bold, scale: fontScale)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text("Trip \(info.pairing)")
                                .appScaledFont(.caption, scale: fontScale)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        HStack {
                            Text(nextReportTimestampText(for: info.reportTime))
                                .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                                .foregroundStyle(dateHeaderTextColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .layoutPriority(1)
                            Spacer()
                            Text(countdownText(to: info.reportTime))
                                .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                                .foregroundStyle(countdownColor(to: info.reportTime))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .layoutPriority(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .accessibilityIdentifier("timeline.nextReportCard")
                } else {
                    EmptyView()
                }
            }
        }
    }

    private func timelineRow(leg: TripLeg, nextLegByID: [UUID: TripLeg]) -> some View {
        let flightMatches = friendScheduleMatches.flightMatchesByLegID[leg.id] ?? []
        let hasFlightMatch = !flightMatches.isEmpty
        return TimelineFlightRow(
            leg: leg,
            isPast: isPastFlightRow(leg),
            fontScale: fontScale,
            timeRangeText: timeRangeText(for: leg),
            dayDiff: dayShift(for: leg),
            blockText: blockAndLayoverText(for: leg, nextLegByID: nextLegByID),
            iconColor: hasFlightMatch ? friendMatchAmber : .primary,
            onIconTap: hasFlightMatch
                ? { friendMatchAlert = flightMatchAlert(for: leg, matches: flightMatches) }
                : nil
        )
    }

    private func manualOperationalRow(_ event: ManualOperationalEvent) -> some View {
        TimelineManualOperationalRow(
            event: event,
            isPast: isPastManualOperationalEvent(event),
            fontScale: fontScale,
            timeRangeText: manualOperationalTimeRangeText(for: event),
            dayDiff: manualOperationalDayShift(for: event)
        )
    }

    /// 到着日付ラベルを生成（"Tue, Apr 28 2026"）- UTC/LCL トグルに連動
    private func arrivalLocalDateLabel(for leg: TripLeg) -> String {
        guard let arrUTC = utcArrivalDate(for: leg) else { return "" }
        if selectedClockDisplay == .utc {
            return Self.utcDayHeaderFormatter.string(from: arrUTC)
        }
        guard let tzID = IATATimeZoneResolver.shared.resolve(leg.arrAirport),
              let tz   = TimeZone(identifier: tzID) else { return "" }
        let fmt = DateFormatter()
        fmt.locale     = Locale(identifier: "en_US")
        fmt.timeZone   = tz
        fmt.dateFormat = "EEE, MMM d yyyy"
        return fmt.string(from: arrUTC)
    }

    /// レイオーバーカードを表示するか: 同トリップの次レグが 3h 超先の場合
    private func shouldShowLayover(leg: TripLeg, connectionMap: [UUID: TripLeg]) -> Bool {
        let next = connectionMap[leg.id]
        return TimelineLayoverSupport.shouldShow(
            arrDate: utcArrivalDate(for: leg),
            nextDepDate: next.flatMap { utcDepartureDate(for: $0) },
            samePairing: next?.pairing == leg.pairing
        )
    }

    @ViewBuilder
    private func layoverCard(for leg: TripLeg, connectionMap: [UUID: TripLeg], now: Date = Date()) -> some View {
        let station = leg.layoverStation ?? leg.arrAirport
        // TripLeg フィールド → JSON hotelDetails の順でフォールバック
        let hotel = leg.layoverHotelName
            ?? tripDataByTripID[leg.pairing]?.hotelByStation[CrewAccessTripSummaryStore.stationKey(station)]
            ?? ""
        let restOverlaps = friendScheduleMatches.restOverlapsByArrivalLegID[leg.id] ?? []
        let hasRestOverlap = !restOverlaps.isEmpty
        let next = connectionMap[leg.id]
        let arrDate = utcArrivalDate(for: leg)
        TimelineLayoverCard(
            station: station,
            hotel: hotel,
            durationText: TimelineLayoverSupport.durationText(
                arrDate: arrDate,
                nextLeg: next,
                fallbackDuration: leg.layoverDuration
            ),
            remainingText: TimelineLayoverSupport.remainingText(arrDate: arrDate, nextLeg: next, now: now),
            arrLocalDateLabel: arrivalLocalDateLabel(for: leg),
            isPast: TimelineLayoverSupport.isPastLayover(arrDate: arrDate, nextLeg: next),
            fontScale: fontScale,
            iconColor: hasRestOverlap ? friendMatchAmber : .primary,
            onIconTap: hasRestOverlap
                ? { friendMatchAlert = restOverlapAlert(station: station, overlaps: restOverlaps) }
                : nil
        )
    }

    private var timelineTopBar: some View {
        ZStack {
            Text("Timeline")
                .appScaledFont(.headline, weight: .semibold, scale: fixedSmallScale)
                .foregroundStyle(.primary)
            HStack {
                Spacer()
                clockDisplayPicker
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.background)
    }

    private var clockDisplayPicker: some View {
        HStack(spacing: 0) {
            Text("LCL")
                .appScaledFont(.caption2, weight: .semibold, scale: fixedSmallScale)
                .foregroundStyle(selectedClockDisplay == .lcl ? clockPickerSelectedTextColor : clockPickerUnselectedTextColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(selectedClockDisplay == .lcl ? clockPickerSelectedBackground : .clear)
                .clipShape(Capsule())
                .onTapGesture { timelineClockDisplayRawValue = TimelineClockDisplay.lcl.rawValue }
            Text(" ")
                .appScaledFont(.caption2, weight: .semibold, scale: fixedSmallScale)
                .foregroundStyle(clockPickerUnselectedTextColor)
                .padding(.horizontal, 0)
            Text("UTC")
                .appScaledFont(.caption2, weight: .semibold, scale: fixedSmallScale)
                .foregroundStyle(selectedClockDisplay == .utc ? clockPickerSelectedTextColor : clockPickerUnselectedTextColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(selectedClockDisplay == .utc ? clockPickerSelectedBackground : .clear)
                .clipShape(Capsule())
                .onTapGesture { timelineClockDisplayRawValue = TimelineClockDisplay.utc.rawValue }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .background(clockPickerContainerBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 999)
                .stroke(clockPickerBorderColor, lineWidth: 1)
        )
        .clipShape(Capsule())
    }

    private var clockPickerSelectedBackground: Color {
        if colorScheme == .dark {
            return clockPickerBrightAccent
        }
        return Color(red: 0.36, green: 0.24, blue: 0.12)
    }

    private var clockPickerSelectedTextColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var clockPickerUnselectedTextColor: Color {
        colorScheme == .dark ? clockPickerBrightAccent : .primary
    }

    private var clockPickerContainerBackground: Color {
        colorScheme == .dark ? clockPickerBrightAccent.opacity(0.24) : Color.black.opacity(0.06)
    }

    private var clockPickerBorderColor: Color {
        colorScheme == .dark ? clockPickerBrightAccent.opacity(0.72) : Color.black.opacity(0.28)
    }

    private var clockPickerBrightAccent: Color {
        Color(red: 0.90, green: 0.76, blue: 0.60)
    }

    @ViewBuilder
    private var importSummaryBanner: some View {
        if let message = viewModel.lastImportSummaryMessage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                Text(message)
                    .appScaledFont(.footnote, scale: fontScale)
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.thinMaterial)
        }
    }

    private var allLegs: [TripLeg] {
        legData.allLegs
    }

    private func layoverScrollID(_ legID: UUID) -> String {
        "timeline.layover.\(legID.uuidString)"
    }

    private func tripDataScrollID(_ boundaryLegID: UUID) -> String {
        "timeline.tripdata.\(boundaryLegID.uuidString)"
    }

    /// Layover中 → Layoverカードへ、Trip先頭（未開始）→ Trip dataカードへ、
    /// それ以外 → フライト行へ、スクロールするためのID。
    private var focusScrollID: String? {
        let now = Date()
        let connectionMap = legData.nextLegByID

        // 1. 現在 Layover 中か判定（到着 ≤ now < duty start）
        for leg in allLegs {
            guard shouldShowLayover(leg: leg, connectionMap: connectionMap),
                  let arr = utcArrivalDate(for: leg),
                  let nextLeg = connectionMap[leg.id]
            else { continue }
            let layoverEnd = TimelineLayoverSupport.restInfo(arrDate: arr, nextLeg: nextLeg)?.dutyStartUTC
                ?? utcDepartureDate(for: nextLeg).map { $0.addingTimeInterval(-90 * 60) }
            guard let end = layoverEnd else { continue }
            if arr <= now && now < end {
                return layoverScrollID(leg.id)
            }
        }

        // 2. 現在飛行中または次のフライト/Tripを探す
        let currentOrNextLeg = allLegs.first { leg in
            guard let dep = utcDepartureDate(for: leg) ?? parseLocalDateTime(leg.depLocal) else {
                return false
            }
            if let arr = utcArrivalDate(for: leg) ?? parseLocalDateTime(leg.arrLocal),
               dep <= now,
               now < arr {
                return true
            }
            return dep >= now
        }
        guard let targetLeg = currentOrNextLeg else { return nil }

        // 3. そのレグがTrip先頭でTripDataカードがある場合はそちらへ
        let tripStartMap = cachedTripStartLegByBoundaryLegID
        if let (boundaryLegID, _) = tripStartMap.first(where: { $0.value.id == targetLeg.id }) {
            return tripDataScrollID(boundaryLegID)
        }

        // 4. フライト行へ
        return "\(targetLeg.id.uuidString)|\(selectedClockDisplay.rawValue)"
    }

    /// Lightweight: selects from pre-built cachedReportWindows using current time.
    private var nextReportInfo: NextReportInfo? {
        let now = Date()
        for window in cachedReportWindows {
            if now < window.reportTime {
                return NextReportInfo(pairing: window.pairing, reportTime: window.reportTime)
            }
            if now >= window.reportTime && now < window.tripEndDomicile {
                return nil
            }
        }
        return nil
    }

    private var hasActiveTripWindow: Bool {
        let now = Date()
        return cachedReportWindows.contains { window in
            now >= window.reportTime && now < window.tripEndDomicile
        }
    }

    private var shouldShowNextReportCardOnTop: Bool {
        nextReportInfo != nil && !hasActiveTripWindow
    }

    private func refreshFriendScheduleMatches() {
        guard AppEnvironment.isTripBoardFetchVisible else {
            friendScheduleMatches = .empty
            return
        }
        let friendSchedules = viewModel.acceptedFriendConnections.map {
            (gemsID: $0.employeeID, schedules: $0.sharedSchedules)
        }
        friendScheduleMatches = FriendScheduleMatchDetector.detect(
            mySchedules: currentTimelineSchedules,
            friendSchedules: friendSchedules
        )
    }

    private func refreshLegData() {
        let schedules = currentTimelineSchedules
        let data = TimelineLegData(schedules: schedules)
        legData = data

        // Cache report windows (expensive build, runs once per schedule change).
        cachedReportWindows = NextReportWindowBuilder.build(
            schedules: schedules,
            domicileAirportCode: selectedCrewDomicile.reportAirportCode,
            domicileTimeZone: selectedDomicileTimeZone
        ).sorted { $0.reportTime < $1.reportTime }

        // Cache day sections (depends on selectedClockDisplay via dayKey).
        cachedDaySections = buildDisplayDaySections(
            from: data.allLegs,
            manualOperationalEvents: viewModel.manualOperationalEvents,
            nextLegByID: data.nextLegByID
        )

        // Cache trip boundaries in one pass over allLegs.
        let legs = data.allLegs
        var boundaryIDs = Set<UUID>()
        var startMap = [UUID: TripLeg]()
        if legs.count > 1 {
            for i in 1..<legs.count {
                let prev = legs[i - 1]; let next = legs[i]
                if isTripBoundary(current: prev, next: next) {
                    boundaryIDs.insert(prev.id)
                    startMap[prev.id] = next
                }
            }
        }
        cachedTripBoundaryAfterLegIDs = boundaryIDs
        cachedTripStartLegByBoundaryLegID = startMap
    }

    private func refreshTripDataCards() {
        Task.detached(priority: .utility) {
            let result = CrewAccessTripSummaryStore.load()
            await MainActor.run {
                tripDataByTripID = result.byTripID
                importedUTCTimesByTripAndSequence = result.legUTCTimesByKey
                // dayKey(for:) uses importedUTCTimesByTripAndSequence — re-cache sections
                // now that UTC import times are available.
                cachedDaySections = buildDisplayDaySections(
                    from: legData.allLegs,
                    manualOperationalEvents: viewModel.manualOperationalEvents,
                    nextLegByID: legData.nextLegByID
                )
            }
        }
    }

    private func daySectionScrollID(_ dayID: String) -> String {
        "timeline.daySection.\(dayID)"
    }

    private var focusScrollContextKey: String {
        let dayIDs = cachedDaySections.map(\.id).joined(separator: "|")
        let focusKey = focusScrollID ?? "none"
        return "\(selectedClockDisplay.rawValue)|\(crewDomicileRawValue)|\(focusKey)|\(dayIDs)|\(scrollTrigger)"
    }

    @MainActor
    private func autoScrollToFocusDay(using proxy: ScrollViewProxy) async {
        guard let scrollID = focusScrollID else {
            return
        }
        // Immediate attempt before LazyVStack may have laid out off-screen cells.
        proxy.scrollTo(scrollID, anchor: .top)
        // Retry with increasing delays to handle lazy rendering timing.
        let delays: [UInt64] = [100_000_000, 200_000_000, 400_000_000]
        for delay in delays {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(scrollID, anchor: .top)
            }
        }
    }

    private func nextReportTimestampText(for reportTime: Date) -> String {
        "\(Self.reportTimestampFormatter(for: selectedDomicileTimeZone.identifier).string(from: reportTime)) \(selectedCrewDomicile.displayName)"
    }

    private func localHeaderTimeText() -> String {
        Self.localHeaderFormatter(for: selectedDomicileTimeZone.identifier).string(from: Date())
    }

    private func utcHeaderTimeText() -> String {
        Self.utcHeaderFormatter.string(from: Date())
    }

    private func selectedHeaderTimeText() -> String {
        switch selectedClockDisplay {
        case .lcl:
            return localHeaderTimeText()
        case .utc:
            return utcHeaderTimeText()
        }
    }

    private func timeRangeText(for leg: TripLeg) -> String {
        if selectedClockDisplay == .utc {
            guard let depUTC = utcDepartureDate(for: leg),
                  let arrUTC = utcArrivalDate(for: leg) else {
                return "UTC MISSING"
            }
            return "\(Self.utcTimeFormatter.string(from: depUTC)) - \(Self.utcTimeFormatter.string(from: arrUTC))"
        }
        guard let depLocalText = localTimeText(fromUTC: utcDepartureDate(for: leg), airport: leg.depAirport),
              let arrLocalText = localTimeText(fromUTC: utcArrivalDate(for: leg), airport: leg.arrAirport)
        else {
            return "LCL MISSING"
        }
        return "\(depLocalText) - \(arrLocalText)"
    }

    private func dayShift(from depText: String, to arrText: String) -> Int {
        ScheduleDateText.dayShift(from: depText, to: arrText)
    }

    private func dayShift(for leg: TripLeg) -> Int {
        if selectedClockDisplay == .utc {
            guard let depUTC = utcDepartureDate(for: leg),
                  let arrUTC = utcArrivalDate(for: leg) else {
                return 0
            }
            let depDayKey = SharedDateFormatters.utcDayOnly.string(from: depUTC)
            let arrDayKey = SharedDateFormatters.utcDayOnly.string(from: arrUTC)
            guard let depDay = SharedDateFormatters.utcDayOnly.date(from: depDayKey),
                  let arrDay = SharedDateFormatters.utcDayOnly.date(from: arrDayKey)
            else {
                return 0
            }
            return Calendar(identifier: .gregorian).dateComponents([.day], from: depDay, to: arrDay).day ?? 0
        }
        guard let depKey = localDayKey(fromUTC: utcDepartureDate(for: leg), airport: leg.depAirport),
              let arrKey = localDayKey(fromUTC: utcArrivalDate(for: leg), airport: leg.arrAirport),
              let depDay = SharedDateFormatters.utcDayOnly.date(from: depKey),
              let arrDay = SharedDateFormatters.utcDayOnly.date(from: arrKey)
        else {
            return 0
        }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: depDay, to: arrDay).day ?? 0
    }

    private func countdownText(to target: Date) -> String {
        let deltaSeconds = Int(target.timeIntervalSince(Date()))
        let sign = deltaSeconds >= 0 ? "-" : "+"
        let absMinutes = abs(deltaSeconds) / 60
        let days = absMinutes / (24 * 60)
        let hours = (absMinutes % (24 * 60)) / 60
        let minutes = absMinutes % 60
        if days == 0 {
            return "(\(sign)\(String(format: "%02d", hours))h \(String(format: "%02d", minutes))m)"
        }
        return "(\(sign)\(String(format: "%02d", days))d \(String(format: "%02d", hours))h \(String(format: "%02d", minutes))m)"
    }

    private func countdownColor(to target: Date) -> Color {
        let remainingSeconds = target.timeIntervalSince(Date())
        let remainingHours = remainingSeconds / 3600.0

        if remainingHours <= 12 {
            if colorScheme == .light {
                return Color(red: 0.68, green: 0.08, blue: 0.08)
            }
            return .red
        }
        if remainingHours <= 24 {
            if colorScheme == .light {
                return Color(red: 0.72, green: 0.34, blue: 0.00)
            }
            return .orange
        }
        if remainingHours <= 48 {
            if colorScheme == .light {
                return Color(red: 0.72, green: 0.52, blue: 0.00)
            }
            return .yellow
        }
        return dateHeaderTextColor
    }

    private func isPastLeg(_ leg: TripLeg, nextLeg: TripLeg? = nil) -> Bool {
        if shouldShowLayover(leg: leg, connectionMap: nextLeg.map { [leg.id: $0] } ?? [:]) {
            return TimelineLayoverSupport.isPastLayover(
                arrDate: utcArrivalDate(for: leg),
                nextLeg: nextLeg
            )
        }
        let reference = utcArrivalDate(for: leg)
            ?? parseLocalDateTime(leg.arrLocal)
            ?? utcDepartureDate(for: leg)
            ?? parseLocalDateTime(leg.depLocal)
        guard let reference else { return false }
        return reference < Date()
    }

    private func isPastFlightRow(_ leg: TripLeg) -> Bool {
        TimelinePastStateSupport.isPastFlightRow(
            arrivalUTC: utcArrivalDate(for: leg),
            departureUTC: utcDepartureDate(for: leg),
            fallbackArrival: parseLocalDateTime(leg.arrLocal),
            fallbackDeparture: parseLocalDateTime(leg.depLocal)
        )
    }

    private func isPastManualOperationalEvent(_ event: ManualOperationalEvent) -> Bool {
        event.endUTC < Date()
    }

    private func isPastTrip(_ tripID: String) -> Bool {
        let tripLegs = allLegs.filter { $0.pairing == tripID }
        guard !tripLegs.isEmpty else { return false }
        let endTimes: [Date] = tripLegs.compactMap { leg in
            utcArrivalDate(for: leg) ?? parseLocalDateTime(leg.arrLocal)
        }
        guard let tripEnd = endTimes.max() else { return false }
        return tripEnd < Date()
    }

    private func parseLocalDateTime(_ text: String) -> Date? {
        Self.localDateTimeFormatter.date(from: text)
    }

    private var dateCardBackground: Color {
        ScheduleColors.dayHeaderBackground(for: colorScheme)
    }

    private var tripCardBackground: Color {
        if colorScheme == .light {
            return Color(red: 0.82, green: 0.82, blue: 0.84)
        }
        return Color(red: 0.16, green: 0.16, blue: 0.18)
    }

    private func buildDisplayDaySections(
        from legs: [TripLeg],
        manualOperationalEvents: [ManualOperationalEvent],
        nextLegByID: [UUID: TripLeg]
    ) -> [TimelineDaySection] {
        var order: [String] = []
        var grouped: [String: [TimelineDutyEntry]] = [:]
        let entries = (
            legs.map { TimelineDutyEntry.leg($0) }
                + manualOperationalEvents.map { TimelineDutyEntry.manualOperational($0) }
        )
        .sorted { lhs, rhs in
            let lhsStart = lhs.startUTC ?? .distantFuture
            let rhsStart = rhs.startUTC ?? .distantFuture
            if lhsStart == rhsStart { return lhs.id < rhs.id }
            return lhsStart < rhsStart
        }

        for entry in entries {
            let key = dayKey(for: entry)
            if grouped[key] == nil {
                grouped[key] = []
                order.append(key)
            }
            grouped[key]?.append(entry)
        }

        return order.map { key in
            let sectionEntries = grouped[key] ?? []
            let sectionLegs = sectionEntries.compactMap(\.leg)
            let isPast = !sectionEntries.isEmpty && sectionEntries.allSatisfy { entry in
                switch entry {
                case .leg(let leg):
                    return isPastLeg(leg, nextLeg: nextLegByID[leg.id])
                case .manualOperational(let event):
                    return isPastManualOperationalEvent(event)
                }
            }
            return TimelineDaySection(
                id: key,
                label: dayHeaderLabel(from: key),
                isPast: isPast,
                legs: sectionLegs,
                entries: sectionEntries
            )
        }
    }

    private func dayKey(for entry: TimelineDutyEntry) -> String {
        switch entry {
        case .leg(let leg):
            return dayKey(for: leg)
        case .manualOperational(let event):
            return manualOperationalDayKey(for: event)
        }
    }

    private func dayKey(for leg: TripLeg) -> String {
        if selectedClockDisplay == .utc,
           let depUTC = utcDepartureDate(for: leg) {
            return SharedDateFormatters.utcDayOnly.string(from: depUTC)
        }
        if let depKey = localDayKey(fromUTC: utcDepartureDate(for: leg), airport: leg.depAirport) {
            return depKey
        }
        return ScheduleDateText.datePart(from: leg.depLocal)
    }

    private func utcDepartureDate(for leg: TripLeg) -> Date? {
        let key = CrewAccessTripSummaryStore.legUTCKey(tripID: leg.pairing, sequence: leg.leg)
        if let fromImport = importedUTCTimesByTripAndSequence[key]?.startUtc,
           let parsedImport = LegConnectionTextBuilder.parseUTC(fromImport) {
            return parsedImport
        }
        if let parsed = LegConnectionTextBuilder.parseUTC(leg.depUTC) {
            return parsed
        }
        return nil
    }

    private func utcArrivalDate(for leg: TripLeg) -> Date? {
        let key = CrewAccessTripSummaryStore.legUTCKey(tripID: leg.pairing, sequence: leg.leg)
        if let fromImport = importedUTCTimesByTripAndSequence[key]?.endUtc,
           let parsedImport = LegConnectionTextBuilder.parseUTC(fromImport) {
            return parsedImport
        }
        if let parsed = LegConnectionTextBuilder.parseUTC(leg.arrUTC) {
            return parsed
        }
        return nil
    }

    private func localTimeText(fromUTC utcDate: Date?, airport: String) -> String? {
        guard let utcDate,
              let tzID = IATATimeZoneResolver.shared.resolve(airport)
        else { return nil }
        return Self.localTimeFormatter(for: tzID).string(from: utcDate)
    }

    private func localDayKey(fromUTC utcDate: Date?, airport: String) -> String? {
        guard let utcDate,
              let tzID = IATATimeZoneResolver.shared.resolve(airport)
        else { return nil }
        return Self.localDayKeyFormatter(for: tzID).string(from: utcDate)
    }

    private func manualOperationalTimeRangeText(for event: ManualOperationalEvent) -> String {
        if selectedClockDisplay == .utc {
            return "\(Self.utcTimeFormatter.string(from: event.startUTC)) - \(Self.utcTimeFormatter.string(from: event.endUTC))"
        }
        let formatter = Self.localTimeFormatter(for: selectedDomicileTimeZone.identifier)
        return "\(formatter.string(from: event.startUTC)) - \(formatter.string(from: event.endUTC))"
    }

    private func manualOperationalDayKey(for event: ManualOperationalEvent) -> String {
        if selectedClockDisplay == .utc {
            return SharedDateFormatters.utcDayOnly.string(from: event.startUTC)
        }
        return Self.localDayKeyFormatter(for: selectedDomicileTimeZone.identifier).string(from: event.startUTC)
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

    private func dayDate(from key: String) -> Date? {
        if selectedClockDisplay == .utc {
            return SharedDateFormatters.utcDayOnly.date(from: key)
        }
        return SharedDateFormatters.localDayInput.date(from: key)
    }

    private func dayHeaderLabel(from key: String) -> String {
        if selectedClockDisplay == .utc,
           let date = SharedDateFormatters.utcDayOnly.date(from: key) {
            return Self.utcDayHeaderFormatter.string(from: date)
        }
        return ScheduleDateText.dayHeaderLabel(from: key)
    }

    private var dateHeaderTextColor: Color {
        ScheduleColors.timelineDateHeaderText(for: colorScheme)
    }

    private var friendMatchAmber: Color {
        Color(red: 0.95, green: 0.58, blue: 0.12)
    }

    private func flightMatchAlert(for leg: TripLeg, matches: [FriendFlightMatch]) -> FriendMatchAlert {
        let title = "Friends on \(leg.displayFlightNumberText)"
        let lines = matches.map { match in
            "GEMS \(match.friendGEMSID): \(match.departureAirport)-\(match.arrivalAirport)"
        }
        return FriendMatchAlert(
            title: title,
            message: lines.joined(separator: "\n")
        )
    }

    private func restOverlapAlert(station: String, overlaps: [FriendRestOverlap]) -> FriendMatchAlert {
        let title = "Friends at \(station)"
        let lines = overlaps.map { overlap in
            "GEMS \(overlap.friendGEMSID): \(durationText(minutes: overlap.overlapMinutes)) overlap"
        }
        return FriendMatchAlert(
            title: title,
            message: lines.joined(separator: "\n")
        )
    }

    private func durationText(minutes: Int) -> String {
        let safeMinutes = max(0, minutes)
        return "\(safeMinutes / 60)h \(safeMinutes % 60)m"
    }

    private func blockAndLayoverText(for leg: TripLeg, nextLegByID: [UUID: TripLeg]) -> String {
        let text = LegConnectionTextBuilder.blockAndConnectionText(for: leg, nextLegByID: nextLegByID)
        // レイオーバーカードを表示する場合は " / LO at ..." 部分を削除して Block のみ残す
        if shouldShowLayover(leg: leg, connectionMap: nextLegByID),
           let slashRange = text.range(of: " / ") {
            return String(text[..<slashRange.lowerBound])
        }
        return text
            .replacingOccurrences(of: "Layover at ", with: "LO at ")
            .replacingOccurrences(of: "Layover:", with: "LO:")
    }

    private func isTripBoundary(current: TripLeg, next: TripLeg) -> Bool {
        if next.leg == 1 { return true }
        if current.payPeriod != next.payPeriod { return true }
        if current.pairing != next.pairing { return true }
        return false
    }

    @ViewBuilder
    private func tripDataCard(forTripID tripID: String, isPast: Bool, isHighlighted: Bool = false) -> some View {
        let summary = tripDataByTripID[tripID]
        let creditText = formattedDurationLabel(summary?.creditTime ?? fallbackCreditHHMM(forTripID: tripID)) ?? "--"
        let tripCardTextColor: Color = isPast ? .gray : dateHeaderTextColor
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("Trip Id: \(tripID)")
                    .appScaledFont(.caption, scale: fontScale)
                    .foregroundStyle(tripCardTextColor)
                Spacer()
                Text("Credit: \(creditText)")
                    .appScaledFont(.caption, scale: fontScale)
                    .foregroundStyle(tripCardTextColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background {
            ZStack {
                tripCardBackground
                if isHighlighted { Color.red.opacity(0.18) }
            }
        }
    }

    private func fallbackCreditHHMM(forTripID tripID: String) -> String? {
        let tripLegs = allLegs.filter { $0.pairing == tripID }
        guard !tripLegs.isEmpty else { return nil }
        let totalMinutes = tripLegs.reduce(0) { partial, leg in
            partial + parseDurationMinutes(leg.block)
        }
        guard totalMinutes > 0 else { return nil }
        return "\(totalMinutes / 60):\(String(format: "%02d", totalMinutes % 60))"
    }

    private func parseDurationMinutes(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2,
              let hh = Int(parts[0]),
              let mm = Int(parts[1]),
              hh >= 0,
              (0...59).contains(mm)
        else {
            return 0
        }
        return hh * 60 + mm
    }

    private func formattedDurationLabel(_ hhmm: String?) -> String? {
        guard let hhmm = hhmm else { return nil }
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let hh = Int(parts[0]),
              let mm = Int(parts[1]),
              hh >= 0,
              (0...59).contains(mm)
        else {
            return nil
        }
        return "\(hh)h\(String(format: "%02d", mm))m"
    }

    private var fontScale: CGFloat {
        let option = AppFontSizeOption(rawValue: appFontSizeOptionRawValue) ?? .medium
        return option.scaleFactor
    }

    private var fixedSmallScale: CGFloat {
        AppFontSizeOption.small.scaleFactor
    }

    private var emptyStateTitle: String {
        "No CrewAccess schedule yet"
    }

    private var emptyStateDescription: String {
        "Import a CrewAccess PDF to view your official schedule."
    }

    private var emptyStateHint: String? {
        "Go to Settings -> CrewAccess Import. Export using CrewAccess Print as a text-selectable PDF."
    }
}

private struct NextReportInfo {
    let pairing: String
    let reportTime: Date
}

enum TimelineClockDisplay: String {
    case lcl
    case utc
}
