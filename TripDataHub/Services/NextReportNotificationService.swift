import Foundation
import UserNotifications
#if DEBUG
import os
#endif

struct NotificationRescheduleResult {
    let requested: Int
    let scheduled: Int
    let failed: Int
}

protocol NextReportNotificationServiceProtocol {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func invalidateNextReportNotifications() async
    func reschedule(
        schedules: [PayPeriodSchedule],
        notify48h: Bool,
        notify24h: Bool,
        notify12h: Bool
    ) async -> NotificationRescheduleResult
}

#if DEBUG
/// DEBUG-only entry points that attach an origin to otherwise unchanged notification operations.
/// The production protocol remains unchanged so diagnostics cannot become a Release dependency.
protocol NextReportNotificationDiagnosticScheduling {
    func invalidateNextReportNotifications(diagnosticOrigin: String) async
    func reschedule(
        schedules: [PayPeriodSchedule],
        notify48h: Bool,
        notify24h: Bool,
        notify12h: Bool,
        diagnosticOrigin: String
    ) async -> NotificationRescheduleResult
}
#endif

final class NextReportNotificationService: NextReportNotificationServiceProtocol {
    private let center: UNUserNotificationCenter
    private let requestPrefix = "nextreport."
#if DEBUG
    private let diagnosticLogger = Logger(
        subsystem: "com.sfune.TripDataHub",
        category: "NextReportNotificationDiag"
    )
#endif

    private var selectedCrewDomicile: CrewBase {
        OperationalSettings.selectedCrewBase()
    }

    private var selectedDomicileTimeZone: TimeZone {
        selectedCrewDomicile.timeZone
    }

    private func reportFormatter(for timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, MMM d yyyy HH:mm"
        return formatter
    }

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

    func invalidateNextReportNotifications() async {
        await invalidateNextReportNotifications(
            diagnosticOrigin: "protocol-invalidation",
            diagnosticRunID: nil
        )
    }

