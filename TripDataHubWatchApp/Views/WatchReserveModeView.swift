import SwiftUI

struct WatchReserveModeView: View {
    let payload: ReservePayload

    var body: some View {
        TabView {
            ReservePrimaryCard(payload: payload)
            ReserveWindowDetailCard(payload: payload)
        }
        .tabViewStyle(.page)
    }
}

// MARK: - Primary Card (live LDT + ring)

private struct ReservePrimaryCard: View {
    let payload: ReservePayload

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let now = ctx.date
            VStack(spacing: 6) {
                ZStack {
                    WatchProgressRing(progress: rsvRingProgress(payload: payload, now: now),
                                      accent: .orange)
                        .frame(width: 90, height: 90)

                    VStack(spacing: 1) {
                        Text("\(payload.domicile) · LDT")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        WatchClockText(text: rsvFormatHHmm(now, tzID: payload.ldtTimeZoneIdentifier),
                                       accent: .orange, style: .title2)
                    }
                }

                VStack(spacing: 2) {
                    Text(payload.reserveType)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                    Text("Remaining")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    WatchClockText(text: rsvRemainingLabel(endUtc: payload.windowEndUtc, now: now),
                                   accent: .primary)
                }
            }
        }
    }
}

// MARK: - Card 1: Window Detail

private struct ReserveWindowDetailCard: View {
    let payload: ReservePayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(payload.reserveType)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.orange)

            Divider()

            Text("Start")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(rsvFormatHHmm(payload.windowStartUtc, tzID: payload.ldtTimeZoneIdentifier) + " LDT")
                .font(.body.monospacedDigit())

            Text("End")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text(rsvFormatHHmm(payload.windowEndUtc, tzID: payload.ldtTimeZoneIdentifier) + " LDT")
                .font(.body.monospacedDigit())

            Divider()

            HStack {
                Text("Total")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(rsvDurationLabel(start: payload.windowStartUtc, end: payload.windowEndUtc))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - File-scope helpers

private func rsvFormatHHmm(_ date: Date, tzID: String) -> String {
    guard let tz = TimeZone(identifier: tzID) else { return "--:--" }
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = tz
    return f.string(from: date)
}

private func rsvRingProgress(payload: ReservePayload, now: Date) -> Double {
    let total = payload.windowEndUtc.timeIntervalSince(payload.windowStartUtc)
    guard total > 0 else { return 1 }
    let elapsed = now.timeIntervalSince(payload.windowStartUtc)
    return 1 - max(0, min(1, elapsed / total))
}

private func rsvRemainingLabel(endUtc: Date, now: Date) -> String {
    let seconds = endUtc.timeIntervalSince(now)
    guard seconds > 0 else { return "00:00" }
    let totalMinutes = Int(seconds) / 60
    return String(format: "%02d:%02d", totalMinutes / 60, totalMinutes % 60)
}

private func rsvDurationLabel(start: Date, end: Date) -> String {
    let minutes = max(0, Int(end.timeIntervalSince(start)) / 60)
    return String(format: "%dh %02dm", minutes / 60, minutes % 60)
}
