import SwiftUI

enum SharedDateFormatters {
    static let localDayInput: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let localDayHeader: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE, MMM d yyyy"
        return formatter
    }()

    static let utcDayOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum ScheduleDateText {
    static func datePart(from value: String) -> String {
        value.split(separator: " ").first.map(String.init) ?? value
    }

    static func timePart(from value: String) -> String {
        let pieces = value.split(separator: " ")
        return pieces.count >= 2 ? String(pieces[1]) : value
    }

    static func dayHeaderLabel(from dateText: String) -> String {
        guard let date = SharedDateFormatters.localDayInput.date(from: dateText) else { return dateText }
        return SharedDateFormatters.localDayHeader.string(from: date)
    }

    static func dayShift(from depText: String, to arrText: String) -> Int {
        let depDate = datePart(from: depText)
        let arrDate = datePart(from: arrText)
        guard let dep = SharedDateFormatters.utcDayOnly.date(from: depDate),
              let arr = SharedDateFormatters.utcDayOnly.date(from: arrDate)
        else { return 0 }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: dep, to: arr).day ?? 0
    }
}

enum ScheduleColors {
    static let timelineDateLight = Color(red: 0.38, green: 0.22, blue: 0.12)
    static let openTimeDateLight = Color(red: 0.24, green: 0.10, blue: 0.06)
    static let dateDark = Color(red: 0.78, green: 0.62, blue: 0.45)
    static let dayHeaderLightBackground = Color(red: 0.90, green: 0.90, blue: 0.92)
    static let dayHeaderDarkBackground = Color(red: 0.21, green: 0.21, blue: 0.24)

    static func dayHeaderBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? dayHeaderDarkBackground : dayHeaderLightBackground
    }

    static func timelineDateHeaderText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? dateDark : timelineDateLight
    }

    static func openTimeDateHeaderText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? dateDark : openTimeDateLight
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum TimelineSourceFilter: String, CaseIterable, Identifiable {
    case crewAccess
    case tripBoard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .crewAccess:
            return "CrewAccess"
        case .tripBoard:
            return "TripBoard"
        }
    }
}

enum AppFontSizeOption: String, CaseIterable, Identifiable {
    case large
    case medium
    case small

    var id: String { rawValue }

    var label: String {
        switch self {
        case .large:
            return "Large"
        case .medium:
            return "Medium"
        case .small:
            return "Small"
        }
    }

    var scaleFactor: CGFloat {
        switch self {
        case .small:
            return 1.0
        case .medium:
            return 1.10
        case .large:
            return 1.25
        }
    }
}

enum AppFontStyle {
    case caption2
    case caption
    case footnote
    case subheadline
    case headline

    var baseSize: CGFloat {
        switch self {
        case .caption2:
            return 11
        case .caption:
            return 12
        case .footnote:
            return 13
        case .subheadline:
            return 15
        case .headline:
            return 17
        }
    }
}

extension View {
    func appScaledFont(_ style: AppFontStyle, weight: Font.Weight? = nil, scale: CGFloat) -> some View {
        modifier(AppScaledFontModifier(style: style, weight: weight, scale: scale))
    }
}

private struct AppScaledFontModifier: ViewModifier {
    let style: AppFontStyle
    let weight: Font.Weight?
    let scale: CGFloat
    @ScaledMetric private var scaledBaseSize: CGFloat

    init(style: AppFontStyle, weight: Font.Weight?, scale: CGFloat) {
        self.style = style
        self.weight = weight
        self.scale = scale
        switch style {
        case .caption2:
            _scaledBaseSize = ScaledMetric(wrappedValue: style.baseSize, relativeTo: .caption2)
        case .caption:
            _scaledBaseSize = ScaledMetric(wrappedValue: style.baseSize, relativeTo: .caption)
        case .footnote:
            _scaledBaseSize = ScaledMetric(wrappedValue: style.baseSize, relativeTo: .footnote)
        case .subheadline:
            _scaledBaseSize = ScaledMetric(wrappedValue: style.baseSize, relativeTo: .subheadline)
        case .headline:
            _scaledBaseSize = ScaledMetric(wrappedValue: style.baseSize, relativeTo: .headline)
        }
    }

    func body(content: Content) -> some View {
        if let weight {
            content.font(.system(size: scaledBaseSize * scale, weight: weight))
        } else {
            content.font(.system(size: scaledBaseSize * scale))
        }
    }
}
