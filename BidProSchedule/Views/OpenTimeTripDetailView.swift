import SwiftUI

struct OpenTimeTripDetailView: View {
    let trip: OpenTimeTrip
    let titleColor: Color
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    var body: some View {
        let connectionMap = nextLegByID
        ScrollView {
            LazyVStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(trip.pairing)
                            .appScaledFont(.headline, scale: fontScale)
                            .foregroundStyle(titleColor)
                        Spacer()
                        Text("Credit: \(trip.credit)")
                            .appScaledFont(.subheadline, scale: fontScale)
                            .foregroundStyle(Color.primary.opacity(0.85))
                    }
                    Text(trip.route)
                        .appScaledFont(.subheadline, weight: .semibold, scale: fontScale)
                        .foregroundStyle(titleColor)
                    Text("\(trip.startLocal) -> \(trip.endLocal)")
                        .appScaledFont(.subheadline, scale: fontScale)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(summaryBackground)

                if groupedLegs.isEmpty {
                    Text("No leg details available for this trip.")
                        .appScaledFont(.footnote, scale: fontScale)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else {
                    ForEach(groupedLegs) { section in
                        Text(section.label)
                            .appScaledFont(.subheadline, weight: .semibold, scale: fontScale)
                            .foregroundStyle(dateHeaderTextColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(dayHeaderBackground)

                        ForEach(Array(section.legs.enumerated()), id: \.element.id) { _, leg in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: iconName(for: leg.status))
                                    .appScaledFont(.subheadline, scale: fontScale)
                                    .foregroundStyle(.primary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("\(leg.depAirport) - \(leg.arrAirport)")
                                            .appScaledFont(.subheadline, weight: .semibold, scale: fontScale)
                                        Spacer()
                                        timeRangeView(for: leg)
                                    }
                                    HStack {
                                        Text(leg.displayFlightNumberText)
                                            .appScaledFont(.footnote, scale: fontScale)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(blockAndLayoverText(for: leg, nextLegByID: connectionMap))
                                            .appScaledFont(.caption, scale: fontScale)
                                            .foregroundStyle(.primary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
        }
        .navigationTitle("Trip Id: \(trip.pairing)")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private var sortedLegs: [TripLeg] {
        trip.legs.sorted { lhs, rhs in
            let lhsUTC = LegConnectionTextBuilder.parseUTC(lhs.depUTC)
            let rhsUTC = LegConnectionTextBuilder.parseUTC(rhs.depUTC)
            if let lhsUTC, let rhsUTC {
                if lhsUTC == rhsUTC {
                    return lhs.leg < rhs.leg
                }
                return lhsUTC < rhsUTC
            }
            if lhs.depLocal == rhs.depLocal {
                return lhs.leg < rhs.leg
            }
            return lhs.depLocal < rhs.depLocal
        }
    }

    private var nextLegByID: [UUID: TripLeg] {
        var table: [UUID: TripLeg] = [:]
        let legs = sortedLegs
        guard legs.count > 1 else { return table }
        for index in 0..<(legs.count - 1) {
            table[legs[index].id] = legs[index + 1]
        }
        return table
    }

    private var groupedLegs: [OpenTimeLegSection] {
        let legs = sortedLegs

        var order: [String] = []
        var grouped: [String: [TripLeg]] = [:]
        for leg in legs {
            let key = ScheduleDateText.datePart(from: leg.depLocal)
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
            }
            grouped[key]?.append(leg)
        }

        return order.map { key in
            OpenTimeLegSection(
                id: key,
                label: ScheduleDateText.dayHeaderLabel(from: key),
                legs: grouped[key] ?? []
            )
        }
    }

    private var summaryBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.14, green: 0.14, blue: 0.16)
            : Color(red: 0.98, green: 0.98, blue: 0.99)
    }

    private var dayHeaderBackground: Color {
        ScheduleColors.dayHeaderBackground(for: colorScheme)
    }

    private var dateHeaderTextColor: Color {
        ScheduleColors.openTimeDateHeaderText(for: colorScheme)
    }

    private func iconName(for status: String) -> String {
        let normalized = status.uppercased()
        if normalized == "DH" || normalized == "CML" {
            return "paperplane.fill"
        }
        return "airplane"
    }

    private func timeRangeText(for leg: TripLeg) -> String {
        let dep = ScheduleDateText.timePart(from: leg.depLocal)
        let arr = ScheduleDateText.timePart(from: leg.arrLocal)
        return "\(dep) - \(arr)"
    }

    @ViewBuilder
    private func timeRangeView(for leg: TripLeg) -> some View {
        let diff = dayShift(from: leg.depLocal, to: leg.arrLocal)
        HStack(spacing: 0) {
            Text(timeRangeText(for: leg))
                .foregroundStyle(.primary)
            if diff != 0 {
                Text(" (\(diff > 0 ? "+" : "")\(diff)d)")
                    .foregroundStyle(.red)
            }
        }
        .appScaledFont(.subheadline, scale: fontScale)
    }

    private func dayShift(from depText: String, to arrText: String) -> Int {
        ScheduleDateText.dayShift(from: depText, to: arrText)
    }

    private func blockAndLayoverText(for leg: TripLeg, nextLegByID: [UUID: TripLeg]) -> String {
        LegConnectionTextBuilder.blockAndConnectionText(for: leg, nextLegByID: nextLegByID)
    }

    private var fontScale: CGFloat {
        let option = AppFontSizeOption(rawValue: appFontSizeOptionRawValue) ?? .medium
        return option.scaleFactor
    }
}

private struct OpenTimeLegSection: Identifiable {
    let id: String
    let label: String
    let legs: [TripLeg]
}
