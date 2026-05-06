import SwiftUI

private struct FriendMatchAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct TimelineTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    @AppStorage("timeline_clock_display") private var timelineClockDisplayRawValue = TimelineClockDisplay.lcl.rawValue
    private let anchorageTimeZone = TimeZone(identifier: "America/Anchorage")
        ?? TimeZone(secondsFromGMT: NextReportWindowBuilder.anchorageFallbackOffsetSeconds)!
    private let tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared
    @State private var legData = TimelineLegData(schedules: [])
    @State private var tripDataByTripID: [String: TripDataCardInfo] = [:]
    @State private var importedUTCTimesByTripAndSequence: [String: ImportLegUTCTimes] = [:]
    @State private var friendMatchAlert: FriendMatchAlert?
    @State private var friendScheduleMatches: FriendScheduleMatches = .empty
    private static let nextReportTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(identifier: "America/Anchorage")
            ?? TimeZone(secondsFromGMT: NextReportWindowBuilder.anchorageFallbackOffsetSeconds)!
        formatter.dateFormat = "EEE, MMM d yyyy  HH:mm"
        return formatter
    }()

    private static let localHeaderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd  HH:mm"
        return formatter
    }()

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

    private var currentTimelineSchedules: [PayPeriodSchedule] {
        viewModel.displaySchedules(filter: .crewAccess)
    }

    var body: some View {
        NavigationStack {
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
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        ScrollViewReader { proxy in
            let connectionMap = legData.nextLegByID
            let tripBoundaryAfterLegs = tripBoundaryAfterLegIDs
            let tripStartLegAfterBoundary = tripStartLegByBoundaryLegID
            ScrollView {
                if daySections.isEmpty {
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
                        ForEach(daySections) { section in
                            Text(section.label)
                                .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                                .foregroundStyle(section.isPast ? .gray : dateHeaderTextColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 5)
                                .background(dateCardBackground)
                                .id(daySectionScrollID(section.id))
                                .accessibilityIdentifier("timeline.dayHeader.\(section.id)")

                            let legs = section.legs
                            ForEach(Array(legs.enumerated()), id: \.element.id) { _, leg in
                                timelineRow(leg: leg, nextLegByID: connectionMap)
                                    .id("\(leg.id.uuidString)|\(selectedClockDisplay.rawValue)")
                                // レイオーバーカード（接続時間 > 3h かつ同一ステーション）
                                if shouldShowLayover(leg: leg, connectionMap: connectionMap) {
                                    layoverCard(for: leg, connectionMap: connectionMap)
                                }
                                if tripBoundaryAfterLegs.contains(leg.id) {
                                    if let nextTripStartLeg = tripStartLegAfterBoundary[leg.id] {
                                        tripDataCard(
                                            forTripID: nextTripStartLeg.pairing,
                                            isPast: isPastTrip(nextTripStartLeg.pairing)
                                        )
                                    } else {
                                        Rectangle()
                                            .fill(isPastLeg(leg) ? Color.gray : dateHeaderTextColor)
                                            .frame(height: 4)
                                    }
                                } else {
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
            .onChange(of: viewModel.friendConnections) { _, _ in
                refreshFriendScheduleMatches()
            }
            .onChange(of: selectedClockDisplay) { _, _ in
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
                            Text("Trip \(info.pairing)")
                                .appScaledFont(.caption, scale: fontScale)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(nextReportTimestampText(for: info.reportTime))
                                .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                                .foregroundStyle(dateHeaderTextColor)
                            Spacer()
                            Text(countdownText(to: info.reportTime))
                                .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                                .foregroundStyle(countdownColor(to: info.reportTime))
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
            isPast: isPastLeg(leg),
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

    /// 到着日付ラベルを生成（"Tue, Apr 28 2026"）- UTC/LCL トグルに連動
    private func arrivalLocalDateLabel(for leg: TripLeg) -> String {
        guard let arrUTC = utcArrivalDate(for: leg) else { return "" }
        if selectedClockDisplay == .utc {
            return Self.utcDayHeaderFormatter.string(from: arrUTC)
        }
        guard let tzID = tzResolver.resolve(leg.arrAirport),
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
    private func layoverCard(for leg: TripLeg, connectionMap: [UUID: TripLeg]) -> some View {
        let station = leg.layoverStation ?? leg.arrAirport
        // TripLeg フィールド → JSON hotelDetails の順でフォールバック
        let hotel = leg.layoverHotelName
            ?? tripDataByTripID[leg.pairing]?.hotelByStation[station]
            ?? ""
        let restOverlaps = friendScheduleMatches.restOverlapsByArrivalLegID[leg.id] ?? []
        let hasRestOverlap = !restOverlaps.isEmpty
        let next = connectionMap[leg.id]
        TimelineLayoverCard(
            station: station,
            hotel: hotel,
            durationText: TimelineLayoverSupport.durationText(
                arrDate: utcArrivalDate(for: leg),
                nextDepDate: next.flatMap { utcDepartureDate(for: $0) },
                fallbackDuration: leg.layoverDuration
            ),
            arrLocalDateLabel: arrivalLocalDateLabel(for: leg),
            isPast: isPastLeg(leg),
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

    private var focusDayID: String? {
        let now = Date()

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

        guard let currentOrNextLeg else { return nil }
        return dayKey(for: currentOrNextLeg)
    }

    private var nextReportInfo: NextReportInfo? {
        let nowANC = nowInAnchorage()
        let windows = tripWindows.sorted { $0.reportTime < $1.reportTime }

        for window in windows {
            if nowANC < window.reportTime {
                return NextReportInfo(
                    pairing: window.pairing,
                    reportTime: window.reportTime
                )
            }

            if nowANC >= window.reportTime && nowANC < window.tripEndANC {
                return nil
            }
        }

        return nil
    }

    private var hasActiveTripWindow: Bool {
        let nowANC = nowInAnchorage()
        return tripWindows.contains { window in
            nowANC >= window.reportTime && nowANC < window.tripEndANC
        }
    }

    private var shouldShowNextReportCardOnTop: Bool {
        nextReportInfo != nil && !hasActiveTripWindow
    }

    private var tripWindows: [NextReportTripWindow] {
        NextReportWindowBuilder.build(schedules: currentTimelineSchedules, anchorageTimeZone: anchorageTimeZone)
    }

    private var daySections: [TimelineDaySection] {
        buildDisplayDaySections(from: allLegs)
    }

    private func refreshFriendScheduleMatches() {
        let friendSchedules = viewModel.acceptedFriendConnections.map {
            (gemsID: $0.employeeID, schedules: $0.sharedSchedules)
        }
        friendScheduleMatches = FriendScheduleMatchDetector.detect(
            mySchedules: currentTimelineSchedules,
            friendSchedules: friendSchedules
        )
    }

    private func refreshLegData() {
        legData = TimelineLegData(schedules: currentTimelineSchedules)
        NSLog("[Timeline] schedules=%d legs=%d", currentTimelineSchedules.count, legData.allLegs.count)
        let deviceTZ = TimeZone.current.identifier
        for leg in legData.allLegs {
            NSLog(
                "[Timeline] leg pairing=%@ leg=%d depUTC=%@ depLocal=%@ arrUTC=%@ arrLocal=%@ deviceTZ=%@",
                leg.pairing,
                leg.leg,
                leg.depUTC ?? "nil",
                leg.depLocal,
                leg.arrUTC ?? "nil",
                leg.arrLocal,
                deviceTZ
            )
        }
    }

    private func refreshTripDataCards() {
        Task.detached(priority: .utility) {
            let result = Self.loadTripDataFromCrewAccessImports()
            await MainActor.run {
                tripDataByTripID = result.summaryByTripID
                importedUTCTimesByTripAndSequence = result.utcByTripAndSequence
            }
        }
    }

    private func daySectionScrollID(_ dayID: String) -> String {
        "timeline.daySection.\(dayID)"
    }

    private var focusScrollContextKey: String {
        let dayIDs = daySections.map(\.id).joined(separator: "|")
        let focusKey = focusDayID ?? "none"
        return "\(selectedClockDisplay.rawValue)|\(focusKey)|\(dayIDs)"
    }

    @MainActor
    private func autoScrollToFocusDay(using proxy: ScrollViewProxy) async {
        guard let focusDayID else {
            return
        }

        let scrollID = daySectionScrollID(focusDayID)
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(scrollID, anchor: .top)
            }
        }
    }

    private func nextReportTimestampText(for reportTime: Date) -> String {
        "\(Self.nextReportTimestampFormatter.string(from: reportTime)) ANC"
    }

    private func localHeaderTimeText() -> String {
        Self.localHeaderFormatter.string(from: Date())
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
        let deltaSeconds = Int(target.timeIntervalSince(nowInAnchorage()))
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
        let remainingSeconds = target.timeIntervalSince(nowInAnchorage())
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

    private func isPastLeg(_ leg: TripLeg) -> Bool {
        let reference = utcArrivalDate(for: leg)
            ?? parseLocalDateTime(leg.arrLocal)
            ?? utcDepartureDate(for: leg)
            ?? parseLocalDateTime(leg.depLocal)
        guard let reference else { return false }
        return reference < Date()
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

    private func nowInAnchorage() -> Date {
        Date()
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

    private func buildDisplayDaySections(from legs: [TripLeg]) -> [TimelineDaySection] {
        var order: [String] = []
        var grouped: [String: [TripLeg]] = [:]
        for leg in legs {
            let key = dayKey(for: leg)
            if grouped[key] == nil {
                grouped[key] = []
                order.append(key)
            }
            grouped[key]?.append(leg)
        }

        return order.map { key in
            let sectionLegs = grouped[key] ?? []
            let isPast = !sectionLegs.isEmpty && sectionLegs.allSatisfy { isPastLeg($0) }
            return TimelineDaySection(
                id: key,
                label: dayHeaderLabel(from: key),
                isPast: isPast,
                legs: sectionLegs
            )
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
        let key = tripSequenceKey(tripID: leg.pairing, sequence: leg.leg)
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
        let key = tripSequenceKey(tripID: leg.pairing, sequence: leg.leg)
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
              let tzID = tzResolver.resolve(airport)
        else { return nil }
        return Self.localTimeFormatter(for: tzID).string(from: utcDate)
    }

    private func localDayKey(fromUTC utcDate: Date?, airport: String) -> String? {
        guard let utcDate,
              let tzID = tzResolver.resolve(airport)
        else { return nil }
        return Self.localDayKeyFormatter(for: tzID).string(from: utcDate)
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

    private var tripBoundaryAfterLegIDs: Set<UUID> {
        let legs = allLegs
        guard legs.count > 1 else { return [] }
        var ids: Set<UUID> = []
        for index in 1..<legs.count {
            if isTripBoundary(current: legs[index - 1], next: legs[index]) {
                ids.insert(legs[index - 1].id)
            }
        }
        return ids
    }

    private var tripStartLegByBoundaryLegID: [UUID: TripLeg] {
        let legs = allLegs
        guard legs.count > 1 else { return [:] }
        var map: [UUID: TripLeg] = [:]
        for index in 1..<legs.count {
            let previous = legs[index - 1]
            let next = legs[index]
            if isTripBoundary(current: previous, next: next) {
                map[previous.id] = next
            }
        }
        return map
    }

    @ViewBuilder
    private func tripDataCard(forTripID tripID: String, isPast: Bool) -> some View {
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
        .background(tripCardBackground)
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

    private nonisolated static func loadTripDataFromCrewAccessImports() -> (
        summaryByTripID: [String: TripDataCardInfo],
        utcByTripAndSequence: [String: ImportLegUTCTimes]
    ) {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return ([:], [:])
        }
        let dir = documents.appendingPathComponent("CrewAccessImports", isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return ([:], [:]) }

        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return ([:], [:])
        }

        var latestFileByTripID: [String: (date: Date, url: URL)] = [:]

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  url.pathExtension.lowercased() == "json"
            else {
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(CrewAccessTripSummaryCardJSON.self, from: data)
            else {
                continue
            }
            let tripID = decoded.tripId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tripID.isEmpty else { continue }
            let modifiedAt = values.contentModificationDate ?? .distantPast
            let current = latestFileByTripID[tripID]
            if current.map({ modifiedAt > $0.date }) ?? true {
                latestFileByTripID[tripID] = (modifiedAt, url)
            }
        }

        var summaryByTripID: [String: TripDataCardInfo] = [:]
        var utcByTripAndSequence: [String: ImportLegUTCTimes] = [:]
        for (tripID, (_, url)) in latestFileByTripID {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(CrewAccessTripSummaryCardJSON.self, from: data)
            else {
                continue
            }
            var hotelByStation: [String: String] = [:]
            for detail in decoded.hotelDetails {
                let (st, name) = CrewAccessTripSummaryCardJSON.parseHotelDetail(detail)
                if !st.isEmpty && !name.isEmpty { hotelByStation[st] = name }
            }
            let legacyHotelDetails = decoded.hotelDetails.filter { $0.hasPrefix("Hotel details ") }
            if !legacyHotelDetails.isEmpty {
                var legacyHotelIndex = 0
                let sortedItems = decoded.items.sorted { $0.sequence < $1.sequence }
                for index in sortedItems.indices.dropLast() {
                    guard legacyHotelIndex < legacyHotelDetails.count else { break }
                    let item = sortedItems[index]
                    let next = sortedItems[index + 1]
                    guard let endDate = LegConnectionTextBuilder.parseUTC(item.endUtc),
                          let nextStartDate = LegConnectionTextBuilder.parseUTC(next.startUtc),
                          nextStartDate.timeIntervalSince(endDate) >= 180 * 60 else {
                        continue
                    }
                    let station = item.arrAirport.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !station.isEmpty, hotelByStation[station] == nil else {
                        legacyHotelIndex += 1
                        continue
                    }
                    let (_, name) = CrewAccessTripSummaryCardJSON.parseHotelDetail(legacyHotelDetails[legacyHotelIndex])
                    if !name.isEmpty { hotelByStation[station] = name }
                    legacyHotelIndex += 1
                }
            }
            summaryByTripID[tripID] = TripDataCardInfo(
                creditTime: decoded.creditTime,
                tripDays: decoded.tripDays,
                tafb: decoded.tafb,
                hotelByStation: hotelByStation
            )
            for item in decoded.items {
                let key = tripSequenceKey(tripID: tripID, sequence: item.sequence)
                utcByTripAndSequence[key] = ImportLegUTCTimes(startUtc: item.startUtc, endUtc: item.endUtc)
            }
        }

        return (summaryByTripID, utcByTripAndSequence)
    }

    private nonisolated static func tripSequenceKey(tripID: String, sequence: Int) -> String {
        "\(tripID)|\(sequence)"
    }

    private func tripSequenceKey(tripID: String, sequence: Int) -> String {
        Self.tripSequenceKey(tripID: tripID, sequence: sequence)
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

private struct TripDataCardInfo {
    let creditTime: String?
    let tripDays: String?
    let tafb: String?
    let hotelByStation: [String: String]   // station → hotel name（JSON fallback）
}

private struct CrewAccessTripSummaryCardJSON: Decodable {
    let tripId: String
    let creditTime: String?
    let tripDays: String?
    let tafb: String?
    let hotelDetails: [String]
    let items: [CrewAccessTripSummaryCardItemJSON]

    private enum CodingKeys: String, CodingKey {
        case tripId
        case creditTime
        case tripDays
        case tafb
        case hotelDetails
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tripId       = try container.decode(String.self, forKey: .tripId)
        creditTime   = try container.decodeIfPresent(String.self, forKey: .creditTime)
        tripDays     = try container.decodeIfPresent(String.self, forKey: .tripDays)
        tafb         = try container.decodeIfPresent(String.self, forKey: .tafb)
        hotelDetails = try container.decodeIfPresent([String].self, forKey: .hotelDetails) ?? []
        items        = try container.decodeIfPresent([CrewAccessTripSummaryCardItemJSON].self, forKey: .items) ?? []
    }

    /// "SGN: Caravelle Hotel +84-28-3823-4999 (15:30)" → (station:"SGN", hotel:"Caravelle Hotel")
    static func parseHotelDetail(_ detail: String) -> (station: String, hotelName: String) {
        if detail.hasPrefix("Hotel details ") {
            return parseLegacyHotelDetail(detail)
        }

        guard let colonRange = detail.range(of: ": ") else {
            return (detail.trimmingCharacters(in: .whitespaces), "")
        }
        let station = String(detail[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        var rest    = String(detail[colonRange.upperBound...])
        // 末尾の "(HH:MM)" を除去
        if let parenRange = rest.range(of: " (", options: .backwards) {
            rest = String(rest[..<parenRange.lowerBound])
        }
        // 電話番号（+始まり or ダッシュ2つ以上）を除去
        let words = rest.split(separator: " ").map(String.init)
        var hotelWords: [String] = []
        for word in words {
            let dashCount = word.filter { $0 == "-" }.count
            if word.hasPrefix("+") || dashCount >= 2 { break }
            hotelWords.append(word)
        }
        return (station, hotelWords.joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }

    private static func parseLegacyHotelDetail(_ detail: String) -> (station: String, hotelName: String) {
        guard let hotelRange = detail.range(of: "Hotel: ") else { return ("", "") }
        let afterHotel = String(detail[hotelRange.upperBound...])
        let hotelOnly: String
        if let transportRange = afterHotel.range(of: " Hotel Transport:") {
            hotelOnly = String(afterHotel[..<transportRange.lowerBound])
        } else {
            hotelOnly = afterHotel
        }

        let cleaned = hotelOnly
            .replacingOccurrences(of: " UPS Only", with: "")
            .replacingOccurrences(of: "UPS Only ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let words = cleaned.split(separator: " ").map(String.init)
        var hotelWords: [String] = []
        for word in words {
            let digitCount = word.filter(\.isNumber).count
            let dashCount = word.filter { $0 == "-" }.count
            if word.hasPrefix("+") || digitCount >= 3 || dashCount >= 2 { break }
            hotelWords.append(word)
        }
        return ("", hotelWords.joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }
}

private struct CrewAccessTripSummaryCardItemJSON: Decodable {
    let sequence: Int
    let arrAirport: String
    let startUtc: String
    let endUtc: String
}

private struct ImportLegUTCTimes {
    let startUtc: String
    let endUtc: String
}

private enum TimelineClockDisplay: String {
    case lcl
    case utc
}
