import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
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
    @State private var isShowingCrewAccessImporter = false
    @State private var isShowingImportPreview = false
    @State private var verifyGemsIDInput = ""
    @State private var verifyDOBDate = Date()
    @State private var crewAccessImportFiles: [CrewAccessImportFile] = []
    @State private var overrideIATAInput = ""
    @State private var overrideTimeZoneInput = ""

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
    private var timeZoneOverridesSection: some View {
        Section {
            let unknownAirports = viewModel.unresolvedIATAAirports()
            if unknownAirports.isEmpty {
                Text("No unknown IATA codes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Unknown IATA: \(unknownAirports.joined(separator: ", "))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            TextField("IATA (e.g. HKG)", text: $overrideIATAInput)

            TextField("IANA TZ (e.g. Asia/Hong_Kong)", text: $overrideTimeZoneInput)

            Button("Save TZ Override") {
                viewModel.setTimeZoneOverride(iata: overrideIATAInput, tzID: overrideTimeZoneInput)
                if viewModel.tzOverrideMessage?.hasPrefix("Saved override:") == true {
                    overrideIATAInput = ""
                    overrideTimeZoneInput = ""
                }
            }

            let overrides = viewModel.currentTimeZoneOverrides()
            if !overrides.isEmpty {
                ForEach(overrides.keys.sorted(), id: \.self) { code in
                    Text("\(code) -> \(overrides[code] ?? "")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let tzOverrideMessage = viewModel.tzOverrideMessage {
                Text(tzOverrideMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Time Zone Overrides")
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

            SettingsExperimentalImportSection(
                onTapImportCrewAccessPDF: { isShowingCrewAccessImporter = true }
            )

            crewAccessFilesSection
            timeZoneOverridesSection

            Section {
                NavigationLink("CrewAccess Import Help") {
                    CrewAccessImportHelpView()
                }
            }

            SettingsPayPeriodsSection()

            SettingsDisplaySection(
                appearanceMode: appearanceModeBinding,
                fontSizeOption: fontSizeOptionBinding
            )

            SettingsNotificationSection(
                notify48h: $notify48h,
                notify24h: $notify24h,
                notify12h: $notify12h
            )
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
            .onChange(of: viewModel.pendingImport?.id) { _, newValue in
                if newValue != nil {
                    isShowingImportPreview = true
                }
            }
            .navigationDestination(isPresented: $isShowingImportPreview) {
                ImportPreviewView()
            }
            .alert("Notifications Are Disabled", isPresented: $showNotificationDeniedAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Open Settings") {
                    openSystemSettings()
                }
            } message: {
                Text("Enable notifications in iOS Settings to receive 48h/24h/12h reminders.")
            }
#if canImport(UniformTypeIdentifiers)
            .fileImporter(
                isPresented: $isShowingCrewAccessImporter,
                allowedContentTypes: [.pdf, .item, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    let ext = url.pathExtension
#if canImport(UniformTypeIdentifiers)
                    let contentTypeValue = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier ?? "nil"
#else
                    let contentTypeValue = "unavailable"
#endif
                    NSLog("[Import] Settings picker selected url=%@", url.absoluteString)
                    NSLog("[Import] Settings picker ext=%@ contentType=%@", ext, contentTypeValue)
                    guard url.startAccessingSecurityScopedResource() else {
                        viewModel.crewAccessImportMessage = "Cannot access selected PDF."
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        let data = try Data(contentsOf: url)
                        NSLog("[Import] Settings picker read bytes=%d", data.count)
                        let sniff = LocalImportFileSniffer.sniffPDFSignature(in: data)
                        NSLog("[Import] Settings picker sniffPDF=%@ header=%@", String(sniff.isPDF), sniff.header)
                        guard sniff.isPDF else {
                            viewModel.crewAccessImportMessage = "Selected file is not a PDF. Re-export using Zscaler Print and retry."
                            return
                        }
                        _ = viewModel.importCrewAccessPDFData(data, sourceFileName: url.lastPathComponent)
                    } catch {
                        viewModel.crewAccessImportMessage = "Failed to read PDF: \(error.localizedDescription)"
                    }
                case let .failure(error):
                    viewModel.crewAccessImportMessage = "PDF import canceled: \(error.localizedDescription)"
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

private enum LocalImportFileSniffer {
    static func sniffPDFSignature(in data: Data) -> (isPDF: Bool, header: String) {
        let prefix = data.prefix(8)
        let ascii = String(decoding: prefix, as: UTF8.self)
        let sanitizedASCII = ascii.unicodeScalars
            .map { scalar in
                let value = scalar.value
                let isPrintableASCII = scalar.isASCII && value >= 32 && value <= 126
                return isPrintableASCII ? String(scalar) : "."
            }
            .joined()
        let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
        let header = "\(sanitizedASCII) [\(hex)]"
        let isPDF = data.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D])
        return (isPDF, header)
    }
}
