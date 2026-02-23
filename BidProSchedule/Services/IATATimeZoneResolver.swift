import Foundation

protocol IATATimeZoneResolving: AnyObject {
    var mappingVersion: String { get }
    func resolve(_ iata: String) -> String?
    func setOverride(iata: String, tzID: String?)
    func currentOverrides() -> [String: String]
}

final class IATATimeZoneResolver: IATATimeZoneResolving {
    static let shared = IATATimeZoneResolver()

    private static let baseMappingVersion = "iata-tz-2026-02-22"
    private static let overridesUserDefaultsKey = "iata_tz_user_overrides_v1"
    private let lock = NSLock()

    private static let builtInMap: [String: String] = [
        // North America
        "SDF": "America/Kentucky/Louisville",
        "ANC": "America/Anchorage",
        "ONT": "America/Los_Angeles",
        "MIA": "America/New_York",
        "LAX": "America/Los_Angeles",
        "SBD": "America/Los_Angeles",
        "ORD": "America/Chicago",
        "JFK": "America/New_York",
        "PHL": "America/New_York",
        "PDX": "America/Los_Angeles",
        "DFW": "America/Chicago",
        "MEM": "America/Chicago",
        "SEA": "America/Los_Angeles",
        "BFI": "America/Los_Angeles",
        "HNL": "Pacific/Honolulu",
        "GUM": "Pacific/Guam",
        "KOA": "Pacific/Honolulu",
        "MSP": "America/Chicago",
        "IND": "America/Indiana/Indianapolis",
        "CVG": "America/New_York",
        "FAI": "America/Anchorage",

        // East Asia
        "NRT": "Asia/Tokyo",
        "KIX": "Asia/Tokyo",
        "KKJ": "Asia/Tokyo",
        "ICN": "Asia/Seoul",
        "PVG": "Asia/Shanghai",
        "TPE": "Asia/Taipei",
        "HKG": "Asia/Hong_Kong",
        "SZX": "Asia/Shanghai",
        "CGO": "Asia/Shanghai",
        "HAN": "Asia/Bangkok",
        "SGN": "Asia/Ho_Chi_Minh",
        "DAD": "Asia/Ho_Chi_Minh",
        "BKK": "Asia/Bangkok",
        "SIN": "Asia/Singapore",
        "KUL": "Asia/Kuala_Lumpur",
        "BLR": "Asia/Kolkata",
        "DEL": "Asia/Kolkata",
        "BOM": "Asia/Kolkata",

        // Middle East
        "DWC": "Asia/Dubai",
        "DXB": "Asia/Dubai",
        "DOH": "Asia/Qatar",

        // Europe
        "CGN": "Europe/Berlin",
        "CDG": "Europe/Paris",
        "FRA": "Europe/Berlin",
        "MUC": "Europe/Berlin"
    ]

    private var userOverrides: [String: String]

    private init() {
        self.userOverrides = Self.loadOverridesFromUserDefaults()
    }

    var mappingVersion: String {
        lock.lock()
        let count = userOverrides.count
        lock.unlock()
        return "\(Self.baseMappingVersion)+u\(count)"
    }

    func resolve(_ iata: String) -> String? {
        let key = normalizedIATA(iata)
        guard !key.isEmpty else { return nil }

        lock.lock()
        if let override = userOverrides[key] {
            lock.unlock()
            return override
        }
        lock.unlock()
        return Self.builtInMap[key]
    }

    func setOverride(iata: String, tzID: String?) {
        let key = normalizedIATA(iata)
        guard !key.isEmpty else { return }

        lock.lock()
        if let tzID, !tzID.isEmpty {
            userOverrides[key] = tzID
        } else {
            userOverrides.removeValue(forKey: key)
        }
        let snapshot = userOverrides
        lock.unlock()

        UserDefaults.standard.set(snapshot, forKey: Self.overridesUserDefaultsKey)
    }

    func currentOverrides() -> [String: String] {
        lock.lock()
        let snapshot = userOverrides
        lock.unlock()
        return snapshot
    }

    private func normalizedIATA(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    private static func loadOverridesFromUserDefaults() -> [String: String] {
        let raw = UserDefaults.standard.dictionary(forKey: overridesUserDefaultsKey) ?? [:]
        var out: [String: String] = [:]
        for (key, value) in raw {
            guard let tz = value as? String, !tz.isEmpty else { continue }
            out[key.uppercased()] = tz
        }
        return out
    }
}
