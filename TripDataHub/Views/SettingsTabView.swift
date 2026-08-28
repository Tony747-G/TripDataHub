import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SettingsTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @AppStorage("auto_fetch_on_open_enabled") private var autoFetchOnOpen = true
    @AppStorage("appearance_mode") private var appearanceModeRawValue = AppearanceMode.system.rawValue
    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    @AppStorage("bid_transition_timeline_enabled") private var bidTransitionTimelineEnabled = true
    @AppStorage(OperationalSettings.crewBaseKey) private var crewBaseRawValue = OperationalSettings.defaultCrewBase.rawValue
    @AppStorage("notification_48h_enabled") private var notify48h = false
    @AppStorage("notification_24h_enabled") private var notify24h = true
    @AppStorage(ProfileStorageKeys.faaMedicalExpiryDate) private var faaMedicalExpiryDate = ""
    @AppStorage(ProfileStorageKeys.passportExpiryDate) private var passportExpiryDate = ""
    @AppStorage(ProfileStorageKeys.chinaVisaExpiryDate) private var chinaVisaExpiryDate = ""
    @State private var showNotificationDeniedAlert = false

    private var appearanceModeBinding: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceModeRawValue) ?? .system },
            set: { appearanceModeRawValue = $0.rawValue }
        )
    }

    private var fontSizeOptionBinding: Binding<AppFontSizeOption> {
        Binding(
            get: { AppFontSizeOption(rawValue: appFontSizeOptionRawValue) ?? .medium },
            set: { appFontSizeOptionRawValue = $0.rawValue }
        )
    }

    @ViewBuilder
    private var settingsListContent: some View {
        List {
            SettingsDisplaySection(
                appearanceMode: appearanceModeBinding,
                fontSizeOption: fontSizeOptionBinding,
                bidTransitionTimelineEnabled: $bidTransitionTimelineEnabled
            )

            SettingsReadinessExpirySection(
                faaMedicalExpiryDate: syncedProfileBinding($faaMedicalExpiryDate),
                passportExpiryDate: syncedProfileBinding($passportExpiryDate),
                chinaVisaExpiryDate: syncedProfileBinding($chinaVisaExpiryDate),
                domicileTimeZone: DomicileSupport.timeZone(for: crewBaseRawValue)
            )

            SettingsNotificationSection(
                notify48h: $notify48h,
                notify24h: $notify24h
            )

            Section {
                NavigationLink("CrewAccess Import Help") {
                    CrewAccessImportHelpView()
                }
            } header: {
                sectionHeader("CrewAccess")
            }

            if AppEnvironment.isTripBoardFetchVisible {
                SettingsTripBoardFetchSection(autoFetchOnOpen: $autoFetchOnOpen)
            }

#if DEBUG
            Section {
                Button {
                    Task {
                        if viewModel.isDebugFlightCountdownFixtureActive {
                            await viewModel.stopDebugFlightCountdownFixture()
                        } else {
                            await viewModel.startDebugFlightCountdownFixture()
                        }
                    }
                } label: {
                    Label(
                        viewModel.isDebugFlightCountdownFixtureActive
                            ? "Stop Home Widget Fixture"
                            : "Start Home Widget Fixture",
                        systemImage: viewModel.isDebugFlightCountdownFixtureActive
                            ? "stop.circle"
                            : "airplane.circle"
                    )
                }
            } header: {
                sectionHeader("DEBUG Validation")
            } footer: {
                Text("In-memory only. Does not modify or publish schedule data.")
            }
#endif

            SettingsProfileSection()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    var body: some View {
        NavigationStack {
            settingsListContent
#if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
#endif
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Spacer()
                    Text("Settings")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.vertical, 8)
                .background(.background)
            }
            // The legacy 12h migration used to live here. It now runs in AppViewModel startup
            // (`migrateLegacyNotificationPreferencesIfNeeded`), because a migration that only
            // happens when the user opens Settings is not a migration. Repeating it here would
            // only add a redundant reschedule on every appearance.
            .onAppear {
                Task {
                    await viewModel.refreshNotificationAuthorizationStatus()
                    await viewModel.applyCrewAccessRetentionPolicy()
                    if viewModel.notificationAuthorizationStatus == .denied {
                        notify48h = false
                        notify24h = false
                    }
                }
            }
            .onChange(of: notify48h) { _, newValue in
                Task {
                    await viewModel.updateNotificationPreferencesFromSettings(triggeredByEnablingToggle: newValue)
                    if newValue && viewModel.notificationAuthorizationStatus == .denied {
                        notify48h = false
                        showNotificationDeniedAlert = true
                    }
                }
            }
            .onChange(of: notify24h) { _, newValue in
                Task {
                    await viewModel.updateNotificationPreferencesFromSettings(triggeredByEnablingToggle: newValue)
                    if newValue && viewModel.notificationAuthorizationStatus == .denied {
                        notify24h = false
                        showNotificationDeniedAlert = true
                    }
                }
            }
            .alert("Notifications Are Disabled", isPresented: $showNotificationDeniedAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Open Settings") {
                    openSystemSettings()
                }
            } message: {
                Text("Enable notifications in iOS Settings to receive 48h/24h reminders.")
            }
        }
    }

    private func syncedProfileBinding(_ binding: Binding<String>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                guard binding.wrappedValue != newValue else { return }
                binding.wrappedValue = newValue
                viewModel.profileSettingsDidChange()
            }
        )
    }

    private func openSystemSettings() {
#if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
#endif
    }
}

#if canImport(UIKit)
struct ActivityView: UIViewControllerRepresentable {
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
