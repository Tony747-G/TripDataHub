import SwiftUI

enum ImportPreviewPresentationPolicy {
    static func browserPreviewIsPresented(
        pendingImportID: UUID?,
        presentsImportPreview: Bool
    ) -> Bool {
        presentsImportPreview && pendingImportID != nil
    }

    static func externalPreviewIsPresented(
        pendingImportID: UUID?,
        browserIsPresented: Bool
    ) -> Bool {
        pendingImportID != nil && !browserIsPresented
    }
}

struct ImportReplacementConfirmation: Identifiable, Equatable {
    let expectedReplacementIDs: Set<String>
    let message: String

    var id: String {
        expectedReplacementIDs.sorted().joined(separator: "|")
    }

    init?(candidates: [AppViewModel.TripImportReplacementCandidate]) {
        guard !candidates.isEmpty else { return nil }
        expectedReplacementIDs = Set(candidates.map(\.id))
        message = candidates.map { candidate in
            switch candidate.reason {
            case .sameTripID:
                return "Trip \(candidate.tripId) already exists.\nThe imported schedule contains revisions and will replace the current version."
            case .timeOverlap:
                return "Trip \(candidate.tripId) overlaps this import.\nIt will be removed from Timeline and synced devices."
            }
        }
        .joined(separator: "\n\n")
    }
}

struct ImportPreviewTripPresentation {
    struct DaySection: Identifiable {
        let id: String
        let label: String
        let legs: [TripLeg]
    }

    let tripID: String
    let dateRangeText: String
    let legCountText: String
    let legs: [TripLeg]
    let daySections: [DaySection]

    init(pending: PendingImport) {
        self.init(
            tripID: pending.tripId,
            fallbackTripDate: pending.tripDate,
            legs: pending.parsedSchedule?.legs ?? []
        )
    }

    init(tripID: String, fallbackTripDate: String, legs: [TripLeg]) {
        self.tripID = tripID
        self.legs = legs
        dateRangeText = Self.dateRangeText(for: legs, fallbackTripDate: fallbackTripDate)
        legCountText = "\(legs.count) \(legs.count == 1 ? "leg" : "legs")"
        daySections = Self.daySections(for: legs)
    }

    private static func daySections(for legs: [TripLeg]) -> [DaySection] {
        var orderedKeys: [String] = []
        var legsByDay: [String: [TripLeg]] = [:]

        for leg in legs {
            let key = ScheduleDateText.datePart(from: leg.depLocal)
            if legsByDay[key] == nil {
                orderedKeys.append(key)
            }
            legsByDay[key, default: []].append(leg)
        }

        return orderedKeys.map { key in
            DaySection(
                id: key,
                label: ScheduleDateText.dayHeaderLabel(from: key),
                legs: legsByDay[key] ?? []
            )
        }
    }

    private static func dateRangeText(for legs: [TripLeg], fallbackTripDate: String) -> String {
        let dates = legs.flatMap { leg in
            [leg.depLocal, leg.arrLocal].compactMap { value in
                SharedDateFormatters.localDayInput.date(
                    from: ScheduleDateText.datePart(from: value)
                )
            }
        }

        guard let start = dates.min(), let end = dates.max() else {
            return formattedFallbackDate(fallbackTripDate)
        }
        if Calendar(identifier: .gregorian).isDate(start, inSameDayAs: end) {
            return "\(monthDayFormatter.string(from: start)), \(yearFormatter.string(from: start))"
        }

        let startText = monthDayFormatter.string(from: start)
        let endText = monthDayFormatter.string(from: end)
        let startYear = yearFormatter.string(from: start)
        let endYear = yearFormatter.string(from: end)
        if startYear == endYear {
            return "\(startText) – \(endText), \(endYear)"
        }
        return "\(startText), \(startYear) – \(endText), \(endYear)"
    }

    private static func formattedFallbackDate(_ value: String) -> String {
        guard let date = crewAccessDateFormatter.date(from: value.uppercased()) else {
            return value
        }
        return "\(monthDayFormatter.string(from: date)), \(yearFormatter.string(from: date))"
    }

