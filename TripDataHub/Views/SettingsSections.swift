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

    private var sortedBidproSchedules: [PayPeriodSchedule] {
        viewModel.bidproSchedules.sorted { lhs, rhs in
            let lhsOrder = payPeriodOrder(for: lhs)
            let rhsOrder = payPeriodOrder(for: rhs)
            switch (lhsOrder, rhsOrder) {
            case let (lhsOrder?, rhsOrder?):
                if lhsOrder == rhsOrder {
                    return lhs.label < rhs.label
                }
                return lhsOrder < rhsOrder
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.label < rhs.label
            }
        }
    }

    var body: some View {
        Section {
            if viewModel.bidproSchedules.isEmpty {
                Text("No fetched data yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedBidproSchedules) { schedule in
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

    private func payPeriodOrder(for schedule: PayPeriodSchedule) -> Int? {
        parsePayPeriodOrder(schedule.id) ?? parsePayPeriodOrder(schedule.label)
    }

    private func parsePayPeriodOrder(_ raw: String) -> Int? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let range = cleaned.range(of: #"PP(\d{2})-(\d{2})"#, options: .regularExpression)
        guard let range else { return nil }
        let match = String(cleaned[range])
        let parts = match.replacingOccurrences(of: "PP", with: "").split(separator: "-")
        guard parts.count == 2,
              let yy = Int(parts[0]),
              let pp = Int(parts[1]) else {
            return nil
        }
        return yy * 100 + pp
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
