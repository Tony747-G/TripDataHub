import SwiftUI

struct TimelineNextReportCountdownView: View {
    let windows: [TimelineNextReportTrip]
    let displayTimeZone: TimeZone
    let zoneCode: String
    let fontScale: CGFloat
    let normalCountdownColor: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let presentation = TimelineNextReportCountdownBuilder.presentation(
                from: windows,
                now: context.date,
                displayTimeZone: displayTimeZone,
                zoneCode: zoneCode
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.titleText)
                        .appScaledFont(.caption, weight: .bold, scale: fontScale)
                        .foregroundStyle(.secondary)
                    Text(presentation.reportDateTimeText)
                        .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                        .foregroundStyle(normalCountdownColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(presentation.remainingText)
                        .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                        .foregroundStyle(
                            presentation.urgency == .urgent ? Color.red : normalCountdownColor
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.thinMaterial)
                .accessibilityIdentifier("timeline.nextReportCountdown")
            }
        }
    }
}

/// Timeline row colouring contract (INV-012):
///
/// - White (`originalScheduled`) — the schedule as first observed, still ahead.
/// - Amber (`revisedScheduled`)  — the schedule was revised and the leg is still active or future.
/// - Gray  (`actual`)            — the leg is finished: both actuals observed, or simply past.
///
/// Completion outranks revision. A leg that was revised and has since been flown is history, so it
/// is gray; leaving it amber would mark every once-delayed past flight as "needs attention"
/// forever. A leg with only an ATD is airborne, not finished, so it keeps its scheduled colour.
enum TimelineFlightVisualState: Equatable {
    case originalScheduled
    case revisedScheduled
    case actual

    static func resolve(for leg: TripLeg, legacyIsPast: Bool) -> Self {
        if leg.isCompleted { return .actual }
        if legacyIsPast { return .actual }
        if leg.hasRevisedSchedule { return .revisedScheduled }
        return .originalScheduled
    }
}

struct FriendMatchPerson: Identifiable, Hashable {
    let id: String
    let displayName: String
    let subtitle: String
    let avatarImageData: Data?
}

struct FriendMatchPresentation: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let friends: [FriendMatchPerson]
}

