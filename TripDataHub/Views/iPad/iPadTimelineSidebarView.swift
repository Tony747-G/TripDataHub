import SwiftUI

struct IPadTimelineSidebarView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var selectedTripID: String?

    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue

    private static let anchorageTimeZone: TimeZone =
        IATATimeZoneResolver.shared.resolve("ANC").flatMap { TimeZone(identifier: $0) }
        ?? TimeZone(secondsFromGMT: NextReportWindowBuilder.anchorageFallbackOffsetSeconds)!

    private static let reportTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = anchorageTimeZone
        f.dateFormat = "HH:mm"
        return f
    }()

    private var fontScale: CGFloat {
        (AppFontSizeOption(rawValue: appFontSizeOptionRawValue) ?? .medium).scaleFactor
    }

    private var sidebarSchedules: [PayPeriodSchedule] {
        // crewAccess is primary; supplement with CloudKit for any schedules not yet PDF-imported.
        let crewAccessPairings = Set(
            viewModel.crewAccessSchedules.flatMap(\.legs).map { "\($0.payPeriod)|\($0.pairing)" }
        )
        let cloudKitOnly = viewModel.schedules.filter { schedule in
            schedule.legs.contains { !crewAccessPairings.contains("\($0.payPeriod)|\($0.pairing)") }
        }
        return viewModel.crewAccessSchedules + cloudKitOnly
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
                                    let isSelected = selectedTripID == tripID

                                    Group {
                                        Button {
                                            selectedTripID = tripID
                                        } label: {
                                            TimelineFlightRow(
                                                leg: leg,
                                                isPast: section.isPast,
                                                fontScale: fontScale,
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
                                                fontScale: fontScale
                                            )
                                        }
                                    }
                                    .id(tripID)
                                }
                            } header: {
                                Text(section.label)
                                    .appScaledFont(.footnote, weight: .semibold, scale: fontScale)
                                    .foregroundStyle(ScheduleColors.timelineDateHeaderText(for: .dark))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 5)
                                    .background(ScheduleColors.dayHeaderBackground(for: .light))
                            }
                        }
                    }
                }
                .onChange(of: selectedTripID) { _, newID in
                    if let id = newID {
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .background(Color(.systemBackground))
    }

    // MARK: Header

    private var sidebarHeader: some View {
        Text("Timeline")
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Next Report Strip

    private func nextReportStrip(report: (reportTime: Date, tripLabel: String)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("NEXT REPORT")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(Self.reportTimeFormatter.string(from: report.reportTime) + " ANC")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Spacer()
            Text(report.tripLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
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
}

#Preview {
    IPadTimelineSidebarView(selectedTripID: .constant(nil))
        .environmentObject(AppViewModel.shared)
        .frame(width: 420)
}
