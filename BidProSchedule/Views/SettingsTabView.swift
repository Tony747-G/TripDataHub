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
    @State private var pendingFileDeleteIDs: [CrewAccessImportFile.ID] = []
    @State private var isShowingCrewAccessFileDeleteConfirm = false
    @State private var selectedCrewAccessScheduleIDs: Set<String> = []
    @State private var isShowingCrewAccessDeleteConfirm = false
    @State private var crewAccessDeleteIDs: Set<String> = []
#if os(iOS)
    @State private var editMode: EditMode = .inactive
#endif

    private static let dobFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MM/dd/yyyy"
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

    private var isDeleteSelectedDisabled: Bool {
        if selectedCrewAccessScheduleIDs.isEmpty || viewModel.isDeletingCrewAccessTrips {
            return true
        }
#if os(iOS)
        return editMode != .active
#else
        return false
#endif
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
        let updated = file.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"
        let kb = max(1, Int((Double(file.bytes) / 1024.0).rounded()))
        let timelineState = file.isOrphan ? "Orphan file" : "In Timeline"
        let fallbackLabel = file.usedFallbackDate ? " • fallback" : ""
        return "Updated: \(updated) • \(kb) KB • \(timelineState)\(fallbackLabel)"
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
                let orphanCount = fileCount - inTimelineCount
                let timelineLegsTotal = viewModel.crewAccessSchedules.reduce(0) { $0 + $1.legCount }
                Text("Files: \(fileCount) • In Timeline: \(inTimelineCount) • Orphans: \(orphanCount) • Timeline legs: \(timelineLegsTotal)")
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
                    let ids = offsets.map { crewAccessImportFiles[$0].id }
                    guard !ids.isEmpty else { return }
                    pendingFileDeleteIDs = ids
                    isShowingCrewAccessFileDeleteConfirm = true
                }
            }
        } header: {
            Text("CrewAccess Imports (Files)")
        }
    }

    @ViewBuilder
    private var crewAccessScheduleSection: some View {
        Section {
            HStack {
#if os(iOS)
                EditButton()
                    .disabled(viewModel.crewAccessSchedules.isEmpty || viewModel.isDeletingCrewAccessTrips)
#endif

                Spacer()

                Button("Delete Selected", role: .destructive) {
                    crewAccessDeleteIDs = selectedCrewAccessScheduleIDs
                    isShowingCrewAccessDeleteConfirm = true
                }
                .disabled(isDeleteSelectedDisabled)
            }

            if viewModel.crewAccessSchedules.isEmpty {
                Text("No imported CrewAccess trips.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.crewAccessSchedules) { schedule in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(schedule.label.isEmpty ? schedule.id : schedule.label)
                            .font(.subheadline.weight(.semibold))
                        Text("Trips: \(schedule.tripCount), Legs: \(schedule.legCount), Updated: \(schedule.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .tag(schedule.id)
                }
            }

            if viewModel.isDeletingCrewAccessTrips {
                ProgressView()
            }

            if let deleteMessage = viewModel.crewAccessDeleteMessage {
                Text(deleteMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("CrewAccess Imports")
        }
    }

    @ViewBuilder
    private var settingsListContent: some View {
        List(selection: $selectedCrewAccessScheduleIDs) {
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
            crewAccessScheduleSection

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
            .confirmationDialog(
                "Delete imported file?",
                isPresented: $isShowingCrewAccessFileDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let targetURLs = crewAccessImportFiles
                        .filter { pendingFileDeleteIDs.contains($0.id) }
                        .map(\.url)
                    Task {
                        await viewModel.deleteCrewAccessImportFiles(urls: targetURLs)
                        pendingFileDeleteIDs.removeAll()
                        selectedCrewAccessScheduleIDs.removeAll()
                        await loadCrewAccessImportFiles(afterDelete: true)
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingFileDeleteIDs.removeAll()
                }
            } message: {
                Text("This removes the JSON file. If it matches a CrewAccess trip in Timeline, that trip will also be removed. This cannot be undone.")
            }
            .confirmationDialog(
                "Delete imported trip(s)?",
                isPresented: $isShowingCrewAccessDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let ids = crewAccessDeleteIDs
                    Task {
                        await viewModel.deleteCrewAccessTrips(ids: ids)
                        selectedCrewAccessScheduleIDs.subtract(ids)
                        crewAccessDeleteIDs.removeAll()
                        await loadCrewAccessImportFiles(afterDelete: true)
                    }
                }
                Button("Cancel", role: .cancel) {
                    crewAccessDeleteIDs.removeAll()
                }
            } message: {
                Text("This removes the imported CrewAccess trip from Timeline. This cannot be undone.")
            }
            .alert("Notifications Are Disabled", isPresented: $showNotificationDeniedAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Open Settings") {
                    openSystemSettings()
                }
            } message: {
                Text("Enable notifications in iOS Settings to receive 48h/24h/12h reminders.")
            }
#if os(iOS)
            .environment(\.editMode, $editMode)
#endif
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
