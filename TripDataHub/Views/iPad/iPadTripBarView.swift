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
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
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
    let hasRegression: Bool
    let labelFontSize: CGFloat
    let onTap: () -> Void

    private var visibleRegressionRanges: [ClosedRange<Double>] {
        regressedRanges.compactMap { range in
            let lower = min(max(range.lowerBound, 0), 1)
            let upper = min(max(range.upperBound, 0), 1)
            guard upper > lower else { return nil }
            return lower...upper
        }
    }

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

                    if visibleRegressionRanges.isEmpty, hasRegression {
                        // Defensive fallback for legacy segments that only carry the boolean flag.
                        let regressionWidth = geo.size.width * 0.30
                        RoundedRectangle(cornerRadius: 3)
                            .fill(regressionColor)
                            .frame(width: regressionWidth)
                            .offset(x: geo.size.width - regressionWidth)
                    } else {
                        ForEach(Array(visibleRegressionRanges.enumerated()), id: \.offset) { _, range in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(regressionColor)
                                .frame(width: max((range.upperBound - range.lowerBound) * geo.size.width, 1))
                                .offset(x: range.lowerBound * geo.size.width)
                        }
                    }

                    Text(label)
                        .font(.system(size: labelFontSize, weight: .semibold, design: .monospaced))
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

    private var regressionColor: Color {
        Color(hue: 0.083, saturation: 1.0, brightness: isSelected ? 0.8 : 0.6)
            .opacity(isSelected ? 0.75 : 0.60)
    }
}
