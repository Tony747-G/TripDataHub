import SwiftUI

struct IPadTimelineSidebarView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var selectedTripID: String?
    @Binding var scrollToDefaultTrigger: UUID
    @Environment(\.colorScheme) private var colorScheme
    @State private var tripDataByTripID: [String: CrewAccessTripSummary] = [:]
    @State private var deleteTripConfirmPairing: String? = nil
    @State private var friendScheduleMatches: FriendScheduleMatches = .empty
    @State private var friendMatchAlert: (title: String, message: String)? = nil
    // Cached per-schedule-update data — computed once in refreshLegData(), not on every body eval.
    @State private var legData = TimelineLegData(schedules: [])
    @State private var cachedTripStartLegIDs: Set<UUID> = []
    @State private var tripDataKeyByLegID: [UUID: String] = [:]
    @State private var firstRowIDByTripID: [String: String] = [:]
    /// Heavy window computation cached; time-based selection stays computed so it
    /// reflects current time as the clock advances without re-running the full build.
    @State private var cachedReportWindows: [NextReportTripWindow] = []

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

    private static let anchorageTimeZone: TimeZone =
        IATATimeZoneResolver.shared.resolve("ANC").flatMap { TimeZone(identifier: $0) }
        ?? TimeZone(secondsFromGMT: NextReportWindowBuilder.anchorageFallbackOffsetSeconds)!

    private static let reportTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US")
        f.timeZone = anchorageTimeZone
        f.dateFormat = "EEE, MMM d yyyy  HH:mm"
        return f
    }()

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
        viewModel.crewAccessSchedules
    }

    /// Selects the active/next report from the pre-built (cached) windows.
    /// Computed so that as time advances the displayed report updates without
    /// re-running the expensive NextReportWindowBuilder.build().
    private var nextReportInfo: (reportTime: Date, tripLabel: String)? {
        let now = Date()
        for window in cachedReportWindows {
            if now < window.reportTime {
                return (window.reportTime, window.pairing)
            }
            if now >= window.reportTime && now < window.tripEndANC {
                return nil
            }
        }
        return nil
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
            sidebarHeader
            if let report = nextReportInfo {
                nextReportStrip(report: report)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(legData.daySections) { section in
                            // Trip summary cards for trips whose first leg is in
                            // this day section. Rendered OUTSIDE the Section so
                            // they appear above the pinned date header, not below.
                            let startLegs = section.legs.filter { cachedTripStartLegIDs.contains($0.id) }
                            if !startLegs.isEmpty {
                                ForEach(startLegs, id: \.id) { startLeg in
                                    let isTripSelected = selectedTripID == "\(startLeg.payPeriod)|\(startLeg.pairing)"
                                    let isTripHighlighted = deleteTripConfirmPairing == startLeg.pairing
                                    tripSummaryCard(for: startLeg, isPast: section.isPast, isHighlighted: isTripHighlighted)
                                        .background(isTripSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                                        .overlay(alignment: .leading) {
                                            if isTripSelected {
                                                Rectangle().fill(Color.accentColor).frame(width: 3)
                                            }
                                        }
                                        .id("ipad.tripdata.\(startLeg.id.uuidString)")
                                        .simultaneousGesture(
                                            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                                deleteTripConfirmPairing = startLeg.pairing
                                            }
                                        )
                                }
                            }
                            Section {
                                ForEach(section.legs) { leg in
                                    let tripID = "\(leg.payPeriod)|\(leg.pairing)"
                                    let rowID = "\(tripID)|\(leg.leg)|\(leg.id.uuidString)"
                                    let isSelected = selectedTripID == tripID

                                    let isHighlighted = deleteTripConfirmPairing == leg.pairing
                                    let flightMatches = friendScheduleMatches.flightMatchesByLegID[leg.id] ?? []
                                    let hasFlightMatch = !flightMatches.isEmpty
                                    Group {
                                        Button {
                                            selectedTripID = selectedTripID == tripID ? nil : tripID
                                        } label: {
                                            TimelineFlightRow(
                                                leg: leg,
                                                isPast: isPastFlightRow(leg),
                                                fontScale: timelineFontScale,
                                                timeRangeText: timeRangeText(for: leg),
                                                dayDiff: ScheduleDateText.dayShift(
                                                    from: leg.depLocal,
                                                    to: leg.arrLocal
                                                ),
                                                blockText: blockText(for: leg),
                                                iconColor: hasFlightMatch ? friendMatchAmber : .primary,
                                                onIconTap: hasFlightMatch ? {
                                                    let lines = flightMatches.map { "GEMS \($0.friendGEMSID): \($0.departureAirport)-\($0.arrivalAirport)" }
                                                    friendMatchAlert = (
                                                        title: "Friends on \(leg.flight)",
                                                        message: lines.joined(separator: "\n")
                                                    )
                                                } : nil
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .background(isHighlighted ? Color.red.opacity(0.10) : (isSelected ? Color.accentColor.opacity(0.12) : Color.clear))
                                        .overlay(alignment: .leading) {
                                            if isSelected {
                                                Rectangle()
                                                    .fill(Color.accentColor)
                                                    .frame(width: 3)
                                            }
                                        }
                                        .simultaneousGesture(
                                            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                                deleteTripConfirmPairing = leg.pairing
                                            }
                                        )

                                        if shouldShowLayover(leg: leg) {
                                            let station = leg.layoverStation ?? leg.arrAirport
                                            let hotel = leg.layoverHotelName
                                                ?? tripDataByTripID[tripDataKeyByLegID[leg.id] ?? Self.fileKey(for: leg)]?.hotelByStation[CrewAccessTripSummaryStore.stationKey(station)]
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
                                                    onIconTap: hasRestOverlap ? {
                                                        let lines = restOverlaps.map { "GEMS \($0.friendGEMSID) at \($0.station)" }
                                                        friendMatchAlert = (
                                                            title: "Friends at \(station)",
                                                            message: lines.joined(separator: "\n")
                                                        )
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
                                                    deleteTripConfirmPairing = leg.pairing
                                                }
                                            )
                                        }
                                    }
                                    .id(rowID)
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
                }
                .onChange(of: selectedTripID) { _, newID in
                    if let id = newID,
                       let rowID = firstRowIDByTripID[id] {
                        withAnimation { proxy.scrollTo(rowID, anchor: .center) }
                    }
                }
                // On appear: if a trip is already selected (portrait sheet opened
                // from a calendar tap), scroll to that trip first. Otherwise fall
                // back to the next upcoming event.
                .task {
                    let initialTarget: String? = selectedTripID.flatMap { firstRowIDByTripID[$0] }
                        ?? nextScrollTargetID()
                    if let rowID = initialTarget { proxy.scrollTo(rowID, anchor: .top) }
                    for delay in [100_000_000, 200_000_000, 400_000_000] as [UInt64] {
                        try? await Task.sleep(nanoseconds: delay)
                        let target = selectedTripID.flatMap { firstRowIDByTripID[$0] }
                            ?? nextScrollTargetID()
                        if let rowID = target {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(rowID, anchor: .top)
                            }
                        }
                    }
                }
                .onChange(of: scrollToDefaultTrigger) { _, _ in
                    Task {
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        if let rowID = nextScrollTargetID() {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(rowID, anchor: .top)
                            }
                        }
                    }
                }
                .onChange(of: viewModel.schedules) { _, _ in
                    Task {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        if let rowID = nextScrollTargetID() {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(rowID, anchor: .top)
                            }
                        }
                    }
                }
                .onChange(of: viewModel.crewAccessSchedules) { _, _ in
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
        .onChange(of: viewModel.crewAccessSchedules) { _, _ in
            refreshLegData()
            refreshTripDataCards()
            refreshFriendScheduleMatches()
        }
        .onChange(of: viewModel.friendConnections) { _, _ in
            refreshFriendScheduleMatches()
        }
        .alert(friendMatchAlert?.title ?? "", isPresented: Binding(
            get: { friendMatchAlert != nil },
            set: { if !$0 { friendMatchAlert = nil } }
        )) {
            Button("OK") { friendMatchAlert = nil }
        } message: {
            Text(friendMatchAlert?.message ?? "")
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

    // MARK: Next Report Strip — identical structure to iPhone's nextReportCard

    private func nextReportStrip(report: (reportTime: Date, tripLabel: String)) -> some View {
        TimelineView(.periodic(from: Date(), by: 60)) { _ in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("NEXT REPORT")
                        .appScaledFont(.caption, weight: .bold, scale: timelineFontScale)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Trip \(report.tripLabel)")
                        .appScaledFont(.caption, scale: timelineFontScale)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                HStack {
                    Text(Self.reportTimeFormatter.string(from: report.reportTime) + " ANC")
                        .appScaledFont(.subheadline, weight: .bold, scale: timelineFontScale)
                        .foregroundStyle(dateHeaderTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                    Spacer()
                    Text(countdownText(to: report.reportTime))
                        .appScaledFont(.subheadline, weight: .bold, scale: timelineFontScale)
                        .foregroundStyle(countdownColor(to: report.reportTime))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.thinMaterial)
        }
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
        let remainingHours = target.timeIntervalSince(Date()) / 3600.0
        if remainingHours <= 12 { return .red }
        if remainingHours <= 24 { return .orange }
        return dateHeaderTextColor
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
        let dep = ScheduleDateText.timePart(from: leg.depLocal)
        let arr = ScheduleDateText.timePart(from: leg.arrLocal)
        return "\(dep) - \(arr)"
    }

    private func blockText(for leg: TripLeg) -> String {
        let text = LegConnectionTextBuilder.blockAndConnectionText(for: leg, nextLegByID: legData.nextLegByID)
        if shouldShowLayover(leg: leg),
           let slashRange = text.range(of: " / ") {
            return String(text[..<slashRange.lowerBound])
        }
        return text
            .replacingOccurrences(of: "Layover at ", with: "LO at ")
            .replacingOccurrences(of: "Layover:", with: "LO:")
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
        let data = TimelineLegData(schedules: schedules)
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

        // Pre-compute trip-start leg IDs (first leg per unique trip, in depLocal order).
        var seenTrips = Set<String>()
        var startIDs = Set<UUID>()
        for leg in data.allLegs {
            let key = "\(leg.payPeriod)|\(leg.pairing)"
            if seenTrips.insert(key).inserted { startIDs.insert(leg.id) }
        }
        cachedTripStartLegIDs = startIDs

        // Pre-compute first row ID per trip (used for scroll + portrait sheet focus).
        var rowMap: [String: String] = [:]
        for section in data.daySections {
            for leg in section.legs {
                let tripID = "\(leg.payPeriod)|\(leg.pairing)"
                if rowMap[tripID] == nil {
                    rowMap[tripID] = "\(tripID)|\(leg.leg)|\(leg.id.uuidString)"
                }
            }
        }
        firstRowIDByTripID = rowMap

        // Cache only the window list; time-based selection stays in computed nextReportInfo.
        cachedReportWindows = NextReportWindowBuilder.build(
            schedules: schedules,
            anchorageTimeZone: Self.anchorageTimeZone
        ).sorted { $0.reportTime < $1.reportTime }
    }

    private func refreshTripDataCards() {
        Task.detached(priority: .utility) {
            let result = CrewAccessTripSummaryStore.load()
            await MainActor.run {
                tripDataByTripID = result.byFileKey
            }
        }
    }

    private func refreshFriendScheduleMatches() {
        guard !AppEnvironment.isAppStoreReviewMode else {
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

}

#Preview {
    IPadTimelineSidebarView(selectedTripID: .constant(nil), scrollToDefaultTrigger: .constant(UUID()))
        .environmentObject(AppViewModel.shared)
        .frame(width: 420)
}
