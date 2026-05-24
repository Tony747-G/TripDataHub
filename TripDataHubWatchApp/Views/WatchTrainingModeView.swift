import SwiftUI

struct WatchTrainingModeView: View {
    let payload: TrainingPayload

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            trainingContent(now: context.date)
        }
    }

    @ViewBuilder
    private func trainingContent(now: Date) -> some View {
        let seconds = payload.startUtc.timeIntervalSince(now)
        let durationLabel = formatDuration(abs(seconds))
        let statusLabel = seconds > 0 ? "Starts in" : "In progress"

        VStack(spacing: 4) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(.cyan)

            Text(payload.eventName)
                .font(.title2.weight(.bold))
                .foregroundStyle(.cyan)

            Text(statusLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)

            WatchClockText(text: durationLabel, accent: .primary, style: .title)

            Divider()
                .padding(.vertical, 2)

            HStack {
                Text(payload.startLdtFormatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(payload.dateLabelFormatted)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}
