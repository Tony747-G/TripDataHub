import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("auto_fetch_on_open_enabled") private var autoFetchOnOpen = true
    @AppStorage("appearance_mode") private var appearanceModeRawValue = AppearanceMode.system.rawValue
    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    @AppStorage("app_font_size_migrated_to_medium") private var didMigrateFontSizeToMedium = false
    @State private var isShowingImportPreviewFromExternalOpen = false
    @State private var selectedTab = 0
    /// Increments every time the Timeline tab is tapped (including re-taps while
    /// already on Timeline), so TimelineTabView can reliably re-trigger its scroll.
    @State private var timelineScrollTrigger = 0

    private var selectedAppearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    var body: some View {
        TabView(selection: Binding(
            get: { selectedTab },
            set: { newTab in
                if newTab == 0 { timelineScrollTrigger += 1 }
                selectedTab = newTab
            }
        )) {
            TimelineTabView(scrollTrigger: timelineScrollTrigger)
                .tabItem {
                    Label("Timeline", systemImage: "calendar")
                }
                .tag(0)

            if !AppEnvironment.isAppStoreReviewMode {
                OpenTimeTabView()
                    .tabItem {
                        Label("OpenTime", systemImage: "clock")
                    }
                    .tag(1)
            }

            if !AppEnvironment.isAppStoreReviewMode {
                FriendsTabView()
                    .tabItem {
                        Label("Friends", systemImage: "person.2")
                    }
                    .tag(2)
            }

            BrowserTabView()
                .tabItem {
                    Label("Browser", systemImage: "globe")
                }
                .tag(3)

            if viewModel.canAccessAdminTab {
                AdminTabView()
                    .tabItem {
                        Label("Admin", systemImage: "checklist")
                    }
                    .tag(4)
            }

            SettingsTabView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(5)
        }
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
        .sheet(isPresented: $isShowingImportPreviewFromExternalOpen) {
            NavigationStack {
                ImportPreviewView()
            }
        }
        .onAppear {
            migrateFontSizeDefaultIfNeeded()
            viewModel.consumePendingAppGroupImportIfAvailable()
            viewModel.refreshFlightCountdownPresentation()
            Task {
                await viewModel.autoFetchOnAppActiveIfEnabled(autoFetchOnOpen)
                if !AppEnvironment.isAppStoreReviewMode {
                    await viewModel.syncFriendCloudKit(reason: "app opened")
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.consumePendingAppGroupImportIfAvailable()
                viewModel.refreshFlightCountdownPresentation()
                Task {
                    await viewModel.autoFetchOnAppActiveIfEnabled(autoFetchOnOpen)
                    if !AppEnvironment.isAppStoreReviewMode {
                        await viewModel.syncFriendCloudKit(reason: "app active")
                    }
                }
            }
        }
        .onChange(of: viewModel.schedules) { _, _ in
            viewModel.refreshFlightCountdownPresentation()
            viewModel.handleSchedulesChangedForSharing()
        }
        .onChange(of: viewModel.crewAccessSchedules) { _, _ in
            viewModel.refreshFlightCountdownPresentation()
        }
        .onChange(of: viewModel.pendingImport?.id) { _, newValue in
            if newValue != nil {
                isShowingImportPreviewFromExternalOpen = true
            }
        }
        .preferredColorScheme(selectedAppearanceMode.colorScheme)
    }

    private func migrateFontSizeDefaultIfNeeded() {
        guard !didMigrateFontSizeToMedium else { return }
        appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
        didMigrateFontSizeToMedium = true
    }
}

#Preview {
    RootTabView()
        .environmentObject(AppViewModel())
}
