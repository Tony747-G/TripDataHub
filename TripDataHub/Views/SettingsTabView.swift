import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SettingsTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @AppStorage("appearance_mode") private var appearanceModeRawValue = AppearanceMode.system.rawValue
    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    @AppStorage(OperationalSettings.crewBaseKey) private var crewBaseRawValue = OperationalSettings.defaultCrewBase.rawValue
    @AppStorage("pilot_qualification") private var pilotQualificationRawValue = PilotQualification.captain.rawValue
    @AppStorage("bid_transition_timeline_enabled") private var bidTransitionTimelineEnabled = true
    @AppStorage("notification_48h_enabled") private var notify48h = false
    @AppStorage("notification_24h_enabled") private var notify24h = false
    @AppStorage("notification_12h_enabled") private var notify12h = false
    @AppStorage("faa_medical_expiry_date") private var faaMedicalExpiryDate = ""
    @AppStorage("passport_expiry_date") private var passportExpiryDate = ""
    @AppStorage("china_visa_expiry_date") private var chinaVisaExpiryDate = ""
    @State private var showNotificationDeniedAlert = false
    @State private var showLogTenExportWarning = false
    @State private var logTenExportOutput: LogTenExportOutput?
#if DEBUG
    @State private var verifyGemsIDInput = ""
    @State private var verifyDOBDate = Date()
#endif

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
    private var logTenExportSection: some View {
        Section {
            Button("Export LogTen Pro CSV") {
                showLogTenExportWarning = true
            }
            if let message = viewModel.logTenExportMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("LogTen Pro Export (Beta)")
        } footer: {
            Text("Exports CrewAccess flights as UTC CSV columns: DATE, Flight Number, FROM, TO, STD, STA, ATD, ATA.")
                .font(.footnote)
        }
    }

    @ViewBuilder
    private var settingsListContent: some View {
        List {
            SettingsSupportSection()

#if DEBUG
            SettingsAccountSection(
                verifyGemsIDInput: $verifyGemsIDInput,
                verifyDOBDate: $verifyDOBDate,
                formatDOB: formatDOB
            )
#endif

            SettingsCrewBaseSection(crewBaseRawValue: $crewBaseRawValue)

            SettingsQualificationSection(
                qualificationRawValue: $pilotQualificationRawValue,
                bidTransitionTimelineEnabled: $bidTransitionTimelineEnabled
            )

            SettingsDisplaySection(
                appearanceMode: appearanceModeBinding,
                fontSizeOption: fontSizeOptionBinding
            )

            SettingsReadinessExpirySection(
                faaMedicalExpiryDate: $faaMedicalExpiryDate,
                passportExpiryDate: $passportExpiryDate,
                chinaVisaExpiryDate: $chinaVisaExpiryDate,
                domicileTimeZone: DomicileSupport.timeZone(for: crewBaseRawValue)
            )

            SettingsNotificationSection(
                notify48h: $notify48h,
                notify24h: $notify24h,
                notify12h: $notify12h
            )

            Section {
                NavigationLink("CrewAccess Import Help") {
                    CrewAccessImportHelpView()
                }
            }

            logTenExportSection
        }
        .scrollDismissesKeyboard(.interactively)
    }

#if DEBUG
    private func formatDOB(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
#endif

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
            .onAppear {
                Task {
                    await viewModel.refreshNotificationAuthorizationStatus()
                    await viewModel.applyCrewAccessRetentionPolicy()
                    if viewModel.notificationAuthorizationStatus == .denied {
                        notify48h = false
                        notify24h = false
                        notify12h = false
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
            .onChange(of: notify12h) { _, newValue in
                Task {
                    await viewModel.updateNotificationPreferencesFromSettings(triggeredByEnablingToggle: newValue)
                    if newValue && viewModel.notificationAuthorizationStatus == .denied {
                        notify12h = false
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
                Text("Enable notifications in iOS Settings to receive 48h/24h/12h reminders.")
            }
            .alert("Export LogTen Pro CSV?", isPresented: $showLogTenExportWarning) {
                Button("Cancel", role: .cancel) {}
                Button("AGREE") {
                    logTenExportOutput = viewModel.exportCrewAccessFlightsLogTenCSV()
                }
            } message: {
                Text("Only past flights included in this export will be marked as exported. Past flights kept only for LogTen export will be removed from the pending export queue after the share completes. Future flights remain saved.")
            }
#if canImport(UIKit)
            .sheet(item: $logTenExportOutput, onDismiss: {
                if let url = logTenExportOutput?.url {
                    try? FileManager.default.removeItem(at: url)
                }
                logTenExportOutput = nil
            }) { output in
                ActivityView(activityItems: [output.url]) { completed in
                    if completed {
                        viewModel.markLogTenExportCompleted(output)
                    }
                    try? FileManager.default.removeItem(at: output.url)
                    logTenExportOutput = nil
                }
            }
#endif
        }
    }

    private func openSystemSettings() {
#if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
#endif
    }
}

#if canImport(UIKit)
private struct ActivityView: UIViewControllerRepresentable {
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
