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
            if AppEnvironment.isAppStoreReviewMode {
                Label("Demo Mode", systemImage: "checkmark.shield.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
                Text(AppEnvironment.reviewModeMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            let gemsID = AppEnvironment.isAppStoreReviewMode ? "Demo" : (viewModel.isIdentityVerified ? (viewModel.verifiedIdentity?.gemsID ?? "N/A") : "N/A")
            Text("GEMS ID: \(gemsID)")
                .font(.footnote)
            Text("Verification Status: \(viewModel.isIdentityVerified ? "Verified" : "Not Verified")")
                .font(.footnote)
                .foregroundStyle(viewModel.isIdentityVerified ? .green : .secondary)
            if viewModel.isIdentityVerified && !AppEnvironment.isAppStoreReviewMode {
                Label("Identity Verified", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
            }
            if viewModel.isRefreshingCloudKitIdentity && !AppEnvironment.isAppStoreReviewMode {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking iCloud identity...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = viewModel.cloudKitIdentityMessage, !AppEnvironment.isAppStoreReviewMode {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if !viewModel.isIdentityVerified && !AppEnvironment.isAppStoreReviewMode {
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
            if AppEnvironment.isAppStoreReviewMode {
                Label(AppEnvironment.tripBoardUnavailableMessage, systemImage: "lock.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
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

enum PilotQualification: String, CaseIterable, Identifiable {
    case captain
    case firstOfficer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .captain:
            return "Captain"
        case .firstOfficer:
            return "First Officer"
        }
    }
}

struct SettingsQualificationSection: View {
    @Binding var qualificationRawValue: String
    @Binding var bidTransitionTimelineEnabled: Bool

    private var qualificationBinding: Binding<PilotQualification> {
        Binding(
            get: { PilotQualification(rawValue: qualificationRawValue) ?? .captain },
            set: { qualificationRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Section {
            Picker("Qualification", selection: qualificationBinding) {
                ForEach(PilotQualification.allCases) { qualification in
                    Text(qualification.label).tag(qualification)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Bid Transition Timeline", isOn: $bidTransitionTimelineEnabled)
        } header: {
            sectionHeader("Qualification")
        }
    }
}

struct SettingsCrewBaseSection: View {
    @Binding var crewBaseRawValue: String

    private var crewBaseBinding: Binding<CrewBase> {
        Binding(
            get: { CrewBase(rawValue: crewBaseRawValue) ?? OperationalSettings.defaultCrewBase },
            set: { crewBaseRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Section {
            Picker("Crew Domicile", selection: crewBaseBinding) {
                ForEach(CrewBase.allCases) { base in
                    Text(base.displayName).tag(base)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            sectionHeader("Crew Domicile")
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

private enum ManualEventDraftLayer: String, CaseIterable, Identifiable {
    case operational = "Operational"
    case personal = "Personal"

    var id: String { rawValue }
}

private enum ManualEventClockDisplay: String, CaseIterable, Identifiable {
    case ldt = "LDT"
    case utc = "UTC"

    var id: String { rawValue }
}

struct ManualEventAddSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(OperationalSettings.crewBaseKey) private var crewBaseRawValue = OperationalSettings.defaultCrewBase.rawValue
    @AppStorage("manual_event_clock_display") private var manualEventClockDisplayRawValue = ManualEventClockDisplay.ldt.rawValue

    private let editingOperationalEvent: ManualOperationalEvent?
    private let editingPersonalEvent: ManualPersonalEvent?
    private let onSaved: (() -> Void)?

    @State private var draftLayer: ManualEventDraftLayer = .operational
    @State private var operationalCode: ManualOperationalCode = .reserveA
    @State private var personalCode: ManualPersonalCode = .commute
    @State private var startDate = Date()
    @State private var endDate = Date().addingTimeInterval(60 * 60)
    @State private var notes = ""
    @State private var saveError: String?
    @State private var hasSyncedInitialAutoEndDate = false

    init(
        editingOperationalEvent: ManualOperationalEvent? = nil,
        editingPersonalEvent: ManualPersonalEvent? = nil,
        onSaved: (() -> Void)? = nil
    ) {
        self.editingOperationalEvent = editingOperationalEvent
        self.editingPersonalEvent = editingPersonalEvent
        self.onSaved = onSaved

        let initialLayer: ManualEventDraftLayer = editingPersonalEvent == nil ? .operational : .personal
        _draftLayer = State(initialValue: initialLayer)
        _operationalCode = State(initialValue: editingOperationalEvent?.code ?? .reserveA)
        _personalCode = State(initialValue: editingPersonalEvent?.code ?? .commute)
        _startDate = State(initialValue: editingOperationalEvent?.startUTC ?? editingPersonalEvent?.startUTC ?? Date())
        _endDate = State(initialValue: editingOperationalEvent?.endUTC ?? editingPersonalEvent?.endUTC ?? Date().addingTimeInterval(60 * 60))
        _notes = State(initialValue: editingOperationalEvent?.notes ?? editingPersonalEvent?.notes ?? "")
    }

    private var isEditing: Bool {
        editingOperationalEvent != nil || editingPersonalEvent != nil
    }

    private var selectedCrewBase: CrewBase {
        if let editingOperationalEvent {
            return editingOperationalEvent.crewBase
        }
        return CrewBase(rawValue: crewBaseRawValue) ?? OperationalSettings.defaultCrewBase
    }

    private var selectedBaseTimeZone: TimeZone {
        selectedCrewBase.timeZone
    }

    private var selectedManualEventClockDisplay: ManualEventClockDisplay {
        ManualEventClockDisplay(rawValue: manualEventClockDisplayRawValue) ?? .ldt
    }

    private var selectedInputTimeZone: TimeZone {
        selectedManualEventClockDisplay == .utc ? (TimeZone(secondsFromGMT: 0) ?? .gmt) : selectedBaseTimeZone
    }

    private var selectedBaseCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = selectedBaseTimeZone
        return calendar
    }

    private var defaultOperationalRange: TimeRangeRule? {
        CrewBaseRule.rule(for: selectedCrewBase).defaultTimeRange(for: operationalCode)
    }

    private var localStartDateComponents: DateComponents {
        selectedBaseCalendar.dateComponents([.year, .month, .day], from: startDate)
    }

    private var localEndDateComponents: DateComponents {
        selectedBaseCalendar.dateComponents([.year, .month, .day], from: endDate)
    }

    private var autoFilledOperationalEvent: ManualOperationalEvent? {
        guard defaultOperationalRange != nil else { return nil }
        return try? ManualOperationalEvent(
            id: editingOperationalEvent?.id ?? UUID(),
            code: operationalCode,
            crewBase: selectedCrewBase,
            localStartDate: localStartDateComponents,
            notes: normalizedNotes,
            createdAt: editingOperationalEvent?.createdAt ?? Date(),
            updatedAt: isEditing ? Date() : nil
        )
    }

    private var autoFilledOperationalEvents: [ManualOperationalEvent]? {
        guard defaultOperationalRange != nil else { return nil }
        return try? ManualOperationalEvent.dailyAutoFilledEvents(
            code: operationalCode,
            crewBase: selectedCrewBase,
            localStartDate: localStartDateComponents,
            localEndDate: localEndDateComponents,
            notes: normalizedNotes,
            createdAt: Date()
        )
    }

    private var normalizedNotes: String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let baseDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm'Z'"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Event Type", selection: $draftLayer) {
                        ForEach(ManualEventDraftLayer.allCases) { layer in
                            Text(layer.rawValue).tag(layer)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isEditing)
                }

                switch draftLayer {
                case .operational:
                    operationalSection
                case .personal:
                    personalSection
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(1...3)
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Event" : "Add Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .environment(\.timeZone, selectedBaseTimeZone)
        .onAppear {
            syncAutoEndDateIfNeeded(force: !isEditing)
        }
        .onChange(of: startDate) { _, newValue in
            if defaultOperationalRange != nil {
                syncAutoEndDateIfNeeded(force: true)
            } else if endDate <= newValue {
                endDate = newValue.addingTimeInterval(60 * 60)
            }
        }
        .onChange(of: operationalCode) { _, _ in
            syncAutoEndDateIfNeeded(force: true)
        }
    }

    private var operationalSection: some View {
        Section {
            Picker("Operational Code", selection: $operationalCode) {
                ForEach(ManualOperationalCode.allCases) { code in
                    Text(code.rawValue).tag(code)
                }
            }

            LabeledContent("Crew Domicile", value: selectedCrewBase.displayName)

            if let range = defaultOperationalRange, let autoEvent = autoFilledOperationalEvent {
                DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                LabeledContent("Auto Fill") {
                    Text("\(range.start.displayHHMM) - \(range.end.displayHHMM) LDT")
                }
                DatePicker(
                    "End Date",
                    selection: $endDate,
                    displayedComponents: .date
                )
                LabeledContent("UTC") {
                    Text("\(Self.utcText(autoEvent.startUTC)) - \(Self.utcText(autoEvent.endUTC))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let autoEvents = autoFilledOperationalEvents, autoEvents.count > 1, !isEditing {
                    LabeledContent("Events", value: "\(autoEvents.count)")
                }
            } else {
                DatePicker("Start", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                DatePicker("End", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                Text("No default time range is defined for \(selectedCrewBase.rawValue) + \(operationalCode.rawValue). Enter start and end time in LDT.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Operational")
        }
    }

    private var personalSection: some View {
        Section {
            Picker("Personal Event", selection: $personalCode) {
                ForEach(ManualPersonalCode.allCases) { code in
                    Text(code.rawValue).tag(code)
                }
            }
            Picker("Time Display", selection: Binding(
                get: { selectedManualEventClockDisplay },
                set: { manualEventClockDisplayRawValue = $0.rawValue }
            )) {
                ForEach(ManualEventClockDisplay.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            DatePicker("Start", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, selectedInputTimeZone)
            DatePicker("End", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, selectedInputTimeZone)
            Text(selectedManualEventClockDisplay == .utc ? "Times are entered in UTC." : "Times are entered in Crew Domicile LDT.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            sectionHeader("Personal")
        }
    }

    private func save() {
        do {
            switch draftLayer {
            case .operational:
                if isEditing, let autoEvent = autoFilledOperationalEvent {
                    try viewModel.updateManualOperationalEvent(autoEvent)
                } else if let autoEvents = autoFilledOperationalEvents {
                    try viewModel.saveManualOperationalEventsReplacingOverlaps(autoEvents)
                } else {
                    let event = try ManualOperationalEvent(
                        id: editingOperationalEvent?.id ?? UUID(),
                        code: operationalCode,
                        crewBase: selectedCrewBase,
                        startUTC: startDate,
                        endUTC: endDate,
                        notes: normalizedNotes,
                        createdAt: editingOperationalEvent?.createdAt ?? Date(),
                        updatedAt: isEditing ? Date() : nil
                    )
                    if isEditing {
                        try viewModel.updateManualOperationalEvent(event)
                    } else {
                        try viewModel.saveManualOperationalEvent(event)
                    }
                }
            case .personal:
                let event = try ManualPersonalEvent(
                    id: editingPersonalEvent?.id ?? UUID(),
                    code: personalCode,
                    startUTC: startDate,
                    endUTC: endDate,
                    notes: normalizedNotes,
                    createdAt: editingPersonalEvent?.createdAt ?? Date(),
                    updatedAt: isEditing ? Date() : nil
                )
                if isEditing {
                    try viewModel.updateManualPersonalEvent(event)
                } else {
                    try viewModel.saveManualPersonalEvent(event)
                }
            }
            onSaved?()
            dismiss()
        } catch {
            saveError = "Unable to save event: \(error.localizedDescription)"
        }
    }

    private static func utcText(_ date: Date) -> String {
        baseDateTimeFormatter.string(from: date)
    }

    private func syncAutoEndDateIfNeeded(force: Bool = false) {
        guard let range = defaultOperationalRange else { return }
        guard force || !hasSyncedInitialAutoEndDate else { return }
        endDate = defaultEndDate(for: startDate, range: range)
        hasSyncedInitialAutoEndDate = true
    }

    private func defaultEndDate(for start: Date, range: TimeRangeRule) -> Date {
        selectedBaseCalendar.startOfDay(for: start)
    }
}

struct ManualEventDetailSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(OperationalSettings.crewBaseKey) private var crewBaseRawValue = OperationalSettings.defaultCrewBase.rawValue
    @AppStorage("manual_event_clock_display") private var manualEventClockDisplayRawValue = ManualEventClockDisplay.ldt.rawValue

    let operationalEvent: ManualOperationalEvent?
    let personalEvent: ManualPersonalEvent?

    @State private var showingEdit = false
    @State private var showingDeleteConfirm = false
    @State private var actionError: String?

    init(operationalEvent: ManualOperationalEvent) {
        self.operationalEvent = operationalEvent
        self.personalEvent = nil
    }

    init(personalEvent: ManualPersonalEvent) {
        self.operationalEvent = nil
        self.personalEvent = personalEvent
    }

    private var title: String {
        operationalEvent?.code.rawValue ?? personalEvent?.code.rawValue ?? "Event"
    }

    private var selectedManualEventClockDisplay: ManualEventClockDisplay {
        ManualEventClockDisplay(rawValue: manualEventClockDisplayRawValue) ?? .ldt
    }

    private var selectedCrewBase: CrewBase {
        CrewBase(rawValue: crewBaseRawValue) ?? OperationalSettings.defaultCrewBase
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    detailRow("Type", operationalEvent == nil ? "Personal" : "Operational")
                    detailRow("Code", title)
                    if let operationalEvent {
                        detailRow("Crew Domicile", operationalEvent.crewBase.displayName)
                        detailRow("Time", timeRangeText(start: operationalEvent.startUTC, end: operationalEvent.endUTC, timeZone: operationalEvent.crewBase.timeZone))
                    } else if let personalEvent {
                        detailRow("Time", timeRangeText(start: personalEvent.startUTC, end: personalEvent.endUTC, timeZone: selectedCrewBase.timeZone))
                    }
                    if let notes = operationalEvent?.notes ?? personalEvent?.notes, !notes.isEmpty {
                        detailRow("Notes", notes)
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                HStack(spacing: 10) {
                    Button("Edit") { showingEdit = true }
                        .buttonStyle(.bordered)
                    Button("Delete", role: .destructive) { showingDeleteConfirm = true }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                if let actionError {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            if let operationalEvent {
                ManualEventAddSheet(editingOperationalEvent: operationalEvent) {
                    dismiss()
                }
                .environmentObject(viewModel)
            } else if let personalEvent {
                ManualEventAddSheet(editingPersonalEvent: personalEvent) {
                    dismiss()
                }
                .environmentObject(viewModel)
            }
        }
        .confirmationDialog(
            "Delete \(title)?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteEvent()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the manual event from Calendar and Timeline. This cannot be undone.")
        }
    }

    private func deleteEvent() {
        do {
            if let operationalEvent {
                try viewModel.deleteManualOperationalEvent(id: operationalEvent.id)
            } else if let personalEvent {
                try viewModel.deleteManualPersonalEvent(id: personalEvent.id)
            }
            dismiss()
        } catch {
            actionError = "Unable to delete event: \(error.localizedDescription)"
        }
    }

    private func timeRangeText(start: Date, end: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = selectedManualEventClockDisplay == .utc ? (TimeZone(secondsFromGMT: 0) ?? .gmt) : timeZone
        formatter.dateFormat = "MMM d HH:mm"
        return "\(formatter.string(from: start)) - \(formatter.string(from: end)) \(selectedManualEventClockDisplay.rawValue)"
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsReadinessExpirySection: View {
    @Binding var faaMedicalExpiryDate: String
    @Binding var passportExpiryDate: String
    @Binding var chinaVisaExpiryDate: String
    let domicileTimeZone: TimeZone
    @State private var expandedField: ExpiryField?

    private enum ExpiryField {
        case faaMedical
        case passport
        case chinaVisa
    }

    var body: some View {
        Section {
            expiryDatePicker("FAA Medical Expiry Date", field: .faaMedical, value: $faaMedicalExpiryDate)
            expiryDatePicker("Passport Expiry Date", field: .passport, value: $passportExpiryDate)
            expiryDatePicker("China Visa Expiry Date", field: .chinaVisa, value: $chinaVisaExpiryDate)
        } header: {
            sectionHeader("Readiness Expiry Dates")
        } footer: {
            Text("These dates appear on the iPad calendar as personal readiness indicators.")
                .font(.footnote)
        }
    }

    private func expiryDatePicker(_ title: String, field: ExpiryField, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedField = expandedField == field ? nil : field
                }
            } label: {
                HStack {
                    Text(title)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(displayText(for: field, value: value.wrappedValue))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 86, alignment: .trailing)
                    Image(systemName: expandedField == field ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expandedField == field {
                if field == .faaMedical {
                    faaMedicalMonthYearPicker(value: value)
                } else {
                    DatePicker(
                        title,
                        selection: dateBinding(for: value),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.calendar, domicileCalendar)
                    .environment(\.timeZone, domicileTimeZone)
                }

                if !value.wrappedValue.isEmpty {
                    Button("Clear") {
                        value.wrappedValue = ""
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedField = nil
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func faaMedicalMonthYearPicker(value: Binding<String>) -> some View {
        HStack(spacing: 0) {
            Picker("Month", selection: faaMedicalMonthBinding(for: value)) {
                ForEach(1...12, id: \.self) { month in
                    Text(Self.monthSymbols[month - 1]).tag(month)
                }
            }
            .pickerStyle(.wheel)

            Picker("Year", selection: faaMedicalYearBinding(for: value)) {
                ForEach(Self.yearRange, id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
            .pickerStyle(.wheel)
        }
        .frame(height: 170)
    }

    private func faaMedicalMonthBinding(for value: Binding<String>) -> Binding<Int> {
        Binding(
            get: { components(from: value.wrappedValue).month },
            set: { month in
                let current = components(from: value.wrappedValue)
                value.wrappedValue = lastDayString(year: current.year, month: month)
            }
        )
    }

    private func faaMedicalYearBinding(for value: Binding<String>) -> Binding<Int> {
        Binding(
            get: { components(from: value.wrappedValue).year },
            set: { year in
                let current = components(from: value.wrappedValue)
                value.wrappedValue = lastDayString(year: year, month: current.month)
            }
        )
    }

    private func dateBinding(for value: Binding<String>) -> Binding<Date> {
        Binding(
            get: {
                domicileNoonDate(from: value.wrappedValue) ?? Date()
            },
            set: { newValue in
                value.wrappedValue = domicileDateString(from: newValue)
            }
        )
    }

    private var domicileCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = domicileTimeZone
        return calendar
    }

    private func domicileNoonDate(from value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = domicileCalendar
        components.timeZone = domicileTimeZone
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        return domicileCalendar.date(from: components)
    }

    private func domicileDateString(from date: Date) -> String {
        let components = domicileCalendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? Self.currentYear
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func displayText(for field: ExpiryField, value: String) -> String {
        guard !value.isEmpty else { return "" }
        if field == .faaMedical, let date = Self.dateFormatter.date(from: value) {
            return Self.monthYearFormatter.string(from: date)
        }
        return value
    }

    private func components(from value: String) -> (year: Int, month: Int) {
        let date = Self.dateFormatter.date(from: value) ?? Date()
        let components = Self.calendar.dateComponents([.year, .month], from: date)
        return (components.year ?? Self.currentYear, components.month ?? 1)
    }

    private func lastDayString(year: Int, month: Int) -> String {
        let nextMonth = month == 12 ? 1 : month + 1
        let nextYear = month == 12 ? year + 1 : year
        var components = DateComponents()
        components.calendar = Self.calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = nextYear
        components.month = nextMonth
        components.day = 0
        let date = Self.calendar.date(from: components) ?? Date()
        return Self.dateFormatter.string(from: date)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private static var currentYear: Int {
        calendar.component(.year, from: Date())
    }

    private static var yearRange: [Int] {
        Array((currentYear - 1)...(currentYear + 15))
    }

    private static let monthSymbols: [String] = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.monthSymbols
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()
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