    private func invalidateNextReportNotifications(
        diagnosticOrigin: String,
        diagnosticRunID: String?
    ) async {
        let pendingIDs = await pendingRequestIDsWithPrefix()
        let deliveredIDs = await deliveredRequestIDsWithPrefix()
#if DEBUG
        let runID = diagnosticRunID ?? UUID().uuidString
        diagnosticLogger.info(
            "[NextReportNotificationDiag] event=pre-removal runID=\(runID, privacy: .public) origin=\(diagnosticOrigin, privacy: .public) pending=\(Self.diagnosticIdentifierList(pendingIDs), privacy: .public) delivered=\(Self.diagnosticIdentifierList(deliveredIDs), privacy: .public) removePending=\(Self.diagnosticIdentifierList(pendingIDs), privacy: .public) removeDelivered=\(Self.diagnosticIdentifierList(deliveredIDs), privacy: .public)"
        )
#endif
        if !pendingIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        }
        if !deliveredIDs.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        }
    }

    func reschedule(
        schedules: [PayPeriodSchedule],
        notify48h: Bool,
        notify24h: Bool,
        notify12h: Bool
    ) async -> NotificationRescheduleResult {
        await performReschedule(
            schedules: schedules,
            notify48h: notify48h,
            notify24h: notify24h,
            notify12h: notify12h,
            diagnosticOrigin: "protocol-reschedule"
        )
    }

    private func performReschedule(
        schedules: [PayPeriodSchedule],
        notify48h: Bool,
        notify24h: Bool,
        notify12h: Bool,
        diagnosticOrigin: String
    ) async -> NotificationRescheduleResult {
#if DEBUG
        let diagnosticRunID = UUID().uuidString
        let diagnosticStartedAt = Date()
        diagnosticLogger.info(
            "[NextReportNotificationDiag] event=run-start runID=\(diagnosticRunID, privacy: .public) origin=\(diagnosticOrigin, privacy: .public) now=\(Self.diagnosticDate(diagnosticStartedAt), privacy: .public) notify48h=\(notify48h, privacy: .public) notify24h=\(notify24h, privacy: .public)"
        )
#else
        let diagnosticRunID: String? = nil
#endif
        let enabledThresholds = enabledOffsets(notify48h: notify48h, notify24h: notify24h, notify12h: notify12h)
        await invalidateNextReportNotifications(
            diagnosticOrigin: diagnosticOrigin,
            diagnosticRunID: diagnosticRunID
        )

        guard !enabledThresholds.isEmpty else {
#if DEBUG
            await logRunCompletion(
                runID: diagnosticRunID,
                origin: diagnosticOrigin,
                requested: 0,
                scheduled: 0,
                failed: 0,
                reason: "no-enabled-offsets"
            )
#endif
            return NotificationRescheduleResult(requested: 0, scheduled: 0, failed: 0)
        }

        let now = Date()
#if DEBUG
        diagnosticLogger.info(
            "[NextReportNotificationDiag] event=scheduling-now runID=\(diagnosticRunID, privacy: .public) origin=\(diagnosticOrigin, privacy: .public) now=\(Self.diagnosticDate(now), privacy: .public)"
        )
#endif
        let crewDomicile = selectedCrewDomicile
        let domicileTimeZone = selectedDomicileTimeZone
        let windows = NextReportWindowBuilder.build(
            schedules: schedules,
            domicileAirportCode: crewDomicile.reportAirportCode,
            domicileTimeZone: domicileTimeZone
        )
        var requested = 0
        var scheduled = 0
        var failed = 0
        var seenDedupKeys = Set<String>()

        for window in windows {
            for (label, secondsBeforeReport) in enabledThresholds {
                let fireDate = window.reportTime.addingTimeInterval(-secondsBeforeReport)
                let identifier = "\(requestPrefix)\(window.pairing).\(Int(window.reportTime.timeIntervalSince1970)).\(label)"
                let secondsRemaining = fireDate.timeIntervalSince(now)
                guard fireDate > now else {
#if DEBUG
                    diagnosticLogger.info(
                        "[NextReportNotificationDiag] event=offset-decision runID=\(diagnosticRunID, privacy: .public) origin=\(diagnosticOrigin, privacy: .public) tripID=\(window.pairing, privacy: .public) reportTime=\(Self.diagnosticDate(window.reportTime), privacy: .public) notify48h=\(notify48h, privacy: .public) notify24h=\(notify24h, privacy: .public) offset=\(label, privacy: .public) fireDate=\(Self.diagnosticDate(fireDate), privacy: .public) secondsRemaining=\(secondsRemaining, privacy: .public) identifier=\(identifier, privacy: .public) decision=skipped reason=fire-date-not-future"
                    )
#endif
                    continue
                }

                let dedupKey = "\(window.pairing)|\(Int(window.reportTime.timeIntervalSince1970))|\(label)"
                guard seenDedupKeys.insert(dedupKey).inserted else {
#if DEBUG
                    diagnosticLogger.info(
                        "[NextReportNotificationDiag] event=offset-decision runID=\(diagnosticRunID, privacy: .public) origin=\(diagnosticOrigin, privacy: .public) tripID=\(window.pairing, privacy: .public) reportTime=\(Self.diagnosticDate(window.reportTime), privacy: .public) notify48h=\(notify48h, privacy: .public) notify24h=\(notify24h, privacy: .public) offset=\(label, privacy: .public) fireDate=\(Self.diagnosticDate(fireDate), privacy: .public) secondsRemaining=\(secondsRemaining, privacy: .public) identifier=\(identifier, privacy: .public) decision=skipped reason=duplicate"
                    )
#endif
                    continue
                }
                requested += 1
#if DEBUG
                diagnosticLogger.info(
                    "[NextReportNotificationDiag] event=offset-decision runID=\(diagnosticRunID, privacy: .public) origin=\(diagnosticOrigin, privacy: .public) tripID=\(window.pairing, privacy: .public) reportTime=\(Self.diagnosticDate(window.reportTime), privacy: .public) notify48h=\(notify48h, privacy: .public) notify24h=\(notify24h, privacy: .public) offset=\(label, privacy: .public) fireDate=\(Self.diagnosticDate(fireDate), privacy: .public) secondsRemaining=\(secondsRemaining, privacy: .public) identifier=\(identifier, privacy: .public) decision=schedule reason=eligible"
                )
#endif

                let content = UNMutableNotificationContent()
                content.title = "Next Report Reminder"
                content.body = "Trip \(window.pairing): report \(formatReportTime(window.reportTime, timeZone: domicileTimeZone)) \(crewDomicile.displayName)"
                content.sound = .default
                content.threadIdentifier = "nextreport"

                // This is an absolute instant. Passing `dateComponents(in:)` wholesale to a
                // calendar trigger also includes fields such as weekday/week-of-year and can make
                // an otherwise valid one-shot date impossible to match. A relative trigger keeps
                // the already-computed UTC instant authoritative.
                let trigger = Self.notificationTrigger(fireDate: fireDate, now: now)
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                do {
                    try await center.add(request)
                    scheduled += 1
#if DEBUG
                    diagnosticLogger.info(
                        "[NextReportNotificationDiag] event=add-result runID=\(diagnosticRunID, privacy: .public) origin=\(diagnosticOrigin, privacy: .public) offset=\(label, privacy: .public) identifier=\(identifier, privacy: .public) result=success"
                    )
                    let pendingAfterAdd = await pendingRequestIDsWithPrefix()
                    diagnosticLogger.info(
                        "[NextReportNotificationDiag] event=post-add-pending runID=\(diagnosticRunID, privacy: .public) origin=\(diagnosticOrigin, privacy: .public) offset=\(label, privacy: .public) identifier=\(identifier, privacy: .public) identifierPresent=\(pendingAfterAdd.contains(identifier), privacy: .public) pending=\(Self.diagnosticIdentifierList(pendingAfterAdd), privacy: .public)"
                    )
#endif
                } catch {
                    failed += 1
#if DEBUG
                    let nsError = error as NSError
                    diagnosticLogger.error(
                        "[NextReportNotificationDiag] event=add-result runID=\(diagnosticRunID, privacy: .public) origin=\(diagnosticOrigin, privacy: .public) offset=\(label, privacy: .public) identifier=\(identifier, privacy: .public) result=failure errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) errorDescription=\(String(describing: nsError), privacy: .public)"
                    )
#endif
                }
            }
        }

#if DEBUG
        await logRunCompletion(
            runID: diagnosticRunID,
            origin: diagnosticOrigin,
            requested: requested,
            scheduled: scheduled,
            failed: failed,
            reason: "completed"
        )
#endif
        return NotificationRescheduleResult(requested: requested, scheduled: scheduled, failed: failed)
    }

    private func enabledOffsets(notify48h: Bool, notify24h: Bool, notify12h: Bool) -> [(String, TimeInterval)] {
        var values: [(String, TimeInterval)] = []
        if notify48h { values.append(("48h", 48 * 3600)) }
        if notify24h { values.append(("24h", 24 * 3600)) }
        if notify12h { values.append(("12h", 12 * 3600)) }
        return values
    }

    static func notificationTrigger(fireDate: Date, now: Date) -> UNTimeIntervalNotificationTrigger {
        UNTimeIntervalNotificationTrigger(
            timeInterval: fireDate.timeIntervalSince(now),
            repeats: false
        )
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

    private func deliveredRequestIDsWithPrefix() async -> [String] {
        let prefix = requestPrefix
        return await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                let ids = notifications
                    .map { $0.request.identifier }
                    .filter { $0.hasPrefix(prefix) }
                continuation.resume(returning: ids)
            }
        }
    }

