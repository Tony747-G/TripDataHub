import SwiftUI

struct TimelineTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    @AppStorage("timeline_source_filter") private var timelineSourceFilterRawValue = TimelineSourceFilter.tripBoard.rawValue
    private let headerBrown = Color(red: 0.24, green: 0.10, blue: 0.06)
    private let headerGold = Color(red: 0.96, green: 0.74, blue: 0.06)
    private let anchorageTimeZone = TimeZone(identifier: "America/Anchorage")
        ?? TimeZone(secondsFromGMT: NextReportWindowBuilder.anchorageFallbackOffsetSeconds)!
    @State private var didAutoScroll = false
    @State private var legData = TimelineLegData(schedules: [])

    private static let nextReportTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(identifier: "America/Anchorage")
            ?? TimeZone(secondsFromGMT: NextReportWindowBuilder.anchorageFallbackOffsetSeconds)!
        formatter.dateFormat = "EEE, MMM d yyyy  HH:mm"
        return formatter
    }()

    private static let anchorageHeaderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Anchorage")
            ?? TimeZone(secondsFromGMT: NextReportWindowBuilder.anchorageFallbackOffsetSeconds)!
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

    private var selectedSourceFilter: TimelineSourceFilter {
        TimelineSourceFilter(rawValue: timelineSourceFilterRawValue) ?? .tripBoard
    }

    private var currentTimelineSchedules: [PayPeriodSchedule] {
        viewModel.displaySchedules(filter: selectedSourceFilter)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                timelineTopBar
                sourceFilterBar
                importSummaryBanner
                timelineHeader
                nextReportCard
                timelineContent
                timelineFooter
                Color.gray.opacity(0.10)
                    .frame(height: 10)
            }
            .onAppear {
                viewModel.lastImportSummaryMessage = nil
                refreshLegData()
            }
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        ScrollViewReader { proxy in
            let connectionMap = legData.nextLegByID
            let tripBoundaryAfterLegs = tripBoundaryAfterLegIDs
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
                                    .id(leg.id)
                                if tripBoundaryAfterLegs.contains(leg.id) {
                                    Rectangle()
                                        .fill(isPastLeg(leg) ? Color.gray : dateHeaderTextColor)
                                        .frame(height: 4)
                                        .padding(.horizontal, 0)
                                        .padding(.top, 0)
                                        .padding(.bottom, 0)
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
                autoScrollToNextFlight(using: proxy)
            }
            .onChange(of: viewModel.schedules) { _, _ in
                refreshLegData()
                didAutoScroll = false
                autoScrollToNextFlight(using: proxy)
            }
            .onChange(of: timelineSourceFilterRawValue) { _, _ in
                refreshLegData()
                didAutoScroll = false
                autoScrollToNextFlight(using: proxy)
            }
        }
    }

    private var nextReportCard: some View {
        Group {
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
        HStack {
            Spacer()
            Text("Timeline")
                .appScaledFont(.headline, weight: .semibold, scale: fixedSmallScale)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.vertical, 8)
        .background(.background)
    }

    private var sourceFilterBar: some View {
        Picker("Source", selection: $timelineSourceFilterRawValue) {
            ForEach(TimelineSourceFilter.allCases) { filter in
                Text(filter.label).tag(filter.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(.background)
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

    private var timelineHeader: some View {
        HStack {
            Text("FNN CREW SUPPORT")
                .appScaledFont(.footnote, weight: .bold, scale: fixedSmallScale)
                .foregroundStyle(headerGold)
            Spacer()
            TimelineView(.periodic(from: Date(), by: 60)) { _ in
                Text(anchorageHeaderTimeText())
                    .appScaledFont(.caption2, scale: fixedSmallScale)
                    .foregroundStyle(headerGold.opacity(0.9))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(headerBrown)
    }

    private var timelineFooter: some View {
        Text(verbatim: "Copyright ©\(currentYear) FNNDEV, LLC. All Rights Reserved.")
            .appScaledFont(.caption2, scale: fixedSmallScale)
            .foregroundStyle(headerGold)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
            .background(headerBrown)
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
        legData.daySections
    }

    private var nextUpcomingLegID: UUID? {
        let now = Date()
        if let next = allLegs.first(where: { leg in
            guard let dep = parseLocalDateTime(leg.depLocal) else { return false }
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
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(targetID, anchor: .top)
            }
        }
    }

    private func refreshLegData() {
        legData = TimelineLegData(schedules: currentTimelineSchedules)
        NSLog(
            "[Timeline] filter=%@ schedules=%d legs=%d",
            selectedSourceFilter.rawValue,
            currentTimelineSchedules.count,
            legData.allLegs.count
        )
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

    private func nextReportTimestampText(for reportTime: Date) -> String {
        "\(Self.nextReportTimestampFormatter.string(from: reportTime)) ANC"
    }

    private func anchorageHeaderTimeText() -> String {
        "ANC  \(Self.anchorageHeaderFormatter.string(from: Date()))"
    }

    private func timeRangeText(for leg: TripLeg) -> String {
        let depTime = ScheduleDateText.timePart(from: leg.depLocal)
        let arrTime = ScheduleDateText.timePart(from: leg.arrLocal)
        return "\(depTime) - \(arrTime)"
    }

    @ViewBuilder
    private func timeRangeView(for leg: TripLeg, isPast: Bool) -> some View {
        let baseColor: Color = isPast ? .gray : .primary
        let diff = dayShift(from: leg.depLocal, to: leg.arrLocal)
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
            return .red
        }
        if remainingHours <= 24 {
            return .orange
        }
        if remainingHours <= 48 {
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
        let reference = parseLocalDateTime(leg.arrLocal) ?? parseLocalDateTime(leg.depLocal)
        guard let reference else { return false }
        return reference < Date()
    }

    private func parseLocalDateTime(_ text: String) -> Date? {
        Self.localDateTimeFormatter.date(from: text)
    }

    private func nowInAnchorage() -> Date {
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents(in: anchorageTimeZone, from: now)
        return calendar.date(from: DateComponents(
            timeZone: anchorageTimeZone,
            year: comps.year,
            month: comps.month,
            day: comps.day,
            hour: comps.hour,
            minute: comps.minute,
            second: comps.second
        )) ?? now
    }

    private var dateCardBackground: Color {
        ScheduleColors.dayHeaderBackground(for: colorScheme)
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

    private var fontScale: CGFloat {
        let option = AppFontSizeOption(rawValue: appFontSizeOptionRawValue) ?? .medium
        return option.scaleFactor
    }

    private var fixedSmallScale: CGFloat {
        AppFontSizeOption.small.scaleFactor
    }

    private var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    private var emptyStateTitle: String {
        switch selectedSourceFilter {
        case .crewAccess:
            return "No CrewAccess schedule yet"
        case .tripBoard:
            return "No TripBoard data yet"
        }
    }

    private var emptyStateDescription: String {
        switch selectedSourceFilter {
        case .crewAccess:
            return "Import a CrewAccess PDF to view your official schedule."
        case .tripBoard:
            return "Use Settings to fetch from TripBoard."
        }
    }

    private var emptyStateHint: String? {
        switch selectedSourceFilter {
        case .crewAccess:
            return "Go to Settings -> CrewAccess Import. Export using CrewAccess Print as a text-selectable PDF."
        case .tripBoard:
            return nil
        }
    }
}

private struct NextReportInfo {
    let pairing: String
    let reportTime: Date
}
