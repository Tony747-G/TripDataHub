import Foundation

enum DomicileSupport {
    static let defaultDomicile = "ANC"
    private static let supportedDomiciles: Set<String> = ["ANC", "SDF", "SDFZ", "ONT", "MIA"]

    static func normalize(_ raw: String?) -> String {
        let cleaned = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard supportedDomiciles.contains(cleaned) else {
            return defaultDomicile
        }
        return cleaned
    }

    static func timeZone(for raw: String?) -> TimeZone {
        let domicile = normalize(raw)
        let identifier: String
        switch domicile {
        case "SDF", "SDFZ":
            identifier = "America/Kentucky/Louisville"
        case "ONT":
            identifier = "America/Los_Angeles"
        case "MIA":
            identifier = "America/New_York"
        case "ANC":
            fallthrough
        default:
            identifier = "America/Anchorage"
        }
        return TimeZone(identifier: identifier)
            ?? IATATimeZoneResolver.shared.resolve(domicile == "SDFZ" ? "SDF" : domicile).flatMap { TimeZone(identifier: $0) }
            ?? TimeZone(identifier: "America/Anchorage")
            ?? TimeZone(secondsFromGMT: -9 * 3600)!
    }
}

enum ReportRegion: Equatable {
    case lower48
    case asia
    case europe
}

/// Classifies an airport using the app's single IATA-to-time-zone mapping.
/// Unknown airports deliberately remain unclassified so report-time callers can fail safe.
enum ReportRegionResolver {
    static func region(
        for airport: String,
        tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared
    ) -> ReportRegion? {
        var normalized = airport.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized == "SDFZ" {
            normalized = "SDF"
        }
        guard let timeZoneID = tzResolver.resolve(normalized) else { return nil }
        if timeZoneID.hasPrefix("Asia/") { return .asia }
        if timeZoneID.hasPrefix("Europe/") { return .europe }
        if lower48TimeZoneIDs.contains(timeZoneID) { return .lower48 }
        return nil
    }

    private static let lower48TimeZoneIDs: Set<String> = [
        "America/New_York",
        "America/Detroit",
        "America/Kentucky/Louisville",
        "America/Kentucky/Monticello",
        "America/Indiana/Indianapolis",
        "America/Indiana/Knox",
        "America/Indiana/Vincennes",
        "America/Chicago",
        "America/Menominee",
        "America/North_Dakota/Center",
        "America/North_Dakota/New_Salem",
        "America/North_Dakota/Beulah",
        "America/Denver",
        "America/Boise",
        "America/Phoenix",
        "America/Los_Angeles"
    ]
}

/// The app-wide report lead-time rule. All report times and duty-start calculations use this API.
enum ReportLeadTimePolicy {
    static let lower48Minutes = 60
    static let standardMinutes = 90

    static func minutes(
        originAirport: String,
        destinationAirport: String,
        tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared
    ) -> Int {
        let originRegion = ReportRegionResolver.region(for: originAirport, tzResolver: tzResolver)
        let destinationRegion = ReportRegionResolver.region(for: destinationAirport, tzResolver: tzResolver)
        if originRegion == .lower48, destinationRegion == .lower48 {
            return lower48Minutes
        }
        return standardMinutes
    }
}
