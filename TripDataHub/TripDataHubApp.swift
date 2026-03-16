import SwiftUI

enum ExternalOpenLaunchGate {
    private static let lock = NSLock()
    private static var recentKeys: [String: Date] = [:]
    private static let dedupTTL: TimeInterval = 5

    /// TTL is intentionally short (5s): iOS delivers the same share action as 2-3 rapid
    /// `onOpenURL` calls within milliseconds. 5s catches those duplicates while allowing
    /// the user to deliberately re-share the same PDF immediately after confirm/discard.
    static func shouldForward(url: URL) -> Bool {
        let key = stableKey(for: url)
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        recentKeys = recentKeys.filter { now.timeIntervalSince($0.value) < dedupTTL }
        if recentKeys[key] != nil {
            return false
        }
        recentKeys[key] = now
        return true
    }

    /// Call after an import is confirmed or discarded so the same file can be
    /// re-shared immediately without waiting for the TTL to expire.
    /// Any entries that were dropped as duplicates during the TTL window are intentionally
    /// discarded and will not be re-surfaced — the user must re-share the file if needed.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        recentKeys.removeAll()
    }

    static func stableKey(for url: URL) -> String {
        // Key on file content identity (size + mtime) rather than path, so that iOS delivering
        // the same PDF via different paths (tmp original vs Inbox copy) maps to the same key.
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        if let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path),
           let size = (attrs[.size] as? NSNumber)?.int64Value,
           let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 {
            return "size:\(size)|mtime:\(Int64(modified))"
        }
        return resolvedURL.absoluteString
    }
}

@main
struct TripDataHubApp: App {
    private let viewModel = AppViewModel.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(viewModel)
                .onOpenURL { url in
                    NSLog("[Import] app.onOpenURL received url=%@", url.absoluteString)
                    if url.isFileURL {
                        if ExternalOpenLaunchGate.shouldForward(url: url) {
                            viewModel.queueExternalOpenURL(url)
                        } else {
                            NSLog("[Import] app.onOpenURL skipped (duplicate) url=%@", url.absoluteString)
                        }
                    } else {
                        viewModel.handleIncomingAppDeepLink(url)
                    }
                }
        }
    }
}
