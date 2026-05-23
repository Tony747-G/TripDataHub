import SwiftUI

// MARK: - Sidebar content type

private enum IPadSidebarContent {
    case ownTimeline
}

// MARK: - Main workspace

struct IPadOperationalWorkspaceView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @AppStorage("appearance_mode") private var appearanceModeRawValue = AppearanceMode.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    private var selectedAppearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    @State private var selectedTripID: String?
    @State private var selectedBidPeriodID: String?
    @State private var sidebarContent: IPadSidebarContent = .ownTimeline
    @State private var timelineScrollTrigger = UUID()
    @State private var menuExpanded = false
    @State private var showingBrowser = false
    @State private var showingSettings = false
    @State private var showingAddEvent = false
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
            if !AppEnvironment.isAppStoreReviewMode {
                await viewModel.syncFriendCloudKit(reason: "ipad workspace opened")
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.consumePendingAppGroupImportIfAvailable()
                Task {
                    if !AppEnvironment.isAppStoreReviewMode {
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
                    get: { viewModel.isShowingLoginSheet && !AppEnvironment.isAppStoreReviewMode },
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

    private let verticalMenuItemCount = 4
    private let verticalMenuItemSpacing: CGFloat = 58

    private var floatingMenu: some View {
        ZStack {
            verticalMenuItem(index: 0, icon: "calendar", label: "Timeline", isActive: isOwnTimeline) {
                sidebarContent = .ownTimeline
                timelineScrollTrigger = UUID()
                withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
            }
            verticalMenuItem(index: 1, icon: "globe", label: "Browser") {
                showingBrowser = true
                withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
            }
            verticalMenuItem(index: 2, icon: "plus", label: "Add Event") {
                showingAddEvent = true
                withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
            }
            verticalMenuItem(index: 3, icon: "gearshape", label: "Settings") {
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
}

// MARK: - Friends sheet

private struct IPadFriendsSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingFriend: FriendConnection?
    @State private var nicknameInput = ""

    var body: some View {
        NavigationStack {
            List {
                FriendsManagementSection()
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

    var body: some View {
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
}

#Preview {
    IPadOperationalWorkspaceView()
        .environmentObject(AppViewModel.shared)
}
