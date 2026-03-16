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
    private let topAnchorID = "opentime.top.anchor"
    @State private var isRefreshingOpenTime = false
    @State private var refreshMessage: String?
    @State private var refreshMessageIsError = false
    @State private var lastFetchMessage: String?
    @State private var hideUpToDateTask: Task<Void, Never>?

    private static let lastFetchFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd, yyyy 'at' HH:mm"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Group {
                    if ppSections.isEmpty {
                        ScrollView {
                            Color.clear
                                .frame(height: 0)
                                .id(topAnchorID)
                            Text("No fetched data yet. Use Settings to fetch from TripBoard.")
                                .appScaledFont(.footnote, scale: fontScale)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                        }
                        .refreshable {
                            await refreshOpenTime(using: proxy)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                Color.clear
                                    .frame(height: 0)
                                    .id(topAnchorID)
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
                                                    HStack {
                                                        Text(row.route)
                                                            .appScaledFont(.subheadline, weight: .semibold, scale: fontScale)
                                                            .foregroundStyle(colorForRequestType(row.requestType))
                                                        Spacer()
                                                        if let daysText = tripDaysText(startLocal: row.startLocal, endLocal: row.endLocal) {
                                                            Text(daysText)
                                                                .appScaledFont(.subheadline, scale: fontScale)
                                                                .foregroundStyle(Color.primary.opacity(0.75))
                                                        }
                                                    }
                                                    HStack {
                                                        Text("\(row.startLocal) -> \(row.endLocal)")
                                                            .appScaledFont(.subheadline, scale: fontScale)
                                                            .foregroundStyle(Color.primary.opacity(0.75))
                                                        Spacer()
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
                        .refreshable {
                            await refreshOpenTime(using: proxy)
                        }
                    }
                }
            }
#if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
#endif
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 4) {
                    HStack {
                        Spacer()
                        Text("OpenTime")
                            .appScaledFont(.headline, weight: .semibold, scale: fontScale)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    if let lastFetchMessage {
                        Text(lastFetchMessage)
                            .appScaledFont(.caption2, scale: fontScale)
                            .foregroundStyle(.secondary)
                    }
                    if isRefreshingOpenTime {
                        Text("Refreshing TripBoard data...")
                            .appScaledFont(.caption, scale: fontScale)
                            .foregroundStyle(.secondary)
                    } else if let refreshMessage {
                        Text(refreshMessage)
                            .appScaledFont(.caption, scale: fontScale)
                            .foregroundStyle(refreshMessageIsError ? .red : .secondary)
                    }
                }
                .padding(.vertical, 8)
                .background(.background)
            }
        }
    }

    private var ppSections: [OpenTimePPSection] {
        OpenTimeSectionBuilder.build(schedules: viewModel.schedules)
    }

    private func refreshOpenTime(using proxy: ScrollViewProxy) async {
        hideUpToDateTask?.cancel()
        hideUpToDateTask = nil
        let (previousLastSyncAt, wasShowingLoginSheet) = await MainActor.run {
            (viewModel.lastSyncAt, viewModel.isShowingLoginSheet)
        }
        await MainActor.run {
            isRefreshingOpenTime = true
            refreshMessage = nil
            refreshMessageIsError = false
        }
        await viewModel.syncTapped()
        while await MainActor.run(body: { viewModel.isSyncing }) {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let (currentLastSyncAt, currentErrorMessage, didLastFetchFail, isShowingLoginSheet) = await MainActor.run {
            (viewModel.lastSyncAt, viewModel.errorMessage, viewModel.didLastFetchFail, viewModel.isShowingLoginSheet)
        }
        let didSyncSucceed = currentLastSyncAt != previousLastSyncAt
        let hasVisibleError = (currentErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let loginRequired = isShowingLoginSheet || wasShowingLoginSheet
        await MainActor.run {
            isRefreshingOpenTime = false
            if let currentLastSyncAt {
                lastFetchMessage = "Last Fetch \(Self.lastFetchFormatter.string(from: currentLastSyncAt))"
            }
            if didSyncSucceed {
                refreshMessage = "TripBoard refresh complete."
                refreshMessageIsError = false
                hideUpToDateTask = Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        if refreshMessage == "TripBoard refresh complete." {
                            refreshMessage = nil
                            refreshMessageIsError = false
                        }
                    }
                }
            } else if loginRequired {
                refreshMessage = "Login required. Please sign in and try again."
                refreshMessageIsError = true
            } else if !didLastFetchFail && !hasVisibleError {
                refreshMessage = "Data is up to date."
                refreshMessageIsError = false
                hideUpToDateTask = Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        if refreshMessage == "Data is up to date." {
                            refreshMessage = nil
                            refreshMessageIsError = false
                        }
                    }
                }
            } else {
                refreshMessage = currentErrorMessage ?? "TripBoard refresh did not complete."
                refreshMessageIsError = true
            }
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(topAnchorID, anchor: .top)
            }
        }
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
