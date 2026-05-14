import SwiftUI

struct IPadTimelineSidebarView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var selectedTripID: String?
    @Environment(\.colorScheme) private var colorScheme
    @State private var tripDataByTripID: [String: IPadTripDataCardInfo] = [:]
    @State private var deleteTripConfirmPairing: String? = nil

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

    private var legData: TimelineLegData {
        TimelineLegData(schedules: sidebarSchedules)
    }

    /// Section (day) IDs that contain at least one leg of the selected trip.
    /// Used to highlight date headers when a trip is selected.
    private var selectedSectionIDs: Set<String> {
        guard let selected = selectedTripID else { return [] }
        return Set(
            legData.daySections
                .filter { section in section.legs.contains { "\($0.payPeriod)|\($0.pairing)" == selected } }
                .map(\.id)
        )
    }

    /// IDs of legs that are the first leg of their trip in the visible timeline
    /// (sorted by depLocal). Used to insert a compact `Trip Id / Credit` summary
    /// card before the first leg of each trip.
    private var tripStartLegIDs: Set<UUID> {
        var seenTrips = Set<String>()
        var startIDs = Set<UUID>()
        let sorted = legData.allLegs.sorted { lhs, rhs in
            if lhs.depLocal == rhs.depLocal { return lhs.flight < rhs.flight }
            return lhs.depLocal < rhs.depLocal
        }
        for leg in sorted {
            let key = "\(leg.payPeriod)|\(leg.pairing)"
            if seenTrips.insert(key).inserted {
                startIDs.insert(leg.id)
            }
        }
        return startIDs
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
                            // Trip summary cards for trips whose first leg is in
                            // this day section. Rendered OUTSIDE the Section so
                            // they appear above the pinned date header, not below.
                            let startLegs = section.legs.filter { tripStartLegIDs.contains($0.id) }
                            if !startLegs.isEmpty {
                                ForEach(startLegs, id: \.id) { startLeg in
                                    let isTripSelected = selectedTripID == "\(startLeg.payPeriod)|\(startLeg.pairing)"
                                    tripSummaryCard(for: startLeg, isPast: section.isPast)
                                        .background(isTripSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                                        .overlay(alignment: .leading) {
                                            if isTripSelected {
                                                Rectangle().fill(Color.accentColor).frame(width: 3)
                                            }
                                        }
                                        .id("ipad.tripdata.\(startLeg.id.uuidString)")
                                }
                            }
                            Section {
                                ForEach(section.legs) { leg in
                                    let tripID = "\(leg.payPeriod)|\(leg.pairing)"
                                    let rowID = "\(tripID)|\(leg.leg)|\(leg.id.uuidString)"
                                    let isSelected = selectedTripID == tripID

                                    Group {
                                        Button {
                                            selectedTripID = selectedTripID == tripID ? nil : tripID
                                        } label: {
                                            TimelineFlightRow(
                                                leg: leg,
                                                isPast: isPastLeg(leg),
                                                fontScale: timelineFontScale,
                                                timeRangeText: timeRangeText(for: leg),
                                                dayDiff: ScheduleDateText.dayShift(
                                                    from: leg.depLocal,
                                                    to: leg.arrLocal
                                                ),
                                                blockText: blockText(for: leg)
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
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                deleteTripConfirmPairing = leg.pairing
                                            } label: {
                                                Label("Delete Trip", systemImage: "trash")
                                            }
                                        }

                                        if shouldShowLayover(leg: leg) {
                                            let station = leg.layoverStation ?? leg.arrAirport
                                            let hotel = leg.layoverHotelName
                                                ?? tripDataByTripID[Self.fileKey(for: leg)]?.hotelByStation[Self.normalizedStationKey(station)]
                                                ?? ""
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
                                                    fontScale: timelineFontScale
                                                )
                                                .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                                                .overlay(alignment: .leading) {
                                                    if isSelected {
                                                        Rectangle().fill(Color.accentColor).frame(width: 3)
                                                    }
                                                }
                                            }
                                            .id("ipad.layover.\(leg.id.uuidString)")
                                            .contextMenu {
                                                Button(role: .destructive) {
                                                    deleteTripConfirmPairing = leg.pairing
                                                } label: {
                                                    Label("Delete Trip", systemImage: "trash")
                                                }
                                            }
                                        }
                                    }
                                    .id(rowID)
                                }
                            } header: {
                                let isSectionSelected = selectedSectionIDs.contains(section.id)
                                let headerBg = ScheduleColors.dayHeaderBackground(for: colorScheme)
                                Text(section.label)
                                    .appScaledFont(.caption2, weight: .semibold, scale: timelineFontScale)
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
                       let firstRowID = firstRowID(for: id) {
                        withAnimation { proxy.scrollTo(firstRowID, anchor: .center) }
                    }
                }
                // Scroll the next upcoming leg (or in-progress leg) to the top
                // when the sidebar appears. Without this, the sidebar shows the
                // oldest legs at top, requiring the user to scroll to find what
                // is actually upcoming.
                .task {
                    for _ in 0..<3 {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        if let rowID = nextScrollTargetID() {
                            proxy.scrollTo(rowID, anchor: .top)
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
        .onAppear { refreshTripDataCards() }
        .onChange(of: viewModel.crewAccessSchedules) { _, _ in refreshTripDataCards() }
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
        if tripStartLegIDs.contains(target.id) {
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
    private func tripSummaryCard(for startLeg: TripLeg, isPast: Bool) -> some View {
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
        .background(tripCardBackground)
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
        guard let reference = LegConnectionTextBuilder.parseUTC(leg.arrUTC)
            ?? LegConnectionTextBuilder.parseUTC(leg.depUTC)
        else {
            return false
        }
        return reference < Date()
    }

    private func firstRowID(for tripID: String) -> String? {
        for section in legData.daySections {
            if let leg = section.legs.first(where: { "\($0.payPeriod)|\($0.pairing)" == tripID }) {
                return "\(tripID)|\(leg.leg)|\(leg.id.uuidString)"
            }
        }
        return nil
    }

    private func refreshTripDataCards() {
        Task.detached(priority: .utility) {
            let result = Self.loadTripDataFromCrewAccessImports()
            await MainActor.run {
                tripDataByTripID = result
            }
        }
    }

    private nonisolated static func loadTripDataFromCrewAccessImports() -> [String: IPadTripDataCardInfo] {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return [:]
        }
        let dir = documents.appendingPathComponent("CrewAccessImports", isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return [:] }

        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return [:]
        }

        // Key by the file's base name ("{date}_{tripId}", e.g. "2026-05-14_A70303R")
        // rather than tripId alone. This gives payPeriod-level disambiguation when
        // the same pairing appears in multiple pay periods.
        var latestFileByKey: [String: (date: Date, url: URL)] = [:]
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  url.pathExtension.lowercased() == "json"
            else {
                continue
            }
            let fileKey = url.deletingPathExtension().lastPathComponent.uppercased()
            guard !fileKey.isEmpty else { continue }
            let modifiedAt = values.contentModificationDate ?? .distantPast
            if latestFileByKey[fileKey].map({ modifiedAt > $0.date }) ?? true {
                latestFileByKey[fileKey] = (modifiedAt, url)
            }
        }

        var result: [String: IPadTripDataCardInfo] = [:]
        for (fileKey, (_, url)) in latestFileByKey {
            let tripID = fileKey
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(IPadCrewAccessTripSummaryCardJSON.self, from: data)
            else {
                continue
            }
            var hotelByStation: [String: String] = [:]
            for detail in decoded.hotelDetails {
                let (station, name) = IPadCrewAccessTripSummaryCardJSON.parseHotelDetail(detail)
                let stationKey = normalizedStationKey(station)
                if !stationKey.isEmpty && !name.isEmpty {
                    hotelByStation[stationKey] = name
                }
            }

            let legacyHotelDetails = decoded.hotelDetails.filter { $0.hasPrefix("Hotel details ") }
            if !legacyHotelDetails.isEmpty {
                var legacyHotelIndex = 0
                let sortedItems = decoded.items.sorted { $0.sequence < $1.sequence }
                for index in sortedItems.indices.dropLast() {
                    guard legacyHotelIndex < legacyHotelDetails.count else { break }
                    let item = sortedItems[index]
                    let next = sortedItems[index + 1]
                    guard let endDate = LegConnectionTextBuilder.parseUTC(item.endUtc),
                          let nextStartDate = LegConnectionTextBuilder.parseUTC(next.startUtc),
                          nextStartDate.timeIntervalSince(endDate) >= 180 * 60 else {
                        continue
                    }
                    let station = normalizedStationKey(item.arrAirport)
                    guard !station.isEmpty, hotelByStation[station] == nil else {
                        legacyHotelIndex += 1
                        continue
                    }
                    let (_, name) = IPadCrewAccessTripSummaryCardJSON.parseHotelDetail(legacyHotelDetails[legacyHotelIndex])
                    if !name.isEmpty { hotelByStation[station] = name }
                    legacyHotelIndex += 1
                }
            }

            result[tripID] = IPadTripDataCardInfo(
                hotelByStation: hotelByStation,
                creditTime: decoded.creditTime?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    private nonisolated static func normalizedTripKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private nonisolated static func normalizedStationKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

private struct IPadTripDataCardInfo {
    let hotelByStation: [String: String]
    let creditTime: String?
}

private struct IPadCrewAccessTripSummaryCardJSON: Decodable {
    let tripId: String
    let creditTime: String?
    let hotelDetails: [String]
    let items: [IPadCrewAccessTripSummaryCardItemJSON]

    private enum CodingKeys: String, CodingKey {
        case tripId
        case creditTime
        case hotelDetails
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tripId = try container.decode(String.self, forKey: .tripId)
        creditTime = try container.decodeIfPresent(String.self, forKey: .creditTime)
        hotelDetails = try container.decodeIfPresent([String].self, forKey: .hotelDetails) ?? []
        items = try container.decodeIfPresent([IPadCrewAccessTripSummaryCardItemJSON].self, forKey: .items) ?? []
    }

    static func parseHotelDetail(_ detail: String) -> (station: String, hotelName: String) {
        if detail.hasPrefix("Hotel details ") {
            return parseLegacyHotelDetail(detail)
        }

        guard let colonRange = detail.range(of: ": ") else {
            return (detail.trimmingCharacters(in: .whitespaces), "")
        }
        let station = String(detail[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        var rest = String(detail[colonRange.upperBound...])
        if let parenRange = rest.range(of: " (", options: .backwards) {
            rest = String(rest[..<parenRange.lowerBound])
        }
        let words = rest.split(separator: " ").map(String.init)
        var hotelWords: [String] = []
        for word in words {
            let dashCount = word.filter { $0 == "-" }.count
            if word.hasPrefix("+") || dashCount >= 2 { break }
            hotelWords.append(word)
        }
        return (station, hotelWords.joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }

    private static func parseLegacyHotelDetail(_ detail: String) -> (station: String, hotelName: String) {
        guard let hotelRange = detail.range(of: "Hotel: ") else { return ("", "") }
        let afterHotel = String(detail[hotelRange.upperBound...])
        let hotelOnly: String
        if let transportRange = afterHotel.range(of: " Hotel Transport:") {
            hotelOnly = String(afterHotel[..<transportRange.lowerBound])
        } else {
            hotelOnly = afterHotel
        }

        let cleaned = hotelOnly
            .replacingOccurrences(of: " UPS Only", with: "")
            .replacingOccurrences(of: "UPS Only ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let words = cleaned.split(separator: " ").map(String.init)
        var hotelWords: [String] = []
        for word in words {
            let digitCount = word.filter(\.isNumber).count
            let dashCount = word.filter { $0 == "-" }.count
            if word.hasPrefix("+") || digitCount >= 3 || dashCount >= 2 { break }
            hotelWords.append(word)
        }
        return ("", hotelWords.joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }
}

private struct IPadCrewAccessTripSummaryCardItemJSON: Decodable {
    let sequence: Int
    let arrAirport: String
    let startUtc: String
    let endUtc: String
}

#Preview {
    IPadTimelineSidebarView(selectedTripID: .constant(nil))
        .environmentObject(AppViewModel.shared)
        .frame(width: 420)
}