struct FriendMatchPresentationView: View {
    let presentation: FriendMatchPresentation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(presentation.friends) { friend in
                ProfileCard(
                    avatarImageData: friend.avatarImageData ?? Data(),
                    displayName: friend.displayName,
                    subtitle: friend.subtitle,
                    avatarSize: 44
                )
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(presentation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Shared flight row used by TimelineTabView and ScheduleTimelineRendererView.
///
/// All computed values (timeRangeText, dayDiff, blockConnectionDisplay) are pre-computed by the caller,
/// keeping UTC/LCL logic and friend-match state entirely in the owning view.
/// `iconColor` defaults to `.primary`; pass `friendMatchAmber` for friend highlights.
/// `onFriendMatchTap` is nil in ScheduleTimelineRendererView (Friends Timeline, no tap needed).
struct TimelineFlightRow: View {
    let leg: TripLeg
    let isPast: Bool
    let fontScale: CGFloat
    let timeRangeText: String
    let dayDiff: Int
    let blockConnectionDisplay: BlockConnectionDisplay
    var iconColor: Color = .primary
    /// Transient UI state (selection, highlight) that must take precedence over the
    /// schedule-state tint. Rendered in the same layer as `rowBackground` so it cannot be
    /// painted over by it.
    var backgroundOverride: Color? = nil
    var onFriendMatchTap: (() -> Void)? = nil
    var onFlightTap: (() -> Void)? = nil

    /// Minimum tap target for the friend-match icon. The icon itself is 28pt wide, which is below
    /// the 44pt Human Interface Guidelines minimum, so the gesture gets its own padded hit area.
    private static let minimumTapTarget: CGFloat = 44

    var body: some View {
        if let tap = onFlightTap {
            if let friendTap = onFriendMatchTap {
                flightDetailTappable(tap)
                    .accessibilityAction(named: "Show friends on this flight", friendTap)
            } else {
                flightDetailTappable(tap)
            }
        } else if let tap = onFriendMatchTap {
            rowContent
                .contentShape(Rectangle())
                .onTapGesture(perform: tap)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows friends on this flight")
        } else {
            rowContent
        }
    }

    private func flightDetailTappable(_ tap: @escaping () -> Void) -> some View {
        rowContent
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows flight log details")
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 12) {
            let resolvedIconColor: Color = isPast ? .gray : iconColor
            let iconStatus = leg.flight.caseInsensitiveCompare("GND") == .orderedSame
                ? "GND"
                : leg.status
            flightIcon(status: iconStatus, color: resolvedIconColor)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("\(leg.depAirport) - \(leg.arrAirport)")
                        .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                    Spacer()
                    HStack(spacing: 0) {
                        Text(timeRangeText)
                            .foregroundStyle(isPast ? .gray : .primary)
                        Text(timelineDiffLabel(dayDiff))
                            .foregroundStyle(isPast ? .gray : (dayDiff == 0 ? .primary : .red))
                    }
                    .appScaledFont(.subheadline, scale: fontScale)
                }
                HStack {
                    Text(leg.displayFlightNumberText)
                        .appScaledFont(.footnote, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                    Spacer()
                    BlockConnectionDisplayView(
                        display: blockConnectionDisplay,
                        fontScale: fontScale,
                        foregroundColor: isPast ? .gray : .primary
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(rowBackground)
    }

    @ViewBuilder
    private func flightIcon(status: String, color: Color) -> some View {
        let icon = MaterialIconView(
            codePoint: TimelineLegIconSupport.codePoint(for: status),
            size: 20 * fontScale,
            color: color,
            fallbackSystemName: TimelineLegIconSupport.fallbackSystemName(for: status)
        )
        .frame(width: 28 * fontScale, alignment: .center)

        if let tap = onFriendMatchTap, onFlightTap != nil {
            // The row tap opens the Flight Log, so the friend-match affordance needs its own
            // target. `frame(minWidth:minHeight:)` before `contentShape` expands the hit area to
            // 44pt without changing the 28pt visual column width.
            icon
                .frame(
                    minWidth: Self.minimumTapTarget,
                    minHeight: Self.minimumTapTarget
                )
                .contentShape(Rectangle())
                .highPriorityGesture(TapGesture().onEnded(tap))
                .accessibilityLabel("Show friends on this flight")
                .accessibilityAddTraits(.isButton)
        } else {
            icon
        }
    }

    private var rowBackground: Color {
        if let backgroundOverride { return backgroundOverride }
        switch TimelineFlightVisualState.resolve(for: leg, legacyIsPast: isPast) {
        case .originalScheduled:
            return Color.clear
        case .revisedScheduled:
            return Color.orange.opacity(0.18)
        case .actual:
            return Color.gray.opacity(0.10)
        }
    }
}

struct FlightLegDetailSheet: View {
    let leg: TripLeg
    let onSaveRegistration: (String?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var registration = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        let presentation = FlightLogPresentation(leg: leg)
        NavigationStack {
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    detailRow("DATE:", presentation.dateUTC)
                    detailRow("FLT:", leg.flight.isEmpty ? "—" : leg.flight)
                    detailRow("TYPE:", display(leg.aircraftType))
                    GridRow {
                        Text("A/C:")
                        TextField("—", text: $registration)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Aircraft registration")
                    }
                    detailRow("FR:", display(leg.depAirport))
                    detailRow("TO:", display(leg.arrAirport))
                    GridRow { Color.clear.frame(height: 6); Color.clear.frame(height: 6) }
                    detailRow("STD:", scheduleTime(original: leg.originalSTDUTC, current: leg.stdUTC))
                    detailRow("STA:", scheduleTime(original: leg.originalSTAUTC, current: leg.staUTC))
                    detailRow("ATD:", utcTime(leg.atdUTC))
                    detailRow("ATA:", utcTime(leg.ataUTC))
                    GridRow { Color.clear.frame(height: 6); Color.clear.frame(height: 6) }
                    detailRow("TOTAL TIME:", display(leg.block))
                    GridRow { Color.clear.frame(height: 6); Color.clear.frame(height: 6) }
                    // Departure-first, not max(). These are two independent observations, and
                    // taking the later one labelled an arrival-only observation as though it were
                    // when the departure schedule was published.
                    detailRow("Schedule Created:", observedUTC(
                        leg.scheduledDepartureObservedAtUTC
                            ?? leg.scheduledArrivalObservedAtUTC
                    ))
                    detailRow(presentation.importLabel, presentation.importedAtUTC)
                }
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("Flight Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveRegistration() }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .onAppear { registration = leg.aircraftRegistration ?? "" }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
            Text(value).textSelection(.enabled)
        }
    }

    private func saveRegistration() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSaveRegistration(registration)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func display(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "—" : trimmed
    }

    private func scheduleTime(original: String?, current: String?) -> String {
        let originalText = utcTime(original)
        let currentText = utcTime(current)
        guard originalText != "—", currentText != "—", originalText != currentText else {
            return currentText != "—" ? currentText : originalText
        }
        return "\(originalText) → \(currentText)"
    }

    private func utcTime(_ value: String?) -> String {
        guard let date = LegConnectionTextBuilder.parseUTC(value) else { return "—" }
        return Self.utcTimeFormatter.string(from: date)
    }

    private func observedUTC(_ value: String?) -> String {
        guard let date = LegConnectionTextBuilder.parseUTC(value) else { return "—" }
        return Self.utcObservedFormatter.string(from: date)
    }

    private static let utcTimeFormatter = formatter("HH:mm'Z'")
    private static let utcObservedFormatter = formatter("yyyy-MM-dd HH:mm'Z'")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}

struct FlightLogPresentation: Equatable {
    let dateUTC: String
    let importLabel: String
    let importedAtUTC: String

    init(leg: TripLeg) {
        dateUTC = Self.format(leg.atdUTC ?? leg.plannedDepartureUTC, with: Self.dateFormatter)
        let hasCompleteActuals = leg.atdUTC != nil && leg.ataUTC != nil
        importLabel = hasCompleteActuals ? "ATD/ATA Imported:" : "Trip Imported:"
        importedAtUTC = Self.format(
            hasCompleteActuals ? leg.actualsImportedAtUTC : leg.tripImportedAtUTC,
            with: Self.timestampFormatter
        )
    }

    private static func format(_ value: String?, with formatter: DateFormatter) -> String {
        guard let date = LegConnectionTextBuilder.parseUTC(value) else { return "—" }
        return formatter.string(from: date)
    }

    private static let dateFormatter = formatter("yyyy-MM-dd")
    private static let timestampFormatter = formatter("yyyy-MM-dd HH:mm'Z'")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}

struct BlockConnectionDisplayView: View {
    let display: BlockConnectionDisplay
    let fontScale: CGFloat
    let foregroundColor: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(display.blockText)
                .lineLimit(1)
            if let connectionText = display.connectionText {
                Text(connectionText)
                    .lineLimit(1)
            }
        }
        .appScaledFont(.caption, scale: fontScale)
        .foregroundStyle(foregroundColor)
        .multilineTextAlignment(.trailing)
        .minimumScaleFactor(0.8)
        .allowsTightening(true)
    }
}

struct TimelineManualOperationalRow: View {
    let event: ManualOperationalEvent
    let isPast: Bool
    let fontScale: CGFloat
    let timeRangeText: String
    let dayDiff: Int

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 17 * fontScale, weight: .semibold))
                .foregroundStyle(iconForegroundColor)
                .frame(width: 28 * fontScale, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(event.code.rawValue)
                        .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                    Spacer()
                    HStack(spacing: 0) {
                        Text(timeRangeText)
                            .foregroundStyle(isPast ? .gray : .primary)
                        Text(timelineDiffLabel(dayDiff))
                            .foregroundStyle(isPast ? .gray : (dayDiff == 0 ? .primary : .red))
                    }
                    .appScaledFont(.subheadline, scale: fontScale)
                }
                HStack {
                    Text(event.crewBase.displayName)
                        .appScaledFont(.footnote, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                    Spacer()
                    Text("Operational")
                        .appScaledFont(.caption, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var iconName: String {
        switch event.code {
        case .reserveA, .reserveB, .reserveC, .reserveD:
            return "phone.fill"
        case .lco, .rcid:
            return "phone.fill"
        case .hot:
            return "flame.fill"
        case .cq12, .cq6:
            return "display"
        }
    }

    private var iconForegroundColor: Color {
        if isPast { return .gray }
        switch event.code {
        case .hot:
            return Color.accentColor
        case .reserveA, .reserveB, .reserveC, .reserveD, .lco, .rcid, .cq12, .cq6:
            return .primary
        }
    }
}

/// Shared layover card used by TimelineTabView and ScheduleTimelineRendererView.
///
/// Hotel name, duration, and arrival date label are pre-computed by the caller.
/// `iconColor` defaults to `.primary`; pass `friendMatchAmber` for rest-overlap highlights.
/// `onFriendMatchTap` is nil in ScheduleTimelineRendererView (Friends Timeline, no tap needed).
struct TimelineLayoverCard: View {
    let station: String
    let hotel: String
    let durationText: String
    let remainingText: String
    let arrLocalDateLabel: String
    let isPast: Bool
    let fontScale: CGFloat
    var iconColor: Color = .primary
    var onFriendMatchTap: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var dateHeaderTextColor: Color {
        ScheduleColors.timelineDateHeaderText(for: colorScheme)
    }

    private var dateCardBackground: Color {
        ScheduleColors.dayHeaderBackground(for: colorScheme)
    }

    var body: some View {
        if let tap = onFriendMatchTap {
            cardContent
                .contentShape(Rectangle())
                .onTapGesture(perform: tap)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows friends with overlapping layover")
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        VStack(spacing: 0) {
            if !arrLocalDateLabel.isEmpty {
                Text(arrLocalDateLabel)
                    .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                    .foregroundStyle(isPast ? .gray : dateHeaderTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .background(dateCardBackground)
            }

            HStack(alignment: .center, spacing: 12) {
                let resolvedIconColor: Color = isPast ? .gray : iconColor
                Image(systemName: "bed.double.fill")
                    .font(.system(size: 16 * fontScale))
                    .foregroundStyle(resolvedIconColor)
                    .frame(width: 28 * fontScale, alignment: .center)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Layover at \(station)")
                            .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                            .foregroundStyle(isPast ? .gray : .primary)
                        Spacer()
                        if !durationText.isEmpty {
                            Text("Rest: \(durationText)")
                                .appScaledFont(.caption, scale: fontScale)
                                .foregroundStyle(isPast ? .gray : .primary)
                        }
                    }
                    HStack {
                        if !hotel.isEmpty {
                            Text(hotel)
                                .appScaledFont(.footnote, scale: fontScale)
                                .foregroundStyle(isPast ? .gray : .secondary)
                        }
                        Spacer()
                        if !remainingText.isEmpty {
                            Text("\(remainingText) left")
                                .appScaledFont(.caption, scale: fontScale)
                                .foregroundStyle(isPast ? .gray : Color(red: 0.95, green: 0.58, blue: 0.12))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
    }
}
