import SwiftUI

/// Reusable timeline renderer for `[PayPeriodSchedule]`.
///
/// Phase A: Used by `FriendTimelineView` only.
/// Phase B (planned): `TimelineTabView` will be migrated to use this same renderer
/// without changing its visual output, by adding decorator hooks for friend-match
/// overlays, tap-to-import, trip data cards, etc.
struct ScheduleTimelineRendererView: View {
    let schedules: [PayPeriodSchedule]
    var emptyStateMessage: String = "No timeline data available."

    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private let tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared

    private var fontScale: CGFloat {
        (AppFontSizeOption(rawValue: appFontSizeOptionRawValue) ?? .medium).scaleFactor
    }

    private var dateHeaderTextColor: Color {
        ScheduleColors.timelineDateHeaderText(for: colorScheme)
    }

    private var dateCardBackground: Color {
        ScheduleColors.dayHeaderBackground(for: colorScheme)
    }

    var body: some View {
        let legData = TimelineLegData(schedules: schedules)
        let sections = legData.daySections
        let nextLegByID = legData.nextLegByID
        let initialFocusID = focusScrollID(for: legData)

        ScrollViewReader { proxy in
            ScrollView {
                if sections.isEmpty {
                    Text(emptyStateMessage)
                        .appScaledFont(.footnote, scale: fontScale)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(sections) { section in
                            Text(section.label)
                                .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                                .foregroundStyle(section.isPast ? .gray : dateHeaderTextColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 5)
                                .background(dateCardBackground)
                                .id(daySectionScrollID(section.id))

                            ForEach(section.legs) { leg in
                                legRow(leg: leg, nextLegByID: nextLegByID)
                                    .id(legScrollID(leg.id))
                                if shouldShowLayover(leg: leg, connectionMap: nextLegByID) {
                                    layoverCard(for: leg, connectionMap: nextLegByID)
                                        .id(layoverScrollID(leg.id))
                                }
                                Divider()
                            }
                        }
                    }
                }
            }
            .task(id: scrollContextKey(for: legData, focusID: initialFocusID)) {
                await autoScrollToFocus(using: proxy, scrollID: initialFocusID)
            }
        }
    }

    // MARK: - Leg row

    @ViewBuilder
    private func legRow(leg: TripLeg, nextLegByID: [UUID: TripLeg]) -> some View {
        TimelineFlightRow(
            leg: leg,
            isPast: leg.isCompleted || isPastFlightRow(leg),
            fontScale: fontScale,
            timeRangeText: timeRangeText(for: leg),
            dayDiff: dayShift(for: leg),
            blockText: blockText(for: leg, nextLegByID: nextLegByID)
            // iconColor and onFriendMatchTap omitted: Friends Timeline uses defaults (no highlights)
        )
    }

    // MARK: - Layover card

    @ViewBuilder
    private func layoverCard(for leg: TripLeg, connectionMap: [UUID: TripLeg]) -> some View {
        TimelineLayoverCard(
            station: leg.layoverStation ?? leg.arrAirport,
            hotel: leg.layoverHotelName ?? "",
            durationText: layoverDurationText(for: leg, connectionMap: connectionMap),
            remainingText: layoverRemainingText(for: leg, connectionMap: connectionMap),
            arrLocalDateLabel: arrivalLocalDateLabel(for: leg),
            isPast: TimelineLayoverSupport.isPastLayover(
                arrDate: utcArrivalDate(for: leg),
                nextLeg: connectionMap[leg.id]
            ),
            fontScale: fontScale
            // iconColor and onFriendMatchTap omitted: Friends Timeline uses defaults (no highlights)
        )
    }

    // MARK: - Computations

    private func shouldShowLayover(leg: TripLeg, connectionMap: [UUID: TripLeg]) -> Bool {
        let next = connectionMap[leg.id]
        return TimelineLayoverSupport.shouldShow(
            arrDate: utcArrivalDate(for: leg),
            nextDepDate: next.flatMap { utcDepartureDate(for: $0) },
            samePairing: next?.pairing == leg.pairing
        )
    }

    private func layoverDurationText(for leg: TripLeg, connectionMap: [UUID: TripLeg]) -> String {
        let next = connectionMap[leg.id]
        return TimelineLayoverSupport.durationText(
            arrDate: utcArrivalDate(for: leg),
            nextLeg: next,
            fallbackDuration: leg.layoverDuration
        )
    }

    private func layoverRemainingText(for leg: TripLeg, connectionMap: [UUID: TripLeg]) -> String {
        TimelineLayoverSupport.remainingText(
            arrDate: utcArrivalDate(for: leg),
            nextLeg: connectionMap[leg.id]
        )
    }

    private func arrivalLocalDateLabel(for leg: TripLeg) -> String {
        guard let arrUTC = utcArrivalDate(for: leg) else { return "" }
        guard let tzID = tzResolver.resolve(leg.arrAirport) else { return "" }
        return Self.localDayHeaderFormatter(for: tzID).string(from: arrUTC)
    }

    private func timeRangeText(for leg: TripLeg) -> String {
        guard let depLocalText = localTimeText(fromUTC: utcDepartureDate(for: leg), airport: leg.depAirport),
              let arrLocalText = localTimeText(fromUTC: utcArrivalDate(for: leg), airport: leg.arrAirport)
        else {
            return "LCL MISSING"
        }
        return "\(depLocalText) - \(arrLocalText)"
    }

    private func dayShift(for leg: TripLeg) -> Int {
        guard let depKey = localDayKey(fromUTC: utcDepartureDate(for: leg), airport: leg.depAirport),
              let arrKey = localDayKey(fromUTC: utcArrivalDate(for: leg), airport: leg.arrAirport),
              let depDay = SharedDateFormatters.utcDayOnly.date(from: depKey),
              let arrDay = SharedDateFormatters.utcDayOnly.date(from: arrKey)
        else {
            return 0
        }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: depDay, to: arrDay).day ?? 0
    }

    private func blockText(for leg: TripLeg, nextLegByID: [UUID: TripLeg]) -> String {
        let text = LegConnectionTextBuilder.blockAndConnectionText(for: leg, nextLegByID: nextLegByID)
        // Layover cards are shown separately; trim the connection suffix to avoid duplication.
        if shouldShowLayover(leg: leg, connectionMap: nextLegByID),
           let slashRange = text.range(of: " / ") {
            return String(text[..<slashRange.lowerBound])
        }
        return text
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

    private func utcDepartureDate(for leg: TripLeg) -> Date? {
        LegConnectionTextBuilder.parseUTC(leg.depUTC)
    }

    private func utcArrivalDate(for leg: TripLeg) -> Date? {
        LegConnectionTextBuilder.parseUTC(leg.arrUTC)
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

    private func parseLocalDateTime(_ text: String) -> Date? {
        Self.localDateTimeFormatter.date(from: text)
    }

    // MARK: - Initial scroll target

    private func daySectionScrollID(_ dayID: String) -> String {
        "friendTimeline.daySection.\(dayID)"
    }

    private func legScrollID(_ legID: UUID) -> String {
        "friendTimeline.leg.\(legID.uuidString)"
    }

    private func layoverScrollID(_ legID: UUID) -> String {
        "friendTimeline.layover.\(legID.uuidString)"
    }

    private func scrollContextKey(for legData: TimelineLegData, focusID: String?) -> String {
        let firstID = legData.allLegs.first?.id.uuidString ?? "none"
        let lastID = legData.allLegs.last?.id.uuidString ?? "none"
        return "\(focusID ?? "none")|\(legData.allLegs.count)|\(firstID)|\(lastID)"
    }

    private func focusScrollID(for legData: TimelineLegData) -> String? {
        let now = Date()
        let connectionMap = legData.nextLegByID

        for leg in legData.allLegs {
            guard shouldShowLayover(leg: leg, connectionMap: connectionMap),
                  let arr = utcArrivalDate(for: leg),
                  let nextLeg = connectionMap[leg.id]
            else { continue }
            let layoverEnd = TimelineLayoverSupport.restInfo(arrDate: arr, nextLeg: nextLeg)?.dutyStartUTC
                ?? utcDepartureDate(for: nextLeg).map { $0.addingTimeInterval(-90 * 60) }
            guard let layoverEnd else { continue }
            if arr <= now && now < layoverEnd {
                return layoverScrollID(leg.id)
            }
        }

        let currentOrNextLeg = legData.allLegs.first { leg in
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

        return currentOrNextLeg.map { legScrollID($0.id) }
    }

    @MainActor
    private func autoScrollToFocus(using proxy: ScrollViewProxy, scrollID: String?) async {
        guard !Task.isCancelled, let scrollID else { return }
        proxy.scrollTo(scrollID, anchor: .top)

        let delays: [UInt64] = [100_000_000, 200_000_000, 400_000_000]
        for delay in delays {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(scrollID, anchor: .top)
            }
        }
    }

    // MARK: - Formatters
    //
    // Formatters are cached per timezone identifier to avoid mutating shared state.
    // Each unique tzID gets its own DateFormatter instance, which is safe and efficient.

    private static var localTimeFormatters: [String: DateFormatter] = [:]
    private static var localDayKeyFormatters: [String: DateFormatter] = [:]
    private static var localDayHeaderFormatters: [String: DateFormatter] = [:]

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

    private static func localDayHeaderFormatter(for tzID: String) -> DateFormatter {
        if let cached = localDayHeaderFormatters[tzID] { return cached }
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "EEE, MMM d yyyy"
        fmt.timeZone = TimeZone(identifier: tzID)
        localDayHeaderFormatters[tzID] = fmt
        return fmt
    }

    private static let localDateTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt
    }()
}
