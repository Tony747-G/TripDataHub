import SwiftUI

// MARK: - Sidebar content type

private enum IPadSidebarContent {
    case ownTimeline
    case openTime
    case friendTimeline(friend: FriendConnection)
}

// MARK: - Main workspace

struct IPadOperationalWorkspaceView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @AppStorage("appearance_mode") private var appearanceModeRawValue = AppearanceMode.system.rawValue

    private var selectedAppearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    @State private var selectedTripID: String?
    @State private var selectedBidPeriodID: String?
    @State private var isFriendsOverlayEnabled = false
    @State private var sidebarContent: IPadSidebarContent = .ownTimeline
    @State private var menuExpanded = false
    @State private var showingFriends = false
    @State private var showingBrowser = false
    @State private var showingSettings = false
    @State private var friendForSidebar: FriendConnection?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Main split layout
            GeometryReader { geo in
                let sidebarWidth = geo.size.width * 0.30
                HStack(spacing: 0) {
                    sidebarView
                        .frame(width: sidebarWidth)
                        .clipped()
                    Divider()
                    IPadBidPeriodCalendarView(
                        selectedTripID: $selectedTripID,
                        selectedBidPeriodID: $selectedBidPeriodID,
                        isFriendsOverlayEnabled: $isFriendsOverlayEnabled
                    )
                    .frame(width: geo.size.width - sidebarWidth - 1)
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
            await viewModel.fetchCrewAccessImportFilesIfNeeded(reason: "ipad workspace")
            await viewModel.fetchDeviceScheduleIfNeeded(reason: "ipad workspace")
        }
        .onChange(of: friendForSidebar?.id) { _, friendID in
            if let friendID,
               let friend = viewModel.acceptedFriendConnections.first(where: { $0.id == friendID }) {
                sidebarContent = .friendTimeline(friend: friend)
                friendForSidebar = nil
            }
        }
        .sheet(isPresented: $showingFriends) {
            IPadFriendsSheet(friendForSidebar: $friendForSidebar)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingBrowser) {
            NavigationStack { BrowserTabView(presentsImportPreview: true) }
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsTabView() }
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingLoginSheet) {
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

    // MARK: Sidebar switcher

    @ViewBuilder
    private var sidebarView: some View {
        switch sidebarContent {
        case .ownTimeline:
            IPadTimelineSidebarView(selectedTripID: $selectedTripID)
        case .openTime:
            OpenTimeTabView()
        case .friendTimeline(let friend):
            IPadFriendTimelineSidebarView(
                friend: friend,
                selectedTripID: $selectedTripID,
                onBack: { sidebarContent = .ownTimeline }
            )
        }
    }

    // MARK: Floating menu

    // Fan parameters: quarter-circle arc from straight up (90°) to straight left (180°)
    // Radius 130pt gives ~51pt arc gap between adjacent 44pt icons — no overlap.
    private let fanRadius: CGFloat = 130
    private let fanStartAngle: Double = 90
    private let fanEndAngle: Double = 180
    private let fanItemCount = 5

    private func fanOffset(index: Int) -> CGSize {
        let angle = fanStartAngle + Double(index) * (fanEndAngle - fanStartAngle) / Double(fanItemCount - 1)
        let rad = angle * .pi / 180
        return CGSize(width: fanRadius * cos(rad), height: -fanRadius * sin(rad))
    }

    private var floatingMenu: some View {
        ZStack {
            fanItem(index: 0, icon: "calendar", label: "Timeline", isActive: isOwnTimeline) {
                sidebarContent = .ownTimeline
                withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
            }
            fanItem(index: 1, icon: "clock", label: "Open Time", isActive: isOpenTime) {
                sidebarContent = .openTime
                withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
            }
            fanItem(index: 2, icon: "person.2", label: "Friends") {
                showingFriends = true
                withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
            }
            fanItem(index: 3, icon: "globe", label: "Browser") {
                showingBrowser = true
                withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
            }
            fanItem(index: 4, icon: "gearshape", label: "Settings") {
                showingSettings = true
                withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
            }
            menuToggleButton
        }
    }

    private func fanItem(
        index: Int,
        icon: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let offset = fanOffset(index: index)
        let delay = menuExpanded
            ? Double(index) * 0.045
            : Double(fanItemCount - 1 - index) * 0.03
        return menuItem(icon: icon, label: label, isActive: isActive, action: action)
            .offset(menuExpanded ? offset : .zero)
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

    private var isOpenTime: Bool {
        if case .openTime = sidebarContent { return true }
        return false
    }
}

// MARK: - Friend timeline sidebar

private struct IPadFriendTimelineSidebarView: View {
    let friend: FriendConnection
    @Binding var selectedTripID: String?
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header with back button
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
                Text(friend.employeeID)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(.secondarySystemBackground))
            .overlay(alignment: .bottom) { Divider() }

            ScheduleTimelineRendererView(
                schedules: friend.sharedSchedules,
                emptyStateMessage: "No shared timeline for \(friend.employeeID)."
            )
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Friends sheet

private struct IPadFriendsSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var friendForSidebar: FriendConnection?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // View in sidebar section — only for accepted friends
                if !viewModel.acceptedFriendConnections.isEmpty {
                    Section("View in Sidebar") {
                        ForEach(viewModel.acceptedFriendConnections, id: \.id) { friend in
                            Button {
                                friendForSidebar = friend
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(friend.employeeID)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text("View their timeline in sidebar")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "sidebar.left")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }

                // Full friends management
                FriendsManagementSection()
            }
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
        Section("Friends") {
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
                            Text(friend.employeeID)
                                .font(.headline)
                            if let linkedAt = friend.linkedAt {
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
