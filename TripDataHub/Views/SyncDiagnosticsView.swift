import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Temporary support screen for diagnosing the Personal Event sync asymmetry on managed iPads,
/// which cannot be attached to `log stream`.
///
/// Shows the on-device ring buffer newest-first and offers Copy / Clear. Contains no Personal Event
/// content — identifiers are short SHA256 tags only.
struct SyncDiagnosticsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var showCopyConfirmation = false
    @State private var showClearConfirmation = false

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Entries")
                    Spacer()
                    Text("\(viewModel.diagnostics.entries.count)")
                        .foregroundStyle(.secondary)
                }
                Button {
                    copyDiagnostics()
                } label: {
                    Label("Copy Diagnostics", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label("Clear Diagnostics", systemImage: "trash")
                }
            } footer: {
                Text("Records sync activity only. No event titles, dates or notes are stored, and identifiers are shortened one-way hashes.")
            }

            Section("Recent activity") {
                if viewModel.diagnostics.entries.isEmpty {
                    Text("No diagnostics recorded yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.diagnostics.entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.code)
                                    .font(.system(.footnote, design: .monospaced))
                                Spacer()
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !entry.fields.isEmpty {
                                Text(
                                    entry.fields
                                        .sorted { $0.key < $1.key }
                                        .map { "\($0.key)=\($0.value)" }
                                        .joined(separator: "  ")
                                )
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .navigationTitle("Sync Diagnostics")
        .alert("Copied", isPresented: $showCopyConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Diagnostics copied to the clipboard.")
        }
        .confirmationDialog(
            "Clear all recorded diagnostics?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                viewModel.diagnostics.clear()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func copyDiagnostics() {
#if canImport(UIKit)
        UIPasteboard.general.string = viewModel.diagnostics.exportText()
#endif
        showCopyConfirmation = true
    }
}
