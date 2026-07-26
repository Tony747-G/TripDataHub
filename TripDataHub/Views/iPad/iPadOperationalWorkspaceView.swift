import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Sidebar content type

private enum IPadSidebarContent {
    case ownTimeline
}

// MARK: - Main workspace

struct IPadOperationalWorkspaceView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @AppStorage("appearance_mode") private var appearanceModeRawValue = AppearanceMode.system.rawValue
    @AppStorage("pilot_qualification") private var pilotQualificationRawValue = PilotQualification.captain.rawValue
    @AppStorage("bid_transition_timeline_enabled") private var bidTransitionTimelineEnabled = true
    @AppStorage(ProfileStorageKeys.faaMedicalExpiryDate) private var faaMedicalExpiryDate = ""
    @AppStorage(ProfileStorageKeys.passportExpiryDate) private var passportExpiryDate = ""
    @AppStorage(ProfileStorageKeys.chinaVisaExpiryDate) private var chinaVisaExpiryDate = ""
    @AppStorage(OperationalSettings.crewBaseKey) private var crewDomicileRawValue = OperationalSettings.defaultCrewBase.rawValue
    @Environment(\.scenePhase) private var scenePhase

    private var selectedAppearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    private var selectedCrewDomicile: CrewBase {
        CrewBase(rawValue: crewDomicileRawValue) ?? OperationalSettings.defaultCrewBase
    }

    private var selectedPilotQualification: PilotQualification {
        PilotQualification(rawValue: pilotQualificationRawValue) ?? .captain
    }

    @State private var selectedTripID: String?
    @State private var selectedBidPeriodID: String?
    @State private var sidebarContent: IPadSidebarContent = .ownTimeline
    @State private var timelineScrollTrigger = UUID()
    @State private var menuExpanded = false
    @State private var showingFriends = false
    @State private var showingOpenTime = false
    @State private var showingBrowser = false
    @State private var showingSettings = false
    @State private var showingAddEvent = false
    @State private var showingBidPeriodExportOptions = false
    @State private var bidPeriodPDFExportURL: URL?
    @State private var isExportingBidPeriodPDF = false
    @State private var bidPeriodExportErrorMessage: String?
    @State private var exportIncludesBidLayer = true
    @State private var exportIncludesPersonalLayer = true
    @State private var isShowingImportPreviewFromExternalOpen = false
    /// Calendar trip bars open a focused popup in both orientations. Keep this
    /// separate from the landscape sidebar's own row-selection state.
    @State private var calendarPopupTripID: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Main split layout
            GeometryReader { geo in
                let isPortrait = geo.size.height > geo.size.width
                let sidebarWidth = geo.size.width * 0.30
                if isPortrait {
                    // Portrait: full-width calendar with a focused trip popup.
                    IPadBidPeriodCalendarView(
                        selectedTripID: $calendarPopupTripID,
                        selectedBidPeriodID: $selectedBidPeriodID
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        sidebarView
                            .frame(width: sidebarWidth)
                            .clipped()
                        Divider()
                        IPadBidPeriodCalendarView(
                            selectedTripID: $calendarPopupTripID,
                            selectedBidPeriodID: $selectedBidPeriodID
                        )
                        .frame(width: geo.size.width - sidebarWidth - 1)
                    }
                }
            }

            // Tap-outside-to-dismiss overlay when menu is open
            if menuExpanded {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
                    }
            }

            // Floating expandable menu
            floatingMenu
                .padding(.trailing, 14)
                .padding(.bottom, 24)
        }
        .background(Color(.secondarySystemBackground).ignoresSafeArea(edges: .top))
        .preferredColorScheme(selectedAppearanceMode.colorScheme)
        .task {
            viewModel.consumePendingAppGroupImportIfAvailable()
            await viewModel.syncCrewAccessDeviceData(reason: "ipad workspace")
            if AppEnvironment.isFriendSharingVisible {
                await viewModel.syncFriendCloudKit(reason: "ipad workspace opened")
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.consumePendingAppGroupImportIfAvailable()
                Task {
                    await viewModel.syncCrewAccessDeviceData(reason: "ipad workspace active")
                    if AppEnvironment.isFriendSharingVisible {
                        await viewModel.syncFriendCloudKit(reason: "ipad workspace active")
                    }
                }
            }
        }
        // Calendar trip bars use the same focused popup in portrait and landscape.
        .overlay {
            if let tripID = calendarPopupTripID {
                CalendarTripTimelinePopup(tripID: tripID) {
                    calendarPopupTripID = nil
                }
                .environmentObject(viewModel)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: calendarPopupTripID)
        .sheet(isPresented: $showingBrowser) {
            NavigationStack { BrowserTabView(presentsImportPreview: true) }
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingFriends) {
            IPadFriendsSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingOpenTime) {
            OpenTimeTabView()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $isShowingImportPreviewFromExternalOpen) {
            NavigationStack {
                ImportPreviewView()
            }
            .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsTabView() }
                .environmentObject(viewModel)
                // Login sheet must be attached to the Settings sheet itself —
                // SwiftUI only allows one sheet per view at a time, so attaching
                // it to the workspace (parent) while Settings is already open
                // produces "only presenting a single sheet is supported".
                .sheet(isPresented: Binding(
                    get: { viewModel.isShowingLoginSheet && AppEnvironment.isTripBoardFetchVisible },
                    set: { viewModel.isShowingLoginSheet = $0 }
                )) {
                    TripBoardLoginView(
                        onAuthenticated: { cookies, url in
                            viewModel.handleLoginSucceeded(cookies: cookies, url: url)
                        },
                        onCancel: {
                            viewModel.handleLoginCanceled()
                        }
                    )
                }
        }
        .sheet(isPresented: $showingAddEvent) {
            ManualEventAddSheet()
                .environmentObject(viewModel)
        }
