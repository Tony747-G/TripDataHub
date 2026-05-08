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