    private static let crewAccessDateFormatter = formatter("ddMMMyyyy", locale: "en_US_POSIX")
    private static let monthDayFormatter = formatter("MMM d", locale: "en_US")
    private static let yearFormatter = formatter("yyyy", locale: "en_US_POSIX")

    private static func formatter(_ format: String, locale: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: locale)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }
}

enum ImportPreviewStatusPolicy {
    private static let routineMessages: Set<String> = [
        "Parsed CrewAccess PDF. Review and confirm import.",
        "Another import is waiting for review. Confirm or dismiss the current import first.",
        "Another import is queued. Confirm or dismiss the current import first."
    ]

    static func actionableMessage(_ message: String?) -> String? {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !routineMessages.contains(trimmed) else { return nil }
        return trimmed
    }
}

struct ImportPreviewView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    @State private var replacementConfirmation: ImportReplacementConfirmation?

    var body: some View {
        Group {
            if let pending = viewModel.pendingImport {
                preview(pending)
            } else {
                ContentUnavailableView(
                    "No Pending Import",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Open a trip in CrewAccess to start an import.")
                )
            }
        }
        .navigationTitle("Import Preview")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .alert(item: $replacementConfirmation) { confirmation in
            Alert(
                title: Text("Replace Existing Trip?"),
                message: Text(confirmation.message),
                primaryButton: .destructive(Text("Replace Trip")) {
                    Task {
                        if await viewModel.confirmPendingImport(
                            expectedReplacementIDs: confirmation.expectedReplacementIDs
                        ) {
                            dismiss()
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func preview(_ pending: PendingImport) -> some View {
        let presentation = ImportPreviewTripPresentation(pending: pending)
        let replacements = viewModel.pendingImportReplacementCandidates

        return List {
            ImportPreviewTripSummary(
                tripID: presentation.tripID,
                dateRangeText: presentation.dateRangeText,
                legCountText: presentation.legCountText,
                fontScale: fontScale
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(summaryBackground)

            if viewModel.hasQueuedImport {
                Section {
                    Label(
                        "Another import is queued. It will open after you import or cancel this trip.",
                        systemImage: "tray.full"
                    )
                    .appScaledFont(.footnote, scale: fontScale)
                    .foregroundStyle(.secondary)
                }
            }

            if let message = ImportPreviewStatusPolicy.actionableMessage(
                viewModel.crewAccessImportMessage
            ) {
                Section("Import Issue") {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .appScaledFont(.footnote, scale: fontScale)
                        .foregroundStyle(.red)
                }
            }

            if presentation.daySections.isEmpty {
                Section("Legs") {
                    Text("No parsed legs available.")
                        .appScaledFont(.footnote, scale: fontScale)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(presentation.daySections) { section in
                    Section {
                        ForEach(section.legs) { leg in
                            TimelineFlightRow(
                                leg: leg,
                                isPast: false,
                                fontScale: fontScale,
                                timeRangeText: Self.timeRangeText(for: leg),
                                dayDiff: ScheduleDateText.dayShift(
                                    from: leg.depLocal,
                                    to: leg.arrLocal
                                ),
                                blockConnectionDisplay: nil,
                                density: .compact
                            )
                            .listRowInsets(EdgeInsets())
                        }
                    } header: {
                        Text(section.label)
                            .appScaledFont(.footnote, weight: .bold, scale: fontScale)
                            .foregroundStyle(ScheduleColors.timelineDateHeaderText(for: colorScheme))
                            .textCase(nil)
                            .padding(.bottom, -8)
                    }
                }
            }

            if !replacements.isEmpty {
                Section {
                    ForEach(replacements) { candidate in
                        switch candidate.reason {
                        case .sameTripID:
                            Label(
                                "Existing trip \(candidate.tripId) will be replaced.",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .appScaledFont(.footnote, weight: .semibold, scale: fontScale)
                            .foregroundStyle(.orange)
                        case .timeOverlap:
                            Label(
                                "This trip overlaps Trip \(candidate.tripId), which will be removed from Timeline and synced devices.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .appScaledFont(.footnote, weight: .semibold, scale: fontScale)
                            .foregroundStyle(.red)
                        }
                    }
                }
            }

            if !pending.errors.isEmpty {
                Section("Import Blocked") {
                    ForEach(pending.errors) { error in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(error.message)
                                .appScaledFont(.subheadline, weight: .semibold, scale: fontScale)
                                .foregroundStyle(.red)
                            Text(error.remediation)
                                .appScaledFont(.caption, scale: fontScale)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !pending.warnings.isEmpty {
                Section("Review Before Import") {
                    ForEach(pending.warnings) { warning in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(warning.code.displayTitle)
                                .appScaledFont(.subheadline, weight: .semibold, scale: fontScale)
                            Text(warning.message)
                                .appScaledFont(.caption, scale: fontScale)
                                .foregroundStyle(.secondary)
                            Text(warning.code.displayGuidance)
                                .appScaledFont(.caption, scale: fontScale)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(4)
        .environment(\.defaultMinListHeaderHeight, 0)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ImportPreviewActionBar(
                primaryTitle: replacements.isEmpty ? "Import" : "Replace Trip",
                primaryRole: replacements.isEmpty ? nil : .destructive,
                isPrimaryDisabled: !pending.canConfirm,
                onPrimary: {
                    if replacements.isEmpty {
                        Task {
                            if await viewModel.confirmPendingImport(expectedReplacementIDs: []) {
                                dismiss()
                            }
                        }
                    } else {
                        replacementConfirmation = ImportReplacementConfirmation(candidates: replacements)
                    }
                },
                onCancel: {
                    Task {
                        await viewModel.discardPendingImport()
                        dismiss()
                    }
                }
            )
        }
    }

    private var fontScale: CGFloat {
        (AppFontSizeOption(rawValue: appFontSizeOptionRawValue) ?? .medium).scaleFactor
    }

    private var summaryBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.14, green: 0.14, blue: 0.16)
            : Color(red: 0.98, green: 0.98, blue: 0.99)
    }

    private static func timeRangeText(for leg: TripLeg) -> String {
        "\(ScheduleDateText.timePart(from: leg.depLocal)) - \(ScheduleDateText.timePart(from: leg.arrLocal))"
    }
}

private struct ImportPreviewTripSummary: View {
    let tripID: String
    let dateRangeText: String
    let legCountText: String
    let fontScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Trip \(tripID)")
                .appScaledFont(.subheadline, weight: .bold, scale: fontScale)

            // ViewThatFits keeps the single line at default type sizes and falls back to a stacked
            // layout when Dynamic Type or a narrow width would otherwise truncate it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(dateRangeText)
                    Spacer(minLength: 8)
                    Text(legCountText)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(dateRangeText)
                    Text(legCountText)
                }
            }
            .appScaledFont(.caption, scale: fontScale)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct ImportPreviewActionBar: View {
    let primaryTitle: String
    let primaryRole: ButtonRole?
    let isPrimaryDisabled: Bool
    let onPrimary: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    actionButtons
                }

                VStack(spacing: 8) {
                    actionButtons
                }
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// `.regular` control size with an explicit 44pt floor: the bar gets shorter without any
    /// button dropping below the Human Interface Guidelines minimum tap target, at any Dynamic
    /// Type size.
    private static let minimumTapTarget: CGFloat = 44

    @ViewBuilder
    private var actionButtons: some View {
        Button("Cancel", action: onCancel)
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: Self.minimumTapTarget)
            .contentShape(Rectangle())

        Button(primaryTitle, role: primaryRole, action: onPrimary)
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .frame(maxWidth: .infinity, minHeight: Self.minimumTapTarget)
            .disabled(isPrimaryDisabled)
    }
}
