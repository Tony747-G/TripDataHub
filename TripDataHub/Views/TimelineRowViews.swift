import SwiftUI

struct FriendMatchPerson: Identifiable, Hashable {
    let id: String
    let displayName: String
    let subtitle: String
    let avatarImageData: Data?
}

struct FriendMatchPresentation: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let friends: [FriendMatchPerson]
}

struct FriendMatchPresentationView: View {
    let presentation: FriendMatchPresentation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(presentation.friends) { friend in
                ProfileCard(
                    avatarImageData: friend.avatarImageData ?? Data(),
                    displayName: friend.displayName,
                    subtitle: friend.subtitle,
                    avatarSize: 44
                )
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(presentation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Shared flight row used by TimelineTabView and ScheduleTimelineRendererView.
///
/// All computed values (timeRangeText, dayDiff, blockText) are pre-computed by the caller,
/// keeping UTC/LCL logic and friend-match state entirely in the owning view.
/// `iconColor` defaults to `.primary`; pass `friendMatchAmber` for friend highlights.
/// `onFriendMatchTap` is nil in ScheduleTimelineRendererView (Friends Timeline, no tap needed).
struct TimelineFlightRow: View {
    let leg: TripLeg
    let isPast: Bool
    let fontScale: CGFloat
    let timeRangeText: String
    let dayDiff: Int
    let blockText: String
    var iconColor: Color = .primary
    var onFriendMatchTap: (() -> Void)? = nil

    var body: some View {
        if let tap = onFriendMatchTap {
            rowContent
                .contentShape(Rectangle())
                .onTapGesture(perform: tap)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows friends on this flight")
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 12) {
            let resolvedIconColor: Color = isPast ? .gray : iconColor
            MaterialIconView(
                codePoint: TimelineLegIconSupport.codePoint(for: leg.status),
                size: 20 * fontScale,
                color: resolvedIconColor,
                fallbackSystemName: TimelineLegIconSupport.fallbackSystemName(for: leg.status)
            )
            .frame(width: 28 * fontScale, alignment: .center)

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

struct TimelineManualOperationalRow: View {
    let event: ManualOperationalEvent
    let isPast: Bool
    let fontScale: CGFloat
    let timeRangeText: String
    let dayDiff: Int

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 17 * fontScale, weight: .semibold))
                .foregroundStyle(iconForegroundColor)
                .frame(width: 28 * fontScale, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(event.code.rawValue)
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
                    Text(event.crewBase.displayName)
                        .appScaledFont(.footnote, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                    Spacer()
                    Text("Operational")
                        .appScaledFont(.caption, scale: fontScale)
                        .foregroundStyle(isPast ? .gray : .primary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var iconName: String {
        switch event.code {
        case .reserveA, .reserveB, .reserveC, .reserveD:
            return "phone.fill"
        case .lco, .rcid:
            return "phone.fill"
        case .hot:
            return "flame.fill"
        case .cq12, .cq6:
            return "display"
        }
    }

    private var iconForegroundColor: Color {
        if isPast { return .gray }
        switch event.code {
        case .hot:
            return Color.accentColor
        case .reserveA, .reserveB, .reserveC, .reserveD, .lco, .rcid, .cq12, .cq6:
            return .primary
        }
    }
}

/// Shared layover card used by TimelineTabView and ScheduleTimelineRendererView.
///
/// Hotel name, duration, and arrival date label are pre-computed by the caller.
/// `iconColor` defaults to `.primary`; pass `friendMatchAmber` for rest-overlap highlights.
/// `onFriendMatchTap` is nil in ScheduleTimelineRendererView (Friends Timeline, no tap needed).
struct TimelineLayoverCard: View {
    let station: String
    let hotel: String
    let durationText: String
    let remainingText: String
    let arrLocalDateLabel: String
    let isPast: Bool
    let fontScale: CGFloat
    var iconColor: Color = .primary
    var onFriendMatchTap: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var dateHeaderTextColor: Color {
        ScheduleColors.timelineDateHeaderText(for: colorScheme)
    }

    private var dateCardBackground: Color {
        ScheduleColors.dayHeaderBackground(for: colorScheme)
    }

    var body: some View {
        if let tap = onFriendMatchTap {
            cardContent
                .contentShape(Rectangle())
                .onTapGesture(perform: tap)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows friends with overlapping layover")
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
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
                Image(systemName: "bed.double.fill")
                    .font(.system(size: 16 * fontScale))
                    .foregroundStyle(resolvedIconColor)
                    .frame(width: 28 * fontScale, alignment: .center)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Layover at \(station)")
                            .appScaledFont(.subheadline, weight: .bold, scale: fontScale)
                            .foregroundStyle(isPast ? .gray : .primary)
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
                            Text("\(remainingText) left")
                                .appScaledFont(.caption, scale: fontScale)
                                .foregroundStyle(isPast ? .gray : Color(red: 0.95, green: 0.58, blue: 0.12))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
    }
}
