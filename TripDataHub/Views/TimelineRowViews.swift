import SwiftUI

/// Shared flight row used by TimelineTabView and ScheduleTimelineRendererView.
///
/// All computed values (timeRangeText, dayDiff, blockText) are pre-computed by the caller,
/// keeping UTC/LCL logic and friend-match state entirely in the owning view.
/// `iconColor` defaults to `.primary`; pass `friendMatchAmber` for friend highlights.
/// `onIconTap` is nil in ScheduleTimelineRendererView (Friends Timeline, no tap needed).
struct TimelineFlightRow: View {
    let leg: TripLeg
    let isPast: Bool
    let fontScale: CGFloat
    let timeRangeText: String
    let dayDiff: Int
    let blockText: String
    var iconColor: Color = .primary
    var onIconTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            let resolvedIconColor: Color = isPast ? .gray : iconColor
            let icon = MaterialIconView(
                codePoint: TimelineLegIconSupport.codePoint(for: leg.status),
                size: 20 * fontScale,
                color: resolvedIconColor,
                fallbackSystemName: TimelineLegIconSupport.fallbackSystemName(for: leg.status)
            )
            .frame(width: 28 * fontScale, alignment: .center)

            if let tap = onIconTap {
                Button(action: tap) { icon }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Friend on same flight")
            } else {
                icon
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("\(leg.depAirport) - \(leg.arrAirport)")
                        .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                    Spacer()
                    HStack(spacing: 0) {
                        Text(timeRangeText)
                            .foregroundStyle(isPast ? .gray : .primary)
                        Text(timelineDiffLabel(dayDiff))
                            .foregroundStyle(isPast ? .gray : (dayDiff == 0 ? .primary : .red))
                    }
                    .appScaledFont(.subheadline, scale: fontScale)
                }
                HStack {
                    Text(leg.displayFlightNumberText)
                        .appScaledFont(.footnote, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                    Spacer()
                    Text(blockText)
                        .appScaledFont(.caption, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

/// Shared layover card used by TimelineTabView and ScheduleTimelineRendererView.
///
/// Hotel name, duration, and arrival date label are pre-computed by the caller.
/// `iconColor` defaults to `.primary`; pass `friendMatchAmber` for rest-overlap highlights.
/// `onIconTap` is nil in ScheduleTimelineRendererView (Friends Timeline, no tap needed).
struct TimelineLayoverCard: View {
    let station: String
    let hotel: String
    let durationText: String
    let remainingText: String
    let arrLocalDateLabel: String
    let isPast: Bool
    let fontScale: CGFloat
    var iconColor: Color = .primary
    var onIconTap: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var dateHeaderTextColor: Color {
        ScheduleColors.timelineDateHeaderText(for: colorScheme)
    }

    private var dateCardBackground: Color {
        ScheduleColors.dayHeaderBackground(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !arrLocalDateLabel.isEmpty {
                Text(arrLocalDateLabel)
                    .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                    .foregroundStyle(isPast ? .gray : dateHeaderTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .background(dateCardBackground)
            }

            HStack(alignment: .center, spacing: 12) {
                let resolvedIconColor: Color = isPast ? .gray : iconColor
                let bedIcon = Image(systemName: "bed.double.fill")
                    .font(.system(size: 16 * fontScale))
                    .foregroundStyle(resolvedIconColor)
                    .frame(width: 28 * fontScale, alignment: .center)

                if let tap = onIconTap {
                    Button(action: tap) { bedIcon }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Friend layover overlap")
                } else {
                    bedIcon
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Layover at \(station)")
                            .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                            .foregroundStyle(isPast ? .gray : iconColor)
                        Spacer()
                        if !durationText.isEmpty {
                            Text("Rest: \(durationText)")
                                .appScaledFont(.caption, scale: fontScale)
                                .foregroundStyle(isPast ? .gray : .primary)
                        }
                    }
                    HStack {
                        if !hotel.isEmpty {
                            Text(hotel)
                                .appScaledFont(.footnote, scale: fontScale)
                                .foregroundStyle(isPast ? .gray : .secondary)
                        }
                        Spacer()
                        if !remainingText.isEmpty {
                            Text("Remain: \(remainingText)")
                                .appScaledFont(.caption, scale: fontScale)
                                .foregroundStyle(isPast ? .gray : .primary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
    }
}
