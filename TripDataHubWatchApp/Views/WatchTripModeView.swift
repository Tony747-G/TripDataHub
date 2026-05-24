import SwiftUI

struct WatchTripModeView: View {
    let payload: TripPayload

    var body: some View {
        TabView {
            TripPrimaryCard(payload: payload)
            TripLegDetailCard(payload: payload)
            TripTimePackCard(payload: payload)
        }
        .tabViewStyle(.page)
    }
}

// MARK: - Primary Card (live clocks)

private struct TripPrimaryCard: View {
    let payload: TripPayload

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let now = ctx.date
            VStack(alignment: .leading, spacing: 5) {
                tripClockRow(label: "UTC",          time: tripFormatHHmm(now, tzID: "UTC"),                               accent: .green)
                tripClockRow(label: payload.depIata, time: tripFormatHHmm(now, tzID: payload.depTimeZoneIdentifier))
                tripClockRow(label: payload.arrIata, time: tripFormatHHmm(now, tzID: payload.arrTimeZoneIdentifier))

                Spacer(minLength: 4)

                HStack(alignment: .firstTextBaseline) {
                    Text("\(payload.depIata) → \(payload.arrIata)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Before report, count to Report. Once the trip has started,
                    // count to the next flight departure.
                    let isPreReport = payload.reportUtc.map { now < $0 } ?? false
                    let countdownTarget = isPreReport ? (payload.reportUtc ?? payload.depUtc) : payload.depUtc
                    let countdown = tripCountdownLabel(target: countdownTarget, now: now)
                    Text(isPreReport ? "Report \(countdown)" : countdown)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Card 1: Leg Detail (UTC times + block)

private struct TripLegDetailCard: View {
    let payload: TripPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(payload.depIata) → \(payload.arrIata)")
                .font(.headline)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dep UTC")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    WatchClockText(text: tripFormatHHmm(payload.depUtc, tzID: "UTC"),
                                   accent: .primary, style: .title3)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Arr UTC")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    WatchClockText(text: tripFormatHHmm(payload.arrUtc, tzID: "UTC"),
                                   accent: .primary, style: .title3)
                }
            }

            Divider()

            HStack {
                Text("Block")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(tripBlockLabel(dep: payload.depUtc, arr: payload.arrUtc))
                    .font(.caption.monospacedDigit().weight(.medium))
            }
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - Card 2: Time Pack (local times)

private struct TripTimePackCard: View {
    let payload: TripPayload

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(payload.depIata)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    WatchClockText(text: tripFormatHHmm(payload.depUtc, tzID: payload.depTimeZoneIdentifier),
                                   accent: .primary, style: .title3)
                    Text("LT Dep")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(payload.arrIata)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    WatchClockText(text: tripFormatHHmm(payload.arrUtc, tzID: payload.arrTimeZoneIdentifier),
                                   accent: .primary, style: .title3)
                    Text("LT Arr")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Text("Block")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(tripBlockLabel(dep: payload.depUtc, arr: payload.arrUtc))
                    .font(.caption.monospacedDigit().weight(.medium))
            }
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - File-scope helpers

private func tripFormatHHmm(_ date: Date, tzID: String) -> String {
    guard let tz = TimeZone(identifier: tzID) else { return "--:--" }
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = tz
    return f.string(from: date)
}

private func tripCountdownLabel(target: Date, now: Date) -> String {
    let delta = target.timeIntervalSince(now)
    let prefix = delta >= 0 ? "T-" : "T+"
    let totalMinutes = Int(abs(delta)) / 60
    return String(format: "\(prefix)%02d:%02d", totalMinutes / 60, totalMinutes % 60)
}

private func tripBlockLabel(dep: Date, arr: Date) -> String {
    let minutes = max(0, Int(arr.timeIntervalSince(dep)) / 60)
    return String(format: "%d:%02d", minutes / 60, minutes % 60)
}

private func tripClockRow(label: String, time: String, accent: Color = .primary) -> some View {
    HStack {
        Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 32, alignment: .leading)
        Spacer()
        WatchClockText(text: time, accent: accent)
    }
}
