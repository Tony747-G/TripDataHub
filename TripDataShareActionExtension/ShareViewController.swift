import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    // NOTE: Must match AppGroupImportConfig in main app (AppViewModel.swift).
    private static let appGroupIdentifier = "group.com.sfune.BidProSchedule"
    private static let sharedDirectoryName = "CrewAccessSharedImports"
    private static let pendingFileName = "pending_import.json"

    private let statusLabel = UILabel()
    private var didStart = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        Task { [weak self] in
            await self?.handleShare()
        }
    }

    private func setupUI() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.text = "Importing PDF to TripData Hub..."
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func setStatus(_ text: String) async {
        await MainActor.run {
            statusLabel.text = text
        }
    }

    private func handleShare() async {
        var savedDestinationURL: URL?
        var didWritePendingHandoff = false
        do {
            guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
                  let providers = item.attachments,
                  !providers.isEmpty else {
                await setStatus("No PDF was provided.")
                await complete(after: 0.8)
                return
            }

            guard let dataResult = try await firstPDFData(from: providers) else {
                await setStatus("Selected item is not a PDF.")
                await complete(after: 1.0)
                return
            }

            let destination = try saveToAppGroup(pdfData: dataResult.data, sourceName: dataResult.sourceName)
            savedDestinationURL = destination
            try writePendingHandoff(fileName: destination.lastPathComponent)
            didWritePendingHandoff = true
            let deepLink = URL(string: "tripdatahub://import-crewaccess")!
            let didOpen = await openMainApp(url: deepLink)
            guard didOpen else {
                await setStatus("Shared successfully. Please open TripData Hub to continue.")
                await complete(after: 1.2)
                return
            }
            await setStatus("Opening TripData Hub...")
            await complete(after: 1.5)
        } catch {
            if !didWritePendingHandoff, let savedDestinationURL {
                try? FileManager.default.removeItem(at: savedDestinationURL)
            }
            await setStatus("Import failed: \(error.localizedDescription)")
            await complete(after: 1.2)
        }
    }

    @MainActor
    private func complete(after delay: TimeInterval) async {
        let nanos = UInt64(max(0, delay) * 1_000_000_000)
        if nanos > 0 {
            try? await Task.sleep(nanoseconds: nanos)
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func firstPDFData(from providers: [NSItemProvider]) async throws -> (data: Data, sourceName: String)? {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                if let result = try await loadPDFData(from: provider, typeIdentifier: UTType.pdf.identifier) {
                    return result
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let result = try await loadPDFData(from: provider, typeIdentifier: UTType.fileURL.identifier) {
                    return result
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                if let result = try await loadPDFData(from: provider, typeIdentifier: UTType.data.identifier) {
                    return result
                }
            }
        }
        return nil
    }

    private func loadPDFData(from provider: NSItemProvider, typeIdentifier: String) async throws -> (data: Data, sourceName: String)? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let url = item as? URL {
                    do {
                        let data = try Data(contentsOf: url)
                        guard Self.sniffPDF(data) else {
                            continuation.resume(returning: nil)
                            return
                        }
                        continuation.resume(returning: (data, url.lastPathComponent.isEmpty ? "Shared.pdf" : url.lastPathComponent))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                if let data = item as? Data {
                    guard Self.sniffPDF(data) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: (data, "Shared.pdf"))
                    return
                }

                if let nsData = item as? NSData {
                    let data = Data(referencing: nsData)
                    guard Self.sniffPDF(data) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: (data, "Shared.pdf"))
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }

    private func saveToAppGroup(pdfData: Data, sourceName: String) throws -> URL {
        let fm = FileManager.default
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) else {
            throw NSError(domain: "TripDataShareAction", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Group container not available."])
        }

        let directory = container.appendingPathComponent(Self.sharedDirectoryName, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let sanitizedName = sourceName.isEmpty ? "CrewAccess.pdf" : sourceName
        let uniqueName = "\(UUID().uuidString)-\(sanitizedName)"
        let destination = directory.appendingPathComponent(uniqueName)
        try pdfData.write(to: destination, options: .atomic)
        return destination
    }

    private func writePendingHandoff(fileName: String) throws {
        let fm = FileManager.default
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) else {
            throw NSError(domain: "TripDataShareAction", code: 2, userInfo: [NSLocalizedDescriptionKey: "App Group container not available."])
        }

        let directory = container.appendingPathComponent(Self.sharedDirectoryName, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let pendingURL = directory.appendingPathComponent(Self.pendingFileName)

        let payload: [String: String] = [
            "fileName": fileName,
            "createdAtISO8601": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try data.write(to: pendingURL, options: .atomic)
    }

    private func openMainApp(url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            extensionContext?.open(url) { success in
                continuation.resume(returning: success)
            }
        }
    }

    private static func sniffPDF(_ data: Data) -> Bool {
        data.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D])
    }
}
