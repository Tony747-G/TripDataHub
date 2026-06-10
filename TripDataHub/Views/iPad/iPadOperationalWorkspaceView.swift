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
    /// ポートレート時にトリップバータップで表示するシートのトリップID
    @State private var portraitTripSheetID: String? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Main split layout
            GeometryReader { geo in
                let isPortrait = geo.size.height > geo.size.width
                let sidebarWidth = geo.size.width * 0.30
                if isPortrait {
                    // ポートレート: カレンダーのみ全幅、トリップバータップでシート
                    IPadBidPeriodCalendarView(
                        selectedTripID: $portraitTripSheetID,
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
                            selectedTripID: $selectedTripID,
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
            await viewModel.fetchCrewAccessImportFilesIfNeeded(reason: "ipad workspace")
            await viewModel.fetchDeviceScheduleIfNeeded(reason: "ipad workspace")
            if AppEnvironment.isFriendSharingVisible {
                await viewModel.syncFriendCloudKit(reason: "ipad workspace opened")
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.consumePendingAppGroupImportIfAvailable()
                Task {
                    if AppEnvironment.isFriendSharingVisible {
                        await viewModel.syncFriendCloudKit(reason: "ipad workspace active")
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { portraitTripSheetID != nil },
            set: { if !$0 { portraitTripSheetID = nil } }
        )) {
            NavigationStack {
                IPadTimelineSidebarView(selectedTripID: $portraitTripSheetID, scrollToDefaultTrigger: $timelineScrollTrigger)
                    .environmentObject(viewModel)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { portraitTripSheetID = nil }
                        }
                    }
            }
        }
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

    private let verticalMenuItemSpacing: CGFloat = 58

    private var verticalMenuItemCount: Int {
        5
            + (AppEnvironment.isFriendSharingVisible ? 1 : 0)
            + (AppEnvironment.isOpenTimeVisible ? 1 : 0)
    }

    private var browserMenuIndex: Int {
        1
            + (AppEnvironment.isFriendSharingVisible ? 1 : 0)
            + (AppEnvironment.isOpenTimeVisible ? 1 : 0)
    }

    private var floatingMenu: some View {
        ZStack {
            verticalMenuItem(index: 0, icon: "calendar", label: "Timeline", isActive: isOwnTimeline) {
                sidebarContent = .ownTimeline
                timelineScrollTrigger = UUID()
                withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
            }
            if AppEnvironment.isFriendSharingVisible {
                verticalMenuItem(index: 1, icon: "person.2", label: "Friends") {
                    showingFriends = true
                    withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
                }
            }
            if AppEnvironment.isOpenTimeVisible {
                verticalMenuItem(
                    index: AppEnvironment.isFriendSharingVisible ? 2 : 1,
                    icon: "clock",
                    label: "OpenTime"
                ) {
                    showingOpenTime = true
                    withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
                }
            }
            verticalMenuItem(index: browserMenuIndex, icon: "globe", label: "Browser") {
                showingBrowser = true
                withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
            }
            verticalMenuItem(index: browserMenuIndex + 1, icon: "plus", label: "Add Event") {
                showingAddEvent = true
                withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
            }
            verticalMenuItem(index: browserMenuIndex + 2, icon: "square.and.arrow.up", label: "Print") {
                exportIncludesBidLayer = bidTransitionTimelineEnabled
                exportIncludesPersonalLayer = true
                showingBidPeriodExportOptions = true
                withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
            }
            verticalMenuItem(index: browserMenuIndex + 3, icon: "gearshape", label: "Settings") {
                showingSettings = true
                withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
            }
            menuToggleButton
        }
    }

    private func verticalMenuItem(
        index: Int,
        icon: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let yOffset = -CGFloat(verticalMenuItemCount - index) * verticalMenuItemSpacing
        let delay = menuExpanded
            ? Double(index) * 0.045
            : Double(verticalMenuItemCount - 1 - index) * 0.03
        return menuItem(icon: icon, label: label, isActive: isActive, action: action)
            .offset(x: 0, y: menuExpanded ? yOffset : 0)
            .scaleEffect(menuExpanded ? 1 : 0.1)
            .opacity(menuExpanded ? 1 : 0)
            .animation(
                .spring(response: 0.4, dampingFraction: 0.72).delay(delay),
                value: menuExpanded
            )
    }

    private var menuToggleButton: some View {
        Button {
            withAnimation(.spring(duration: 0.22)) { menuExpanded.toggle() }
        } label: {
            Image(systemName: menuExpanded ? "xmark" : "line.3.horizontal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Color(.tertiarySystemFill))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func menuItem(
        icon: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(width: 44, height: 44)
                .background(Color(.tertiarySystemFill))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
        Section("View Friend's Schedule") {
            if viewModel.acceptedFriendConnections.isEmpty {
                Text("No friends yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.acceptedFriendConnections) { friend in
                    NavigationLink {
                        FriendTimelineView(friend: friend)
                    } label: {
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

        Section {
            Button("Sync Friends") {
                Task { await viewModel.syncFriendCloudKit(reason: "ipad manual") }
            }
            .disabled(viewModel.isSyncingFriendCloudKit)
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
