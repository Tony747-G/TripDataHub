import SwiftUI

struct WatchClockText: View {
    let text: String
    var accent: Color = .primary
    var style: Font = .title3

    var body: some View {
        Text(text)
            .font(style.monospacedDigit())
            .fontWeight(.semibold)
            .foregroundStyle(accent)
    }
}
