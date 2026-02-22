import SwiftUI

struct OpenTimeTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    private let ppCardBackground = Color(red: 0.24, green: 0.10, blue: 0.06)
    private let ppCardForeground = Color(red: 0.96, green: 0.74, blue: 0.06)
    private let poBlueDark = Color(red: 0.00, green: 0.36, blue: 0.80)
    private let pcBrownDark = Color(red: 0.26, green: 0.14, blue: 0.07)
    private let poBlueLight = Color.blue
    private let pcBrownLight = Color(red: 0.78, green: 0.62, blue: 0.45)

    var body: some View {
        NavigationStack {
            Group {
                if ppSections.isEmpty {
                    Text("No fetched data yet. Use Settings to fetch from TripBoard.")
                        .appScaledFont(.footnote, scale: fontScale)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(ppSections) { pp in
                                Text(pp.label)
                                    .appScaledFont(.headline, weight: .bold, scale: fontScale)
                                    .foregroundStyle(ppCardForeground)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(ppCardBackground)
                                    .padding(.top, 8)

                                ForEach(pp.daySections) { day in
                                    Text(day.label)
                                        .appScaledFont(.subheadline, weight: .semibold, scale: fontScale)
                                        .foregroundStyle(dateHeaderTextColor)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 6)
                                        .background(dayHeaderBackground)

                                    ForEach(day.rows) { row in
                                        NavigationLink {
                                            OpenTimeTripDetailView(
                                                trip: row.trip,
                                                titleColor: colorForRequestType(row.requestType)
                                            )
                                        } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack {
                                                    Text(row.pairing)
                                                        .appScaledFont(.subheadline, scale: fontScale)
                                                        .foregroundStyle(colorForRequestType(row.requestType))
                                                    Spacer()
                                                    Text("Credit: \(row.credit)")
                                                        .appScaledFont(.subheadline, scale: fontScale)
                                                        .foregroundStyle(Color.primary.opacity(0.85))
                                                }
                                                Text(row.route)
                                                    .appScaledFont(.subheadline, weight: .semibold, scale: fontScale)
                                                    .foregroundStyle(colorForRequestType(row.requestType))
                                                HStack {
                                                    Text("\(row.startLocal) -> \(row.endLocal)")
                                                        .appScaledFont(.subheadline, scale: fontScale)
                                                        .foregroundStyle(Color.primary.opacity(0.75))
                                                    Spacer()
                                                    if let daysText = tripDaysText(startLocal: row.startLocal, endLocal: row.endLocal) {
                                                        Text(daysText)
                                                            .appScaledFont(.subheadline, scale: fontScale)
                                                            .foregroundStyle(Color.primary.opacity(0.75))
                                                    }
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
                }
            }
#if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
#endif
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Spacer()
                    Text("OpenTime")
                        .appScaledFont(.headline, weight: .semibold, scale: fontScale)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.vertical, 8)
                .background(.background)
            }
        }
    }

    private var ppSections: [OpenTimePPSection] {
        OpenTimeSectionBuilder.build(schedules: viewModel.schedules)
    }

    private func tripDaysText(startLocal: String, endLocal: String) -> String? {
        let startDateText = ScheduleDateText.datePart(from: startLocal)
        let endDateText = ScheduleDateText.datePart(from: endLocal)
        guard let start = SharedDateFormatters.localDayInput.date(from: startDateText),
              let end = SharedDateFormatters.localDayInput.date(from: endDateText)
        else {
            return nil
        }
        let days = (Calendar(identifier: .gregorian).dateComponents([.day], from: start, to: end).day ?? 0) + 1
        guard days > 0 else { return nil }
        return "(\(days)days)"
    }

    private func colorForRequestType(_ requestType: String) -> Color {
        let poBlue = colorScheme == .dark ? poBlueLight : poBlueDark
        let pcBrown = colorScheme == .dark ? pcBrownLight : pcBrownDark
        switch requestType.uppercased() {
        case "PO":
            return pcBrown
        case "PC":
            return poBlue
        default:
            return .primary
        }
    }

    private var dayHeaderBackground: Color {
        ScheduleColors.dayHeaderBackground(for: colorScheme)
    }

    private var dateHeaderTextColor: Color {
        ScheduleColors.openTimeDateHeaderText(for: colorScheme)
    }

    private var fontScale: CGFloat {
        let option = AppFontSizeOption(rawValue: appFontSizeOptionRawValue) ?? .medium
        return option.scaleFactor
    }
}
