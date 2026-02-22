import Foundation
import UserNotifications

struct NotificationRescheduleResult {
    let requested: Int
    let scheduled: Int
    let failed: Int
}

protocol NextReportNotificationServiceProtocol {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func reschedule(
        schedules: [PayPeriodSchedule],
        notify48h: Bool,
        notify24h: Bool,
        notify12h: Bool
    ) async -> NotificationRescheduleResult
}

final class NextReportNotificationService: NextReportNotificationServiceProtocol {
    private let center: UNUserNotificationCenter
    private let ancTimeZone = TimeZone(identifier: "America/Anchorage")
        ?? TimeZone(secondsFromGMT: NextReportWindowBuilder.anchorageFallbackOffsetSeconds)!
    private let requestPrefix = "nextreport."
    private let reportFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(identifier: "America/Anchorage")
            ?? TimeZone(secondsFromGMT: NextReportWindowBuilder.anchorageFallbackOffsetSeconds)!
        formatter.dateFormat = "EEE, MMM d yyyy HH:mm"
        return formatter
    }()

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func reschedule(
        schedules: [PayPeriodSchedule],
        notify48h: Bool,
        notify24h: Bool,
        notify12h: Bool
    ) async -> NotificationRescheduleResult {
        let enabledThresholds = enabledOffsets(notify48h: notify48h, notify24h: notify24h, notify12h: notify12h)
        let existingIDs = await pendingRequestIDsWithPrefix()

        if !existingIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: existingIDs)
            center.removeDeliveredNotifications(withIdentifiers: existingIDs)
        }

        guard !enabledThresholds.isEmpty else {
            return NotificationRescheduleResult(requested: 0, scheduled: 0, failed: 0)
        }

        let now = Date()
        let windows = NextReportWindowBuilder.build(schedules: schedules, anchorageTimeZone: ancTimeZone)
        var requested = 0
        var scheduled = 0
        var failed = 0

        for window in windows {
            for (label, secondsBeforeReport) in enabledThresholds {
                let fireDate = window.reportTime.addingTimeInterval(-secondsBeforeReport)
                guard fireDate > now else { continue }
                requested += 1

                let content = UNMutableNotificationContent()
                content.title = "Next Report Reminder"
                content.body = "Trip \(window.pairing): report \(formatReportTime(window.reportTime)) ANC"
                content.sound = .default
                content.threadIdentifier = "nextreport"

                let triggerDate = Calendar(identifier: .gregorian).dateComponents(
                    in: ancTimeZone,
                    from: fireDate
                )

                let trigger = UNCalendarNotificationTrigger(dateMatching: triggerDate, repeats: false)
                let identifier = "\(requestPrefix)\(window.key).\(label)"
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                do {
                    try await center.add(request)
                    scheduled += 1
                } catch {
                    failed += 1
                }
            }
        }

        return NotificationRescheduleResult(requested: requested, scheduled: scheduled, failed: failed)
    }

    private func enabledOffsets(notify48h: Bool, notify24h: Bool, notify12h: Bool) -> [(String, TimeInterval)] {
        var values: [(String, TimeInterval)] = []
        if notify48h { values.append(("48h", 48 * 3600)) }
        if notify24h { values.append(("24h", 24 * 3600)) }
        if notify12h { values.append(("12h", 12 * 3600)) }
        return values
    }

    private func pendingRequestIDsWithPrefix() async -> [String] {
        let prefix = requestPrefix
        return await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                let ids = requests
                    .map(\.identifier)
                    .filter { $0.hasPrefix(prefix) }
                continuation.resume(returning: ids)
            }
        }
    }

    private func formatReportTime(_ date: Date) -> String {
        reportFormatter.string(from: date)
    }
}
