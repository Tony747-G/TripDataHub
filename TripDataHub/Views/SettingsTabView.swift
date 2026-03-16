import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SettingsTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @AppStorage("auto_fetch_on_open_enabled") private var autoFetchOnOpen = true
    @AppStorage("appearance_mode") private var appearanceModeRawValue = AppearanceMode.system.rawValue
    @AppStorage("app_font_size_option") private var appFontSizeOptionRawValue = AppFontSizeOption.medium.rawValue
    @AppStorage("notification_48h_enabled") private var notify48h = false
    @AppStorage("notification_24h_enabled") private var notify24h = false
    @AppStorage("notification_12h_enabled") private var notify12h = false
    @State private var showNotificationDeniedAlert = false
    @State private var isShowingLogTenExportShare = false
    @State private var verifyGemsIDInput = ""
    @State private var verifyDOBDate = Date()
    @State private var crewAccessImportFiles: [CrewAccessImportFile] = []
    @State private var logTenExportURL: URL?

    private static let dobFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter
    }()

    private static let importFileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd, yyyy 'at' HH:mm"
        return formatter
    }()

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

    private func loadCrewAccessImportFiles(afterDelete: Bool = false) async {
        crewAccessImportFiles = await viewModel.listCrewAccessImportFiles()
        if afterDelete {
            NSLog("[CrewAccessFiles] reloaded count=%d", crewAccessImportFiles.count)
        } else {
            NSLog("[CrewAccessFiles] loaded count=%d", crewAccessImportFiles.count)
        }
    }

    private func fileSecondaryText(for file: CrewAccessImportFile) -> String {
        let modifiedDate = file.modifiedAt ?? file.createdAt
        let dateString = modifiedDate.map { Self.importFileDateFormatter.string(from: $0) } ?? "Unknown"
        if let createdAt = file.createdAt, let modifiedAt = file.modifiedAt, abs(modifiedAt.timeIntervalSince(createdAt)) <= 1 {
            return "Added: \(dateString)"
        }
        return "Updated: \(dateString)"
    }

    @ViewBuilder
    private var logTenExportSection: some View {
        Section {
            Button("Export CrewAccess Flights (LogTen CSV)") {
                let output = viewModel.exportCrewAccessFlightsLogTenCSV()
                logTenExportURL = output
                isShowingLogTenExportShare = output != nil
            }
            if let message = viewModel.logTenExportMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("LogTen Pro Export")
        }
    }

    @ViewBuilder
    private var crewAccessFilesSection: some View {
        Section {
            if crewAccessImportFiles.isEmpty {
                Text("No imported files yet. Export from CrewAccess using Zscaler Print, then import.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                let fileCount = crewAccessImportFiles.count
                let inTimelineCount = crewAccessImportFiles.filter { !$0.isOrphan }.count
                Text("Files: \(fileCount) • In Timeline: \(inTimelineCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(crewAccessImportFiles) { file in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(fileSecondaryText(for: file))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    let targetURLs = offsets.map { crewAccessImportFiles[$0].url }
                    guard !targetURLs.isEmpty else { return }
                    Task {
                        await viewModel.deleteCrewAccessImportFiles(urls: targetURLs)
                        await loadCrewAccessImportFiles(afterDelete: true)
                    }
                }
            }
        } header: {
            Text("CrewAccess Imports (Files)")
        }
    }

    @ViewBuilder
    private var settingsListContent: some View {
        List {
            SettingsAccountSection(
                verifyGemsIDInput: $verifyGemsIDInput,
                verifyDOBDate: $verifyDOBDate,
                formatDOB: { Self.dobFormatter.string(from: $0) }
            )

            SettingsTripBoardFetchSection(autoFetchOnOpen: $autoFetchOnOpen)
            crewAccessFilesSection

            Section {
                NavigationLink("CrewAccess Import Help") {
                    CrewAccessImportHelpView()
                }
            }

            SettingsDisplaySection(
                appearanceMode: appearanceModeBinding,
                fontSizeOption: fontSizeOptionBinding
            )

            SettingsNotificationSection(
                notify48h: $notify48h,
                notify24h: $notify24h,
                notify12h: $notify12h
            )

            SettingsPayPeriodsSection()

            logTenExportSection
        }
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
            .onAppear {
                Task {
                    await viewModel.loadSeniorityRecordsIfNeeded()
                    await viewModel.refreshNotificationAuthorizationStatus()
                    await loadCrewAccessImportFiles()
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
#if canImport(UIKit)
            .sheet(isPresented: $isShowingLogTenExportShare, onDismiss: {
                if let url = logTenExportURL {
                    try? FileManager.default.removeItem(at: url)
                }
                logTenExportURL = nil
            }) {
                if let url = logTenExportURL {
                    ActivityView(activityItems: [url])
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

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
