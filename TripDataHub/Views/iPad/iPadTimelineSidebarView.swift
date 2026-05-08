import SwiftUI

struct IPadTimelineSidebarView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var selectedTripID: String?
    @Environment(\.colorScheme) private var colorScheme

    private var dateHeaderTextColor: Color {
        ScheduleColors.timelineDateHeaderText(for: colorScheme)
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
        // crewAccess is primary. Add bidpro schedules whose pairings have no overlap with
        // crewAccess so we never show the same trip twice (viewModel.schedules is the merged
        // union of both sources and would cause duplicates if used directly here).
        let crewAccessPairings = Set(
            viewModel.crewAccessSchedules.flatMap(\.legs).map { "\($0.payPeriod)|\($0.pairing)" }
        )
        let bidproOnly = viewModel.bidproSchedules.filter { schedule in
            !schedule.legs.contains { crewAccessPairings.contains("\($0.payPeriod)|\($0.pairing)") }
        }
        return viewModel.crewAccessSchedules + bidproOnly
    }

    private var legData: TimelineLegData {
        TimelineLegData(schedules: sidebarSchedules)
    }

    private var nextReportInfo: (reportTime: Date, tripLabel: String)? {
        let windows = NextReportWindowBuilder.build(
            schedules: sidebarSchedules,
            anchorageTimeZone: Self.anchorageTimeZone
        ).sorted { $0.reportTime < $1.reportTime }
        let nowANC = Date()
        for window in windows {
            if nowANC < window.reportTime {
                return (window.reportTime, window.pairing)
            }
            if nowANC >= window.reportTime && nowANC < window.tripEndANC {
                return (window.reportTime, window.pairing)
            }
        }
        return nil
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
                            Section {
                                ForEach(section.legs) { leg in
                                    let tripID = "\(leg.payPeriod)|\(leg.pairing)"
                                    let rowID = "\(tripID)|\(leg.leg)|\(leg.id.uuidString)"
                                    let isSelected = selectedTripID == tripID

                                    Group {
                                        Button {
                                            selectedTripID = tripID
                                        } label: {
                                            TimelineFlightRow(
                                                leg: leg,
                                                isPast: section.isPast,
                                                fontScale: timelineFontScale,
                                                timeRangeText: timeRangeText(for: leg),
                                                dayDiff: ScheduleDateText.dayShift(
                                                    from: leg.depLocal,
                                                    to: leg.arrLocal
                                                ),
                                                blockText: LegConnectionTextBuilder.blockAndConnectionText(
                                                    for: leg,
                                                    nextLegByID: legData.nextLegByID
                                                )
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                                        .overlay(alignment: .leading) {
                                            if isSelected {
                                                Rectangle()
                                                    .fill(Color.accentColor)
                                                    .frame(width: 3)
                                            }
                                        }

                                        if shouldShowLayover(leg: leg) {
                                            TimelineLayoverCard(
                                                station: leg.layoverStation ?? leg.arrAirport,
                                                hotel: leg.layoverHotelName ?? "",
                                                durationText: TimelineLayoverSupport.durationText(
                                                    arrDate: LegConnectionTextBuilder.parseUTC(leg.arrUTC),
                                                    nextDepDate: legData.nextLegByID[leg.id].flatMap {
                                                        LegConnectionTextBuilder.parseUTC($0.depUTC)
                                                    },
                                                    fallbackDuration: leg.layoverDuration
                                                ),
                                                arrLocalDateLabel: "",
                                                isPast: section.isPast,
                                                fontScale: timelineFontScale
                                            )
                                        }
                                    }
                                    .id(rowID)
                                }
                            } header: {
                                Text(section.label)
                                    .appScaledFont(.caption2, weight: .semibold, scale: timelineFontScale)
                                    .foregroundStyle(ScheduleColors.timelineDateHeaderText(for: colorScheme))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(ScheduleColors.dayHeaderBackground(for: colorScheme))
                            }
                        }
                    }
                }
                .onChange(of: selectedTripID) { _, newID in
                    if let id = newID,
                       let firstRowID = firstRowID(for: id) {
                        withAnimation { proxy.scrollTo(firstRowID, anchor: .center) }
                    }
                }
            }
        }
        .background(Color(.systemBackground))
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

    // MARK: Helpers

    private func timeRangeText(for leg: TripLeg) -> String {
        let dep = ScheduleDateText.timePart(from: leg.depLocal)
        let arr = ScheduleDateText.timePart(from: leg.arrLocal)
        return "\(dep) - \(arr)"
    }

    private func shouldShowLayover(leg: TripLeg) -> Bool {
        let nextLeg = legData.nextLegByID[leg.id]
        return TimelineLayoverSupport.shouldShow(
            arrDate: LegConnectionTextBuilder.parseUTC(leg.arrUTC),
            nextDepDate: nextLeg.flatMap { LegConnectionTextBuilder.parseUTC($0.depUTC) },
            samePairing: nextLeg?.pairing == leg.pairing
        )
    }

    private func firstRowID(for tripID: String) -> String? {
        for section in legData.daySections {
            if let leg = section.legs.first(where: { "\($0.payPeriod)|\($0.pairing)" == tripID }) {
                return "\(tripID)|\(leg.leg)|\(leg.id.uuidString)"
            }
        }
        return nil
    }
}

#Preview {
    IPadTimelineSidebarView(selectedTripID: .constant(nil))
        .environmentObject(AppViewModel.shared)
        .frame(width: 420)
}
