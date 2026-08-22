import SwiftUI

/// The Green/Amber/Red dot shown to the left of an accepted friend's name.
///
/// Shared by the iPhone Friends tab and the iPad Friends management section so both render from the
/// same `FriendScheduleSyncHealth` — the colour mapping exists in exactly one place.
///
/// Distinct from the section-level "Schedule sharing" indicator at the top of the Friends screen,
/// which describes this user's own sharing state, not a friend's.
struct FriendScheduleStatusDot: View {
    let health: FriendScheduleSyncHealth

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            // The shape alone is meaningless to VoiceOver, so the dot carries the label/value and
            // the surrounding row keeps its own text.
            .accessibilityElement()
            .accessibilityLabel("Schedule sync status")
            .accessibilityValue(health.accessibilityValue)
    }

    private var color: Color {
        switch health {
        case .synchronizedWithUpcomingSchedule:
            return .green
        case .synchronizedWithoutUpcomingSchedule:
            return Color(red: 1.0, green: 0.72, blue: 0.0) // amber, distinct from the orange spinner state
        case .failed:
            return .red
        }
    }
}
