import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("auto_fetch_on_open_enabled") private var autoFetchOnOpen = true
    @AppStorage("appearance_mode") private var appearanceModeRawValue = AppearanceMode.system.rawValue
    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    @AppStorage("app_font_size_migrated_to_medium") private var didMigrateFontSizeToMedium = false
    @State private var isShowingImportPreviewFromExternalOpen = false

    private var selectedAppearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    var body: some View {
        TabView {
            TimelineTabView()
                .tabItem {
                    Label("Timeline", systemImage: "calendar")
                }

            OpenTimeTabView()
                .tabItem {
                    Label("OpenTime", systemImage: "clock")
                }

            FriendsTabView()
                .tabItem {
                    Label("Friends", systemImage: "person.2")
                }

            if viewModel.canAccessAdminTab {
                AdminTabView()
                    .tabItem {
                        Label("Admin", systemImage: "checklist")
                    }
            }

            SettingsTabView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
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
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.consumePendingAppGroupImportIfAvailable()
                viewModel.refreshFlightCountdownPresentation()
                Task {
                    await viewModel.autoFetchOnAppActiveIfEnabled(autoFetchOnOpen)
                }
            }
        }
        .onChange(of: viewModel.schedules) { _, _ in
            viewModel.refreshFlightCountdownPresentation()
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