#if canImport(UIKit)
        .sheet(isPresented: Binding(
            get: { bidPeriodPDFExportURL != nil },
            set: { isPresented in
                if !isPresented {
                    removeBidPeriodPDFExportFile()
                }
            }
        )) {
            if let bidPeriodPDFExportURL {
                IPadActivityView(activityItems: [bidPeriodPDFExportURL]) { _ in
                    removeBidPeriodPDFExportFile()
                }
            }
        }
#endif
        .sheet(isPresented: $showingBidPeriodExportOptions) {
            NavigationStack {
                Form {
                    Section {
                        Toggle("Bid Layer", isOn: $exportIncludesBidLayer)
                        Toggle("Personal Layer", isOn: $exportIncludesPersonalLayer)
                    } footer: {
                        Text("Generating a print-ready PDF for \(exportBidPeriodLabel).")
                    }
                }
                .navigationTitle("Export Bid Period")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingBidPeriodExportOptions = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isExportingBidPeriodPDF ? "Generating..." : "Export") {
                            let includeBidLayer = exportIncludesBidLayer
                            let includePersonalLayer = exportIncludesPersonalLayer
                            showingBidPeriodExportOptions = false
                            Task {
                                try? await Task.sleep(nanoseconds: 180_000_000)
                                await exportCurrentBidPeriodPDF(
                                    includeBidLayer: includeBidLayer,
                                    includePersonalLayer: includePersonalLayer
                                )
                            }
                        }
                        .disabled(isExportingBidPeriodPDF)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("PDF Export Failed", isPresented: Binding(
            get: { bidPeriodExportErrorMessage != nil },
            set: { if !$0 { bidPeriodExportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { bidPeriodExportErrorMessage = nil }
        } message: {
            Text(bidPeriodExportErrorMessage ?? "Unable to generate the PDF.")
        }
        .onChange(of: viewModel.pendingImport?.id) { _, newValue in
            isShowingImportPreviewFromExternalOpen = newValue != nil
        }
    }

    // MARK: Sidebar switcher

    @ViewBuilder
    private var sidebarView: some View {
        switch sidebarContent {
        case .ownTimeline:
            IPadTimelineSidebarView(selectedTripID: $selectedTripID, scrollToDefaultTrigger: $timelineScrollTrigger)
        }
    }

    // MARK: Floating menu

    private var floatingMenu: some View {
        var items: [ExpandableFloatingMenuItem] = [
            ExpandableFloatingMenuItem(id: "timeline", icon: "calendar", label: "Timeline", isActive: isOwnTimeline) {
                sidebarContent = .ownTimeline
                timelineScrollTrigger = UUID()
            }
        ]
        if AppEnvironment.isFriendSharingVisible {
            items.append(ExpandableFloatingMenuItem(id: "friends", icon: "person.2", label: "Friends") {
                showingFriends = true
            })
        }
        if AppEnvironment.isOpenTimeVisible {
            items.append(ExpandableFloatingMenuItem(id: "open-time", icon: "clock", label: "OpenTime") {
                showingOpenTime = true
            })
        }
        items.append(ExpandableFloatingMenuItem(id: "browser", icon: "globe", label: "Browser") {
            showingBrowser = true
        })
        items.append(ExpandableFloatingMenuItem(id: "add-event", icon: "plus", label: "Add Event") {
            showingAddEvent = true
        })
        items.append(ExpandableFloatingMenuItem(id: "print", icon: "square.and.arrow.up", label: "Print") {
            exportIncludesBidLayer = bidTransitionTimelineEnabled
            exportIncludesPersonalLayer = true
            showingBidPeriodExportOptions = true
        })
        items.append(ExpandableFloatingMenuItem(id: "settings", icon: "gearshape", label: "Settings") {
            showingSettings = true
        })
        return ExpandableFloatingMenu(isExpanded: $menuExpanded, items: items, itemSpacing: 58)
    }

    private var isOwnTimeline: Bool {
        if case .ownTimeline = sidebarContent { return true }
        return false
    }

    private var exportBidPeriodLabel: String {
        selectedBidPeriodID ?? "the current bid period"
    }

    @MainActor
    private func exportCurrentBidPeriodPDF(includeBidLayer: Bool, includePersonalLayer: Bool) async {
        guard !isExportingBidPeriodPDF else { return }
        isExportingBidPeriodPDF = true
        defer { isExportingBidPeriodPDF = false }

        do {
            removeBidPeriodPDFExportFile()
            bidPeriodPDFExportURL = try BidPeriodPDFExportRenderer.renderPDF(
                selectedBidPeriodID: selectedBidPeriodID,
                crewAccessSchedules: viewModel.crewAccessSchedules,
                manualOperationalEvents: viewModel.manualOperationalEvents,
                manualPersonalEvents: viewModel.manualPersonalEvents,
                crewDomicile: selectedCrewDomicile,
                pilotQualification: selectedPilotQualification,
                includeBidLayer: includeBidLayer,
                includePersonalLayer: includePersonalLayer,
                faaMedicalExpiryDate: faaMedicalExpiryDate,
                passportExpiryDate: passportExpiryDate,
                chinaVisaExpiryDate: chinaVisaExpiryDate
            )
        } catch {
            bidPeriodExportErrorMessage = error.localizedDescription
        }
    }

    private func removeBidPeriodPDFExportFile() {
        guard let url = bidPeriodPDFExportURL else { return }
        try? FileManager.default.removeItem(at: url)
        bidPeriodPDFExportURL = nil
    }
}

#if canImport(UIKit)
private struct IPadActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var completion: ((Bool) -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            completion?(completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - Friends sheet

private struct IPadFriendsSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingFriend: FriendConnection?
    @State private var nicknameInput = ""

    var body: some View {
        NavigationStack {
            List {
                FriendsManagementSection { friend in
                    editingFriend = friend
                    nicknameInput = friend.nickname ?? ""
                }
            }
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename Friend", isPresented: Binding(
                get: { editingFriend != nil },
                set: { if !$0 { editingFriend = nil } }
            )) {
                TextField("Nickname (leave blank to reset)", text: $nicknameInput)
                Button("Save") {
                    if let friend = editingFriend {
                        viewModel.setFriendNickname(id: friend.id, nickname: nicknameInput)
                    }
                    editingFriend = nil
                }
                Button("Cancel", role: .cancel) { editingFriend = nil }
            } message: {
                if let friend = editingFriend {
                    Text("GEMS: \(friend.employeeID)")
                }
            }
        }
    }
}

// MARK: - Friends management (extracted from FriendsTabView for reuse)

private struct FriendsManagementSection: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var employeeIDInput = ""
    @State private var friendPendingRemoval: FriendConnection?
    let onRenameFriend: (FriendConnection) -> Void

    var body: some View {
        Group {
        Section {
            if viewModel.acceptedFriendConnections.isEmpty {
                Text("No friends yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.acceptedFriendConnections) { friend in
                    NavigationLink {
                        FriendTimelineView(friend: friend)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // Same evaluator as the iPhone Friends tab — see
                            // AppViewModel.scheduleSyncHealth(for:).
                            FriendScheduleStatusDot(
                                health: viewModel.scheduleSyncHealth(for: friend)
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                if let nickname = friend.nickname,
                                   !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("\(nickname)  (\(friend.employeeID))")
                                        .font(.headline)
                                } else {
                                    Text(friend.employeeID)
                                        .font(.headline)
                                }
                                if let updatedAt = friend.sharedSchedules.map(\.updatedAt).max() {
                                    Text("Last Updated: \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if let linkedAt = friend.linkedAt {
                                    Text("Linked: \(linkedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            onRenameFriend(friend)
                        }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            friendPendingRemoval = friend
                        } label: {
                            Label("Unfriend", systemImage: "person.crop.circle.badge.xmark")
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("View Friend's Schedule")
                Spacer()
                Button("Sync") {
                    Task { await viewModel.syncFriendCloudKit(reason: "ipad manual") }
                }
                .disabled(viewModel.isSyncingFriendCloudKit)
            }
        }

        if !viewModel.incomingFriendRequestConnections.isEmpty {
            Section("Friend Requests") {
                ForEach(viewModel.incomingFriendRequestConnections) { friend in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend.employeeID)
                            Text("Waiting for your approval")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                        Spacer()
                        Button {
                            Task {
                                await viewModel.acceptIncomingFriendRequest(friend.id)
                            }
                        } label: {
                            Label("Accept", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }

        if !viewModel.pendingFriendConnections.isEmpty {
            Section("Pending") {
                ForEach(viewModel.pendingFriendConnections) { friend in
                    HStack {
                        Text(friend.employeeID)
                        Spacer()
                        Text("Pending")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task {
                                await viewModel.cancelPendingFriendRequest(friend.id)
                            }
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                    }
                }
            }
        }

        Section("Add Friend") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("GEMS ID", text: $employeeIDInput)
                    .textInputAutocapitalization(.characters)
                    .textContentType(.none)
                Button("Send Request") {
                    let id = employeeIDInput
                    guard !id.isEmpty else { return }
                    Task { await viewModel.submitFriendRequest(employeeID: id) }
                    employeeIDInput = ""
                }
                .disabled(employeeIDInput.isEmpty || !viewModel.isIdentityVerified)
            }
        }

        }
        .confirmationDialog(
            friendPendingRemoval.map { "Unfriend \($0.displayName)?" } ?? "Unfriend?",
            isPresented: Binding(
                get: { friendPendingRemoval != nil },
                set: { if !$0 { friendPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Unfriend", role: .destructive) {
                if let friend = friendPendingRemoval {
                    Task {
                        await viewModel.removeFriend(friend.id)
                    }
                }
                friendPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                friendPendingRemoval = nil
            }
        } message: {
            if let friend = friendPendingRemoval {
                Text("This removes \(friend.displayName) from Friends and stops sharing schedules with this pilot.")
            }
        }
    }
}

#Preview {
    IPadOperationalWorkspaceView()
        .environmentObject(AppViewModel.shared)
}
