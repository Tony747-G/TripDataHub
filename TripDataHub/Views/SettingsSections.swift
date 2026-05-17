import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
            if viewModel.isIdentityVerified {
                Label("Identity Verified", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
            }
            if viewModel.isRefreshingCloudKitIdentity {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking iCloud identity...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = viewModel.cloudKitIdentityMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if !viewModel.isIdentityVerified {
                TextField("GEMS ID", text: $verifyGemsIDInput)
                    .keyboardType(.numberPad)
                    .textContentType(.username)
                    .submitLabel(.done)
                    .onSubmit(verifyIdentity)
                DatePicker("DOB", selection: $verifyDOBDate, displayedComponents: .date)
                Button("Verify Identity") {
                    verifyIdentity()
                }
            }
            if let message = viewModel.identityActionMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(message.localizedCaseInsensitiveContains("verified") ? .green : .orange)
            }
        } header: {
            sectionHeader("Account")
        }
    }

    private func verifyIdentity() {
        dismissKeyboard()
        Task {
            await viewModel.verifyIdentity(
                gemsID: verifyGemsIDInput,
                dateOfBirth: formatDOB(verifyDOBDate)
            )
        }
    }

    private func dismissKeyboard() {
#if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
    }
}

struct SettingsTripBoardFetchSection: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var autoFetchOnOpen: Bool

    var body: some View {
        Section {
            Toggle("Auto Fetch on App Open", isOn: $autoFetchOnOpen)

            Button(viewModel.authStatus == .loggedOut ? "TripBoard Log-in" : "Fetch TripBoard Data") {
                Task {
                    await viewModel.syncTapped()
                }
            }
            .disabled(viewModel.isSyncing)
            .accessibilityIdentifier("settings.tripboardAction")

            if viewModel.isSyncing {
                ProgressView()
            }

            if viewModel.isTripBoardServerDown {
                Text("Auth: TripBoard Server is down")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text("Auth: \(viewModel.authStatusText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("TripBoard Fetch")
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
                    .contextMenu {
                        Button(role: .destructive) {
                            deleteTargetIDs = [schedule.id]
                            showingDeleteConfirm = true
                        } label: {
                            Label("Delete Trip", systemImage: "trash")
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

struct SettingsSupportSection: View {
    @Environment(\.openURL) private var openURL

    private let supportURL = URL(string: "https://buymeacoffee.com/tripdatahub")

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("TripDataHub is independently developed and maintained.")

                Text("If you find the app useful and would like to support ongoing development, testing, and infrastructure costs, you can support the project here.")

                Text("This is optional and does not unlock any additional features.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button("Support on Buy Me a Coffee") {
                guard let supportURL else { return }
                openURL(supportURL)
            }
            .accessibilityIdentifier("settings.supportTripDataHub.buyMeACoffee")
        } header: {
            sectionHeader("Support TripDataHub")
        }
    }
}

private func sectionHeader(_ title: String) -> some View {
    Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.primary.opacity(0.95))
}
