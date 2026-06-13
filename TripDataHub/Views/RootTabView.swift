import SwiftUI

private enum IPhonePrimaryScreen {
    case timeline
    case calendar
}

struct RootTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("auto_fetch_on_open_enabled") private var autoFetchOnOpen = true
    @AppStorage("appearance_mode") private var appearanceModeRawValue = AppearanceMode.system.rawValue
    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    @AppStorage("app_font_size_migrated_to_medium") private var didMigrateFontSizeToMedium = false
    @State private var isShowingImportPreviewFromExternalOpen = false
    @State private var primaryScreen: IPhonePrimaryScreen = .timeline
    @State private var hasLoadedCalendar = false
    @State private var selectedCalendarTripID: String?
    @State private var timelineScrollTrigger = 0
    @State private var menuExpanded = false
    @State private var showingFriends = false
    @State private var showingOpenTime = false
    @State private var showingBrowser = false
    @State private var showingSettings = false
    @State private var showingAddEvent = false

    private var selectedAppearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                TimelineTabView(
                    scrollTrigger: timelineScrollTrigger,
                    showsAddEventButton: false
                )
                .opacity(primaryScreen == .timeline ? 1 : 0)
                .allowsHitTesting(primaryScreen == .timeline)
                .accessibilityHidden(primaryScreen != .timeline)

                if primaryScreen == .calendar || hasLoadedCalendar {
                    IPhoneCalendarTabView(selectedTripID: $selectedCalendarTripID)
                        .opacity(primaryScreen == .calendar ? 1 : 0)
                        .allowsHitTesting(primaryScreen == .calendar)
                        .accessibilityHidden(primaryScreen != .calendar)
                }
            }

            if menuExpanded {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.22)) { menuExpanded = false }
                    }
            }

            floatingMenu
                .padding(.trailing, 14)
                .padding(.bottom, 24)
        }
        .sheet(isPresented: Binding(
            get: {
                viewModel.isShowingLoginSheet
                    && AppEnvironment.isTripBoardFetchVisible
                    && !showingSettings
            },
            set: { viewModel.isShowingLoginSheet = $0 }
        )) {
            tripBoardLoginSheet
        }
        .sheet(isPresented: $showingBrowser) {
            NavigationStack { BrowserTabView(presentsImportPreview: true) }
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingFriends) {
            FriendsTabView()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingOpenTime) {
            OpenTimeTabView()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingSettings) {
            // The login sheet must nest here while Settings is presented — a second
            // .sheet on the root cannot present over an already-presented sheet.
            NavigationStack { SettingsTabView() }
                .environmentObject(viewModel)
                .sheet(isPresented: Binding(
                    get: { viewModel.isShowingLoginSheet && AppEnvironment.isTripBoardFetchVisible },
                    set: { viewModel.isShowingLoginSheet = $0 }
                )) {
                    tripBoardLoginSheet
                }
        }
        .sheet(isPresented: $showingAddEvent) {
            ManualEventAddSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $isShowingImportPreviewFromExternalOpen) {
            NavigationStack {
                ImportPreviewView()
            }
        }
        .onAppear {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: ProfileStorageKeys.lastSeenAt)
            migrateFontSizeDefaultIfNeeded()
            viewModel.consumePendingAppGroupImportIfAvailable()
            viewModel.refreshFlightCountdownPresentation()
            Task {
                await viewModel.autoFetchOnAppActiveIfEnabled(autoFetchOnOpen)
                if AppEnvironment.isFriendSharingVisible {
                    await viewModel.syncFriendCloudKit(reason: "app opened")
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: ProfileStorageKeys.lastSeenAt)
                viewModel.consumePendingAppGroupImportIfAvailable()
                viewModel.refreshFlightCountdownPresentation()
                Task {
                    await viewModel.autoFetchOnAppActiveIfEnabled(autoFetchOnOpen)
                    if AppEnvironment.isFriendSharingVisible {
                        await viewModel.syncFriendCloudKit(reason: "app active")
                    }
                }
            }
        }
        .onChange(of: viewModel.scheduleDataRevision) { _, _ in
            viewModel.refreshFlightCountdownPresentation()
            viewModel.handleSchedulesChangedForSharing()
        }
        .onChange(of: viewModel.pendingImport?.id) { _, newValue in
            if newValue != nil, !showingBrowser {
                isShowingImportPreviewFromExternalOpen = true
            }
        }
        .onChange(of: primaryScreen) { _, newScreen in
            if newScreen == .calendar {
                hasLoadedCalendar = true
            } else {
                selectedCalendarTripID = nil
            }
        }
        .preferredColorScheme(selectedAppearanceMode.colorScheme)
    }

    private let verticalMenuItemSpacing: CGFloat = 54

    private var tripBoardLoginSheet: some View {
        TripBoardLoginView(
            onAuthenticated: { cookies, url in
                viewModel.handleLoginSucceeded(cookies: cookies, url: url)
            },
            onCancel: {
                viewModel.handleLoginCanceled()
            }
        )
    }

    private var floatingMenu: some View {
        var items: [ExpandableFloatingMenuItem] = [
            ExpandableFloatingMenuItem(
                id: "timeline",
                icon: "list.bullet.rectangle",
                label: "Timeline",
                isActive: primaryScreen == .timeline
            ) {
                primaryScreen = .timeline
                timelineScrollTrigger += 1
            },
            ExpandableFloatingMenuItem(
                id: "calendar",
                icon: "calendar",
                label: "Calendar",
                isActive: primaryScreen == .calendar
            ) {
                primaryScreen = .calendar
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
        items.append(ExpandableFloatingMenuItem(id: "settings", icon: "gearshape", label: "Settings") {
            showingSettings = true
        })
        return ExpandableFloatingMenu(isExpanded: $menuExpanded, items: items, itemSpacing: verticalMenuItemSpacing)
    }

    private func migrateFontSizeDefaultIfNeeded() {
        guard !didMigrateFontSizeToMedium else { return }
        appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
        didMigrateFontSizeToMedium = true
    }
}

private struct IPhoneCalendarTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var selectedTripID: String?
    @State private var selectedBidPeriodID: String?

    var body: some View {
        IPadBidPeriodCalendarView(
            selectedTripID: $selectedTripID,
            selectedBidPeriodID: $selectedBidPeriodID,
            presentationStyle: .iPhone
        )
        // Centered popup scoped to the tapped trip (titled by its Trip Id),
        // replacing the previous full-timeline sheet.
        .overlay {
            if let tripID = selectedTripID {
                CalendarTripTimelinePopup(tripID: tripID) {
                    selectedTripID = nil
                }
                .environmentObject(viewModel)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: selectedTripID)
    }
}

#Preview {
    RootTabView()
        .environmentObject(AppViewModel())
}
