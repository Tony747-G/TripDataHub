import SwiftUI

struct WatchOffDutyModeView: View {
    let payload: OffDutyPayload

    var body: some View {
        TabView {
            OffDutyPrimaryCard(payload: payload)
            OffDutyTimePackCard(payload: payload)
        }
        .tabViewStyle(.page)
    }
}

// MARK: - Primary Card (countdown)

private struct OffDutyPrimaryCard: View {
    let payload: OffDutyPayload

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let seconds = payload.nextDutyStartUtc.timeIntervalSince(ctx.date)
            VStack(alignment: .leading, spacing: 3) {
                Text("Next Duty")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(payload.dateLabelFormatted)
                    .font(.title2.weight(.bold))

                Text("\(payload.dayOfWeekFormatted) · \(payload.nextDutyType)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 2)

                Text(payload.dutyTimeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                WatchClockText(text: payload.reportLdtFormatted, accent: .primary, style: .headline)

                Divider().padding(.vertical, 2)

                HStack(alignment: .firstTextBaseline) {
                    Text("In")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    WatchClockText(text: odFormatCountdown(seconds), accent: .gray, style: .title3)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Card 1: Time Pack (UTC duty time)

private struct OffDutyTimePackCard: View {
    let payload: OffDutyPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(payload.dutyTimeLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(payload.reportLdtFormatted)
                .font(.title3.monospacedDigit().weight(.semibold))

            Text(odFormatUTC(payload.nextDutyStartUtc))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Divider()

            Text("\(payload.dateLabelFormatted) · \(payload.dayOfWeekFormatted)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(payload.nextDutyType)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - File-scope helpers

private func odFormatCountdown(_ seconds: TimeInterval) -> String {
    guard seconds > 0 else { return "Now" }
    let totalMinutes = Int(seconds) / 60
    let h = totalMinutes / 60
    let d = h / 24
    if d > 0 { return "\(d)d \(h % 24)h" }
    return "\(h)h \(totalMinutes % 60)m"
}

private func odFormatUTC(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm 'UTC'"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: date)
}
