import SwiftUI

struct IPadTripBarView: View {
    let segment: CalendarSegment
    let trip: CalendarTrip
    let isSelected: Bool
    let onTap: () -> Void

    private var label: String { tripBarLabel(for: trip) }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(barFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )

                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(barTextColor)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
        }
        .buttonStyle(.plain)
    }

    private var barFill: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor)
        }
        return AnyShapeStyle(Color.accentColor.opacity(0.55))
    }

    private var barTextColor: Color {
        isSelected ? .white : Color(.label)
    }
}

struct IPadTripBarSpanView: View {
    let label: String
    let isSelected: Bool
    let regressedRanges: [ClosedRange<Double>]
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                        )

                    ForEach(Array(regressedRanges.enumerated()), id: \.offset) { _, range in
                        let lower = min(max(range.lowerBound, 0), 1)
                        let upper = min(max(range.upperBound, 0), 1)
                        if upper > lower {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.orange.opacity(isSelected ? 0.95 : 0.75))
                                .frame(width: max((upper - lower) * geo.size.width, 1))
                                .offset(x: lower * geo.size.width)
                        }
                    }

                    Text(label)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(barTextColor)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var barFill: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor)
        }
        return AnyShapeStyle(Color.accentColor.opacity(0.55))
    }

    private var barTextColor: Color {
        isSelected ? .white : Color(.label)
    }
}
