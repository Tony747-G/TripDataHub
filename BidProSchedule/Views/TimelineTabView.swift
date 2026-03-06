import SwiftUI

struct TimelineTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    @AppStorage("timeline_clock_display") private var timelineClockDisplayRawValue = TimelineClockDisplay.lcl.rawValue
    private let anchorageTimeZone = TimeZone(identifier: "America/Anchorage")
        ?? TimeZone(secondsFromGMT: NextReportWindowBuilder.anchorageFallbackOffsetSeconds)!
    private let tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared
    @State private var didAutoScroll = false
    @State private var legData = TimelineLegData(schedules: [])
    @State private var tripDataByTripID: [String: TripDataCardInfo] = [:]
    @State private var importedUTCTimesByTripAndSequence: [String: ImportLegUTCTimes] = [:]

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

    private static let localTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let localDayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

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
                nextReportCard
                timelineContent
                Color.gray.opacity(0.10)
                    .frame(height: 10)
            }
            .onAppear {
                viewModel.lastImportSummaryMessage = nil
                refreshLegData()
                refreshTripDataCards()
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

                            let legs = section.legs
                            ForEach(Array(legs.enumerated()), id: \.element.id) { _, leg in
                                timelineRow(leg: leg, nextLegByID: connectionMap)
                                    .id("\(leg.id.uuidString)|\(selectedClockDisplay.rawValue)")
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
                autoScrollToNextFlight(using: proxy)
            }
            .onChange(of: viewModel.schedules) { _, _ in
                refreshLegData()
                refreshTripDataCards()
                didAutoScroll = false
                autoScrollToNextFlight(using: proxy)
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
                } else {
                    EmptyView()
                }
            }
        }
    }

    private func timelineRow(leg: TripLeg, nextLegByID: [UUID: TripLeg]) -> some View {
        let isPast = isPastLeg(leg)

        return HStack(alignment: .center, spacing: 12) {
            MaterialIconView(
                codePoint: iconCodePointForLegStatus(leg.status),
                size: 20 * fontScale,
                color: isPast ? .gray : .primary,
                fallbackSystemName: iconFallbackSystemNameForLegStatus(leg.status)
            )
                .frame(width: 28 * fontScale, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("\(leg.depAirport) - \(leg.arrAirport)")
                        .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                    Spacer()
                    timeRangeView(for: leg, isPast: isPast)
                }

                HStack {
                    Text(leg.displayFlightNumberText)
                        .appScaledFont(.footnote, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                    Spacer()
                    Text(blockAndLayoverText(for: leg, nextLegByID: nextLegByID))
                        .appScaledFont(.caption, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
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
                .foregroundStyle(selectedClockDisplay == .lcl ? Color.black : dateHeaderTextColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(selectedClockDisplay == .lcl ? dateHeaderTextColor : .clear)
                .clipShape(Capsule())
                .onTapGesture { timelineClockDisplayRawValue = TimelineClockDisplay.lcl.rawValue }
            Text("/")
                .appScaledFont(.caption2, weight: .semibold, scale: fixedSmallScale)
                .foregroundStyle(dateHeaderTextColor)
                .padding(.horizontal, 2)
            Text("UTC")
                .appScaledFont(.caption2, weight: .semibold, scale: fixedSmallScale)
                .foregroundStyle(selectedClockDisplay == .utc ? Color.black : dateHeaderTextColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(selectedClockDisplay == .utc ? dateHeaderTextColor : .clear)
                .clipShape(Capsule())
                .onTapGesture { timelineClockDisplayRawValue = TimelineClockDisplay.utc.rawValue }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 999)
                .stroke(dateHeaderTextColor.opacity(0.8), lineWidth: 1)
        )
        .clipShape(Capsule())
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

    private var tripWindows: [NextReportTripWindow] {
        NextReportWindowBuilder.build(schedules: currentTimelineSchedules, anchorageTimeZone: anchorageTimeZone)
    }

    private var daySections: [TimelineDaySection] {
        buildDisplayDaySections(from: allLegs)
    }

    private var nextUpcomingLegID: UUID? {
        let now = Date()
        if let next = allLegs.first(where: { leg in
            guard let dep = utcDepartureDate(for: leg) ?? parseLocalDateTime(leg.depLocal) else { return false }
            return dep >= now
        }) {
            return next.id
        }
        return allLegs.first?.id
    }

    private func autoScrollToNextFlight(using proxy: ScrollViewProxy) {
        guard !didAutoScroll else { return }
        guard let targetID = nextUpcomingLegID else { return }
        didAutoScroll = true
        let scrollID = "\(targetID.uuidString)|\(selectedClockDisplay.rawValue)"
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(scrollID, anchor: .top)
            }
        }
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

    @ViewBuilder
    private func timeRangeView(for leg: TripLeg, isPast: Bool) -> some View {
        let baseColor: Color = isPast ? .gray : .primary
        let diff = dayShift(for: leg)
        let diffColor: Color = isPast ? .gray : (diff == 0 ? baseColor : .red)
        HStack(spacing: 0) {
            Text(timeRangeText(for: leg))
                .foregroundStyle(baseColor)
            Text(diffLabel(diff))
                .foregroundStyle(diffColor)
        }
        .appScaledFont(.subheadline, scale: fontScale)
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

    private func diffLabel(_ diff: Int) -> String {
        guard diff != 0 else { return "" }
        let sign = diff > 0 ? "+" : ""
        return " (\(sign)\(diff)d)"
    }

    private func countdownText(to target: Date) -> String {
        let deltaSeconds = Int(target.timeIntervalSince(nowInAnchorage()))
        let sign = deltaSeconds >= 0 ? "-" : "+"
        let absMinutes = abs(deltaSeconds) / 60
        let days = absMinutes / (24 * 60)
        let hours = (absMinutes % (24 * 60)) / 60
        let minutes = absMinutes % 60
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

    private func iconCodePointForLegStatus(_ status: String) -> Int {
        let normalized = status.uppercased()
        if normalized == "DH" || normalized == "CML" {
            return 58729
        }
        return 58681
    }

    private func iconFallbackSystemNameForLegStatus(_ status: String) -> String {
        let normalized = status.uppercased()
        if normalized == "DH" || normalized == "CML" {
            return "paperplane.fill"
        }
        return "airplane"
    }

    private func isPastLeg(_ leg: TripLeg) -> Bool {
        let reference = utcDepartureDate(for: leg) ?? parseLocalDateTime(leg.depLocal)
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

        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let dayStart: Date
        if selectedClockDisplay == .utc {
            var utcCalendar = calendar
            utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
            dayStart = utcCalendar.startOfDay(for: now)
        } else {
            dayStart = calendar.startOfDay(for: now)
        }

        return order.map { key in
            let dayDate = dayDate(from: key)
            let isPast = (dayDate?.compare(dayStart) == .orderedAscending)
            return TimelineDaySection(
                id: key,
                label: dayHeaderLabel(from: key),
                isPast: isPast,
                legs: grouped[key] ?? []
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
              let tzID = tzResolver.resolve(airport),
              let tz = TimeZone(identifier: tzID)
        else {
            return nil
        }
        Self.localTimeFormatter.timeZone = tz
        return Self.localTimeFormatter.string(from: utcDate)
    }

    private func localDayKey(fromUTC utcDate: Date?, airport: String) -> String? {
        guard let utcDate,
              let tzID = tzResolver.resolve(airport),
              let tz = TimeZone(identifier: tzID)
        else {
            return nil
        }
        Self.localDayKeyFormatter.timeZone = tz
        return Self.localDayKeyFormatter.string(from: utcDate)
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

    private func blockAndLayoverText(for leg: TripLeg, nextLegByID: [UUID: TripLeg]) -> String {
        let text = LegConnectionTextBuilder.blockAndConnectionText(for: leg, nextLegByID: nextLegByID)
        return text
            .replacingOccurrences(of: "Layover at ", with: "LO at ")
            .replacingOccurrences(of: "Layover:", with: "LO:")
    }

    private func isTripBoundary(current: TripLeg, next: TripLeg) -> Bool {
        if next.leg == 1 { return true }
        if current.payPeriod != next.payPeriod { return true }
        if current.pairing != next.pairing { return true }
        return next.leg <= current.leg
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
                    .appScaledFont(.caption, weight: .bold, scale: fontScale)
                    .foregroundStyle(tripCardTextColor)
                Spacer()
                Text("Credit: \(creditText)")
                    .appScaledFont(.caption, weight: .bold, scale: fontScale)
                    .foregroundStyle(tripCardTextColor)
            }
            if let tripDays = summary?.tripDays, !tripDays.isEmpty {
                Text("Trip Days: \(tripDays)")
                    .appScaledFont(.caption, scale: fontScale)
                    .foregroundStyle(tripCardTextColor)
            }
            if let tafb = summary?.tafb, !tafb.isEmpty {
                Text("TAFB: \(tafb)")
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
            if current == nil || modifiedAt > current!.date {
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
            summaryByTripID[tripID] = TripDataCardInfo(
                creditTime: decoded.creditTime,
                tripDays: decoded.tripDays,
                tafb: decoded.tafb
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
}

private struct CrewAccessTripSummaryCardJSON: Decodable {
    let tripId: String
    let creditTime: String?
    let tripDays: String?
    let tafb: String?
    let items: [CrewAccessTripSummaryCardItemJSON]

    private enum CodingKeys: String, CodingKey {
        case tripId
        case creditTime
        case tripDays
        case tafb
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tripId = try container.decode(String.self, forKey: .tripId)
        creditTime = try container.decodeIfPresent(String.self, forKey: .creditTime)
        tripDays = try container.decodeIfPresent(String.self, forKey: .tripDays)
        tafb = try container.decodeIfPresent(String.self, forKey: .tafb)
        items = try container.decodeIfPresent([CrewAccessTripSummaryCardItemJSON].self, forKey: .items) ?? []
    }
}

private struct CrewAccessTripSummaryCardItemJSON: Decodable {
    let sequence: Int
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
