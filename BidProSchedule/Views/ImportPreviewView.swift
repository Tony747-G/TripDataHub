import SwiftUI

struct ImportPreviewView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
#if DEBUG
    @State private var isShowingDiagnostics = false
#endif

    var body: some View {
        Group {
            if let pending = viewModel.pendingImport {
                List {
                    Section("Import Summary") {
                        Text("Source: \(pending.source.rawValue)")
                        Text("File: \(pending.sourceFileName ?? "N/A")")
                        Text("Trip Id: \(pending.tripId)")
                        Text("Trip Date: \(pending.tripDate)")
                        Text("Legs count: \(pending.parsedSchedule?.legs.count ?? 0)")
                        Text("Extract: \(pending.rawExtractStats.characterCount) chars, \(pending.rawExtractStats.lineCount) lines, \(pending.rawExtractStats.pageCount) pages")
                        Text("Created: \(pending.createdAt.formatted(date: .abbreviated, time: .shortened))")
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
                        }
                    }
#endif

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
                        Section("Warnings") {
                            ForEach(pending.warnings) { warning in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("[\(warning.code.rawValue)] \(warning.message)")
                                        .font(.subheadline)
                                    Text("Review this item before confirm.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    Section {
                        Button("Confirm Import") {
                            Task {
                                await viewModel.confirmPendingImport()
                                dismiss()
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
            } else {
                ContentUnavailableView(
                    "No Pending Import",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Start import from Settings -> Advanced / Experimental.")
                )
            }
        }
        .navigationTitle("Import Preview")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}
