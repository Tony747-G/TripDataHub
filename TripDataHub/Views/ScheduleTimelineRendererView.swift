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

                        ForEach(section.legs) { leg in
                            legRow(leg: leg, nextLegByID: nextLegByID)
                            if shouldShowLayover(leg: leg, connectionMap: nextLegByID) {
                                layoverCard(for: leg, connectionMap: nextLegByID)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Leg row

    @ViewBuilder
    private func legRow(leg: TripLeg, nextLegByID: [UUID: TripLeg]) -> some View {
        let isPast = isPastLeg(leg)
        HStack(alignment: .center, spacing: 12) {
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
                    Text(blockText(for: leg, nextLegByID: nextLegByID))
                        .appScaledFont(.caption, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
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

    // MARK: - Layover card

    @ViewBuilder
    private func layoverCard(for leg: TripLeg, connectionMap: [UUID: TripLeg]) -> some View {
        let isPast = isPastLeg(leg)
        let station = leg.layoverStation ?? leg.arrAirport
        let hotel = leg.layoverHotelName ?? ""
        let arrLocalDate = arrivalLocalDateLabel(for: leg)
        let durationText = layoverDurationText(for: leg, connectionMap: connectionMap)

        VStack(spacing: 0) {
            if !arrLocalDate.isEmpty {
                Text(arrLocalDate)
                    .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                    .foregroundStyle(isPast ? .gray : dateHeaderTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .background(dateCardBackground)
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bed.double.fill")
                    .font(.system(size: 16 * fontScale))
                    .foregroundStyle(isPast ? .gray : .primary)
                    .frame(width: 28 * fontScale, alignment: .center)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Layover at \(station)")
                        .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                    HStack {
                        if !hotel.isEmpty {
                            Text(hotel)
                                .appScaledFont(.footnote, scale: fontScale)
                                .foregroundStyle(isPast ? .gray : .secondary)
                        }
                        Spacer()
                        if !durationText.isEmpty {
                            Text("Rest: \(durationText)")
                                .appScaledFont(.caption, scale: fontScale)
                                .foregroundStyle(isPast ? .gray : .primary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
    }

    // MARK: - Computations

    private func shouldShowLayover(leg: TripLeg, connectionMap: [UUID: TripLeg]) -> Bool {
        guard let next = connectionMap[leg.id], next.pairing == leg.pairing else { return false }
        guard let arrDate = utcArrivalDate(for: leg),
              let depDate = utcDepartureDate(for: next) else { return false }
        let gapMinutes = Int(depDate.timeIntervalSince(arrDate) / 60)
        return gapMinutes >= 180
    }

    private func layoverDurationText(for leg: TripLeg, connectionMap: [UUID: TripLeg]) -> String {
        if let next = connectionMap[leg.id],
           let arrDate = utcArrivalDate(for: leg),
           let depDate = utcDepartureDate(for: next) {
            let mins = max(0, Int(depDate.timeIntervalSince(arrDate) / 60))
            return "\(mins / 60):\(String(format: "%02d", mins % 60))"
        }
        return leg.layoverDuration ?? ""
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

    private func diffLabel(_ diff: Int) -> String {
        guard diff != 0 else { return "" }
        let sign = diff > 0 ? "+" : ""
        return " (\(sign)\(diff)d)"
    }

    private func blockText(for leg: TripLeg, nextLegByID: [UUID: TripLeg]) -> String {
        let text = LegConnectionTextBuilder.blockAndConnectionText(for: leg, nextLegByID: nextLegByID)
        // Layover cards are shown separately; trim " / LO at ..." suffix to avoid duplication.
        if shouldShowLayover(leg: leg, connectionMap: nextLegByID),
           let range = text.range(of: " / LO at") {
            return String(text[..<range.lowerBound])
        }
        return text
    }

    private func isPastLeg(_ leg: TripLeg) -> Bool {
        let reference = utcArrivalDate(for: leg)
            ?? parseLocalDateTime(leg.arrLocal)
            ?? utcDepartureDate(for: leg)
            ?? parseLocalDateTime(leg.depLocal)
        guard let reference else { return false }
        return reference < Date()
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

    private func iconCodePointForLegStatus(_ status: String) -> Int {
        let normalized = status.uppercased()
        if normalized == "DH" || normalized == "CML" { return 58729 }
        return 58681
    }

    private func iconFallbackSystemNameForLegStatus(_ status: String) -> String {
        let normalized = status.uppercased()
        if normalized == "DH" || normalized == "CML" { return "paperplane.fill" }
        return "airplane"
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
