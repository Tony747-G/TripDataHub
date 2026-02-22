import SwiftUI

struct SettingsAccountSection: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var verifyGemsIDInput: String
    @Binding var verifyDOBDate: Date
    let formatDOB: (Date) -> String

    var body: some View {
        Section {
            let gemsID = viewModel.isIdentityVerified ? (viewModel.verifiedIdentity?.gemsID ?? "N/A") : "N/A"
            Text("GEMS ID: \(gemsID)")
                .font(.footnote)
            Text("Verification Status: \(viewModel.isIdentityVerified ? "Verified" : "Not Verified")")
                .font(.footnote)
                .foregroundStyle(viewModel.isIdentityVerified ? .green : .secondary)
            if !viewModel.isIdentityVerified {
                TextField("GEMS ID", text: $verifyGemsIDInput)
                DatePicker("DOB", selection: $verifyDOBDate, displayedComponents: .date)
                Button("Verify Identity") {
                    viewModel.verifyIdentity(
                        gemsID: verifyGemsIDInput,
                        dateOfBirth: formatDOB(verifyDOBDate)
                    )
                }
            }
            if let message = viewModel.friendActionMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Account")
        }
    }
}

struct SettingsTripBoardFetchSection: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var autoFetchOnOpen: Bool

    var body: some View {
        Section {
            Toggle("Auto Fetch on App Open", isOn: $autoFetchOnOpen)

            Button {
                Task { await viewModel.syncTapped() }
            } label: {
                HStack {
                    Text("Fetch Latest")
                    Spacer()
                    if viewModel.isSyncing {
                        ProgressView()
                    }
                }
            }
            .disabled(viewModel.isSyncing)

            if viewModel.isTripBoardServerDown {
                Text("Auth: TripBoard Server is down")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text("Auth: \(viewModel.authStatusText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if viewModel.isTripBoardServerDown, viewModel.didLastFetchFail {
                Text("Last Fetch: Failed")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if let lastSyncAt = viewModel.lastSyncAt {
                Text("Last Fetch: \(lastSyncAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = viewModel.visibleErrorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            sectionHeader("TripBoard Fetch")
        }
    }
}

struct SettingsExperimentalImportSection: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let onTapImportCrewAccessPDF: () -> Void

    var body: some View {
        Section {
            Text("CrewAccess PDF import is experimental and may fail when CrewAccess layout changes.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Import CrewAccess PDF") {
                onTapImportCrewAccessPDF()
            }

            if let pending = viewModel.pendingImport {
                Text("Preview ready: \(pending.tripId) (\(pending.rawExtractStats.characterCount) chars)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let crewAccessImportMessage = viewModel.crewAccessImportMessage {
                Text(crewAccessImportMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("If this fails, re-export from CrewAccess Print as text-selectable PDF.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            sectionHeader("Advanced / Experimental")
        }
    }
}

struct SettingsCrewAccessImportsSection: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var isSelecting = false
    @State private var selectedTripIDs: Set<String> = []
    @State private var showingDeleteConfirm = false
    @State private var deleteTargetIDs: Set<String> = []

    var body: some View {
        Section {
            if viewModel.crewAccessSchedules.isEmpty {
                Text("No imported CrewAccess trips.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button(isSelecting ? "Cancel Selection" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting {
                            selectedTripIDs.removeAll()
                        }
                    }
                    .disabled(viewModel.isDeletingCrewAccessTrips)

                    Spacer()

                    if isSelecting {
                        Button("Delete Selected", role: .destructive) {
                            deleteTargetIDs = selectedTripIDs
                            showingDeleteConfirm = true
                        }
                        .disabled(selectedTripIDs.isEmpty || viewModel.isDeletingCrewAccessTrips)
                    }
                }

                ForEach(viewModel.crewAccessSchedules) { schedule in
                    CrewAccessImportRow(
                        schedule: schedule,
                        isSelecting: isSelecting,
                        isSelected: selectedTripIDs.contains(schedule.id)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard isSelecting else { return }
                        if selectedTripIDs.contains(schedule.id) {
                            selectedTripIDs.remove(schedule.id)
                        } else {
                            selectedTripIDs.insert(schedule.id)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteTargetIDs = [schedule.id]
                            showingDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            if viewModel.isDeletingCrewAccessTrips {
                ProgressView()
            }

            if let message = viewModel.crewAccessDeleteMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("CrewAccess Imports")
        }
        .confirmationDialog(
            "Delete imported trip(s)?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = deleteTargetIDs
                Task {
                    await viewModel.deleteCrewAccessTrips(ids: ids)
                    selectedTripIDs.subtract(ids)
                    deleteTargetIDs.removeAll()
                    if selectedTripIDs.isEmpty {
                        isSelecting = false
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                deleteTargetIDs.removeAll()
            }
        } message: {
            Text("This removes the imported CrewAccess trip from Timeline. This cannot be undone.")
        }
    }
}

private struct CrewAccessImportRow: View {
    let schedule: PayPeriodSchedule
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(schedule.label)
                    .font(.headline)
                Text("Trips: \(schedule.tripCount)  Legs: \(schedule.legCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Updated: \(schedule.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsPayPeriodsSection: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        Section {
            if viewModel.schedules.isEmpty {
                Text("No fetched data yet. Tap Fetch Latest.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.schedules) { schedule in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(schedule.label)
                            .font(.headline)
                        Text("Schedule: \(schedule.tripCount)  Legs: \(schedule.legCount)  Open: \(schedule.openTimeCount)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            sectionHeader("Pay Periods")
        }
    }
}

struct SettingsDisplaySection: View {
    @Binding var appearanceMode: AppearanceMode
    @Binding var fontSizeOption: AppFontSizeOption

    var body: some View {
        Group {
            Section {
                Picker("Appearance", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                sectionHeader("Display Theme")
            }

            Section {
                Picker("Font Size", selection: $fontSizeOption) {
                    ForEach(AppFontSizeOption.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                sectionHeader("Font Size")
            }
        }
    }
}

struct SettingsNotificationSection: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var notify48h: Bool
    @Binding var notify24h: Bool
    @Binding var notify12h: Bool

    var body: some View {
        Section {
            Toggle("48 hours", isOn: $notify48h)
            Toggle("24 hours", isOn: $notify24h)
            Toggle("12 hours", isOn: $notify12h)

            if let message = viewModel.notificationScheduleMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            sectionHeader("Notification Setting")
        }
    }
}

private func sectionHeader(_ title: String) -> some View {
    Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.primary.opacity(0.95))
}