#if DEBUG
    private func logRunCompletion(
        runID: String,
        origin: String,
        requested: Int,
        scheduled: Int,
        failed: Int,
        reason: String
    ) async {
        let finalPending = await pendingRequestIDsWithPrefix()
        diagnosticLogger.info(
            "[NextReportNotificationDiag] event=run-complete runID=\(runID, privacy: .public) origin=\(origin, privacy: .public) reason=\(reason, privacy: .public) requested=\(requested, privacy: .public) scheduled=\(scheduled, privacy: .public) failed=\(failed, privacy: .public) finalPending=\(Self.diagnosticIdentifierList(finalPending), privacy: .public)"
        )
    }

    private static func diagnosticDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func diagnosticIdentifierList(_ identifiers: [String]) -> String {
        "[\(identifiers.sorted().joined(separator: ","))]"
    }
#endif

    private func formatReportTime(_ date: Date, timeZone: TimeZone) -> String {
        reportFormatter(for: timeZone).string(from: date)
    }
}

#if DEBUG
extension NextReportNotificationService: NextReportNotificationDiagnosticScheduling {
    func invalidateNextReportNotifications(diagnosticOrigin: String) async {
        await invalidateNextReportNotifications(
            diagnosticOrigin: diagnosticOrigin,
            diagnosticRunID: nil
        )
    }

    func reschedule(
        schedules: [PayPeriodSchedule],
        notify48h: Bool,
        notify24h: Bool,
        notify12h: Bool,
        diagnosticOrigin: String
    ) async -> NotificationRescheduleResult {
        await performReschedule(
            schedules: schedules,
            notify48h: notify48h,
            notify24h: notify24h,
            notify12h: notify12h,
            diagnosticOrigin: diagnosticOrigin
        )
    }
}
#endif
