import SwiftUI
import UIKit
import os
import UserNotifications

private let logger = Logger(subsystem: "com.sfune.TripDataHub", category: "AppLifecycle")

enum ExternalOpenLaunchGate {
    private static let lock = NSLock()
    private static var recentKeys: [String: Date] = [:]
    private static let dedupTTL: TimeInterval = 5

    /// TTL is intentionally short (5s): iOS delivers the same share action as 2-3 rapid
    /// `onOpenURL` calls within milliseconds. Content identity is handled later by the shared
    /// fingerprint ledger; this gate is only a cheap delivery-burst filter.
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

    static func stableKey(for url: URL) -> String {
        // Key this Layer 1 delivery signature on size + mtime rather than path, so rapid iOS
        // copies usually coalesce. The downstream SHA-256 ledger remains authoritative.
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
    private let notificationDelegate = NotificationForegroundDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(viewModel)
                .onOpenURL { url in
                    logger.info("[Import] app.onOpenURL received url=\(url.absoluteString, privacy: .private)")
                    if url.isFileURL {
                        if ExternalOpenLaunchGate.shouldForward(url: url) {
                            viewModel.queueExternalOpenURL(url)
                        } else {
                            logger.info("[Import] app.onOpenURL skipped (duplicate) url=\(url.absoluteString, privacy: .private)")
                        }
                    } else {
                        viewModel.handleIncomingAppDeepLink(url)
                    }
                }
        }
    }
}

private final class NotificationForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

private struct AppRootView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                IPadOperationalWorkspaceView()
            } else {
                RootTabView()
            }
        }
        .task {
            await viewModel.prepareFlightCountdownPresentationForLaunch()
        }
    }
}
