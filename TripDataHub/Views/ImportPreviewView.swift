import SwiftUI

struct ImportPreviewView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingReplacementConfirm = false
#if DEBUG
    @State private var isShowingDiagnostics = false
#endif

    var body: some View {
        Group {
            if let pending = viewModel.pendingImport {
                List {
                    if viewModel.hasQueuedImport {
                        Section {
                            Label(
                                "Another import is queued. It will open automatically after you confirm or cancel this one.",
                                systemImage: "tray.full"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Section("Import Summary") {
                        Text("Trip Id: \(pending.tripId)")
                        Text("Legs count: \(pending.parsedSchedule?.legs.count ?? 0)")
                    }

                    Section("Legs") {
                        if let schedule = pending.parsedSchedule, !schedule.legs.isEmpty {
                            ForEach(schedule.legs) { leg in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(leg.depAirport) -> \(leg.arrAirport)")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Time: \(leg.depLocal) -> \(leg.arrLocal)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        } else {
                            Text("No parsed legs available.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

#if DEBUG
                    Section {
                        DisclosureGroup("Diagnostics", isExpanded: $isShowingDiagnostics) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("tripId: \(pending.tripId)")
                                Text("tripDate: \(pending.tripDate)")
                                Text("tripDays: \(pending.jsonPayload?.tripDays ?? "N/A")")
                                Text("credit: \(pending.jsonPayload?.creditTime ?? "N/A")")
                                Text("tafb: \(pending.jsonPayload?.tafb ?? "N/A")")
                                Text("characterCount: \(pending.rawExtractStats.characterCount)")
                                Text("lineCount: \(pending.rawExtractStats.lineCount)")
                                Text("pageCount: \(pending.rawExtractStats.pageCount)")
                            }
                            .font(.caption)
                            .padding(.top, 4)

                            if let payload = pending.jsonPayload, !payload.items.isEmpty {
                                ForEach(payload.items, id: \.sequence) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Leg \(item.sequence): \(item.depAirport) -> \(item.arrAirport)")
                                            .font(.caption.weight(.semibold))
                                        Text("depUtc: \(item.startUtc)")
                                            .font(.caption2)
                                        Text("arrUtc: \(item.endUtc)")
                                            .font(.caption2)
                                        Text("originIATA: \(item.depAirport) / destinationIATA: \(item.arrAirport)")
                                            .font(.caption2)
                                        Text("originTz: \(item.originTz ?? "N/A") / destinationTz: \(item.destinationTz ?? "N/A")")
                                            .font(.caption2)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }

                            Button("Export Raw Trip Snapshot (Debug)") {
                                viewModel.debugExportRawTripSnapshot(pending: pending)
                            }
                            .font(.caption)
                        }
                    }
#endif

                    let replacements = viewModel.pendingImportReplacementCandidates
                    if !replacements.isEmpty {
                        Section("Replacements") {
                            ForEach(replacements) { candidate in
                                VStack(alignment: .leading, spacing: 4) {
                                    switch candidate.reason {
                                    case .sameTripID:
                                        Label(
                                            "This import will replace Trip \(candidate.tripId).",
                                            systemImage: "arrow.triangle.2.circlepath"
                                        )
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.orange)
                                    case .timeOverlap:
                                        Label(
                                            "This import overlaps existing Trip \(candidate.tripId). \(candidate.tripId) will be removed from Timeline and synced devices.",
                                            systemImage: "exclamationmark.triangle.fill"
                                        )
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.red)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    if !pending.errors.isEmpty {
                        Section("Errors (Confirm blocked)") {
                            ForEach(pending.errors) { error in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("[\(error.code.rawValue)] \(error.message)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.red)
                                    Text(error.remediation)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    if !pending.warnings.isEmpty {
                        Section("Warnings (\(pending.warnings.count))") {
                            ForEach(pending.warnings) { warning in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(warning.code.displayTitle)
                                        .font(.subheadline.weight(.semibold))
                                    Text(warning.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(warning.code.displayGuidance)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    Section {
                        Button("Confirm Import") {
                            let replacements = viewModel.pendingImportReplacementCandidates
                            if replacements.isEmpty {
                                Task {
                                    await viewModel.confirmPendingImport()
                                    dismiss()
                                }
                            } else {
                                showingReplacementConfirm = true
                            }
                        }
                        .disabled(!pending.canConfirm)

                        Button("Cancel", role: .destructive) {
                            Task {
                                await viewModel.discardPendingImport()
                                dismiss()
                            }
                        }
                    }
                }
                .confirmationDialog(
                    "Replace existing trip(s)?",
                    isPresented: $showingReplacementConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Replace and Import", role: .destructive) {
                        Task {
                            await viewModel.confirmPendingImport()
                            dismiss()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    let replacements = viewModel.pendingImportReplacementCandidates
                    let lines = replacements.map { c -> String in
                        switch c.reason {
                        case .sameTripID:
                            return "Trip \(c.tripId) will be replaced."
                        case .timeOverlap:
                            return "Trip \(c.tripId) overlaps and will be removed from Timeline and synced devices."
                        }
                    }
                    Text(lines.joined(separator: "\n"))
                }
            } else {
                ContentUnavailableView(
                    "No Pending Import",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Start a CrewAccess import from the share sheet.")
                )
            }
        }
        .navigationTitle("Import Preview")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}
