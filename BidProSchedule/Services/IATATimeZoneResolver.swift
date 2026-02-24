import Foundation

protocol IATATimeZoneResolving: AnyObject {
    var mappingVersion: String { get }
    func resolve(_ iata: String) -> String?
    func airportName(_ iata: String) -> String?
    func cityName(_ iata: String) -> String?
    func setOverride(iata: String, tzID: String?)
    func currentOverrides() -> [String: String]
}

final class IATATimeZoneResolver: IATATimeZoneResolving {
    static let shared = IATATimeZoneResolver()

    private static let baseMappingVersion = "iata-tz-2026-02-24"
    private static let overridesUserDefaultsKey = "iata_tz_user_overrides_v1"
    private let lock = NSLock()

    private static let builtInMap: [String: String] = [
        // North America
        "SDF": "America/Kentucky/Louisville",
        "ANC": "America/Anchorage",
        "ONT": "America/Los_Angeles",
        "MIA": "America/New_York",
        "LAX": "America/Los_Angeles",
        "SFO": "America/Los_Angeles",
        "SJC": "America/Los_Angeles",
        "OAK": "America/Los_Angeles",
        "SAN": "America/Los_Angeles",
        "SMF": "America/Los_Angeles",
        "SNA": "America/Los_Angeles",
        "LGB": "America/Los_Angeles",
        "BUR": "America/Los_Angeles",
        "RNO": "America/Los_Angeles",
        "LAS": "America/Los_Angeles",
        "GEG": "America/Los_Angeles",
        "BOI": "America/Boise",
        "SBD": "America/Los_Angeles",
        "ORD": "America/Chicago",
        "JFK": "America/New_York",
        "EWR": "America/New_York",
        "LGA": "America/New_York",
        "CLT": "America/New_York",
        "IAD": "America/New_York",
        "BWI": "America/New_York",
        "BOS": "America/New_York",
        "BDL": "America/New_York",
        "DCA": "America/New_York",
        "PVD": "America/New_York",
        "SYR": "America/New_York",
        "ALB": "America/New_York",
        "BGR": "America/New_York",
        "BUF": "America/New_York",
        "PIT": "America/New_York",
        "CLE": "America/New_York",
        "CMH": "America/New_York",
        "ORF": "America/New_York",
        "RIC": "America/New_York",
        "RDU": "America/New_York",
        "SAV": "America/New_York",
        "PBI": "America/New_York",
        "FLL": "America/New_York",
        "RSW": "America/New_York",
        "TPA": "America/New_York",
        "JAN": "America/Chicago",
        "ABY": "America/New_York",
        "BHM": "America/Chicago",
        "CAE": "America/New_York",
        "GSO": "America/New_York",
        "HSV": "America/Chicago",
        "JAX": "America/New_York",
        "MCO": "America/New_York",
        "PNS": "America/Chicago",
        "TYS": "America/New_York",
        "SJU": "America/Puerto_Rico",
        "SDQ": "America/Santo_Domingo",
        "SJO": "America/Costa_Rica",
        "GUA": "America/Guatemala",
        "MGA": "America/Managua",
        "PTY": "America/Panama",
        "BOG": "America/Bogota",
        "UIO": "America/Guayaquil",
        "PHL": "America/New_York",
        "PDX": "America/Los_Angeles",
        "ABQ": "America/Denver",
        "AUS": "America/Chicago",
        "DAL": "America/Chicago",
        "DFW": "America/Chicago",
        "ELP": "America/Denver",
        "FAT": "America/Los_Angeles",
        "HOU": "America/Chicago",
        "IAH": "America/Chicago",
        "LBB": "America/Chicago",
        "LIT": "America/Chicago",
        "MCI": "America/Chicago",
        "MDW": "America/Chicago",
        "OKC": "America/Chicago",
        "OMA": "America/Chicago",
        "SAT": "America/Chicago",
        "SHV": "America/Chicago",
        "STL": "America/Chicago",
        "TUL": "America/Chicago",
        "CID": "America/Chicago",
        "DSM": "America/Chicago",
        "FSD": "America/Chicago",
        "ICT": "America/Chicago",
        "PIA": "America/Chicago",
        "SGF": "America/Chicago",
        "LCK": "America/New_York",
        "MHR": "America/Los_Angeles",
        "RFD": "America/Chicago",
        "GYY": "America/Chicago",
        "SBN": "America/New_York",
        "DEN": "America/Denver",
        "BIL": "America/Denver",
        "PHX": "America/Phoenix",
        "SLC": "America/Denver",
        "YYC": "America/Edmonton",
        "YWG": "America/Winnipeg",
        "MEM": "America/Chicago",
        "BNA": "America/Chicago",
        "SEA": "America/Los_Angeles",
        "BFI": "America/Los_Angeles",
        "HNL": "Pacific/Honolulu",
        "OGG": "Pacific/Honolulu",
        "LIH": "Pacific/Honolulu",
        "KOA": "Pacific/Honolulu",
        "GUM": "Pacific/Guam",
        "MSP": "America/Chicago",
        "ATL": "America/New_York",
        "DTW": "America/Detroit",
        "LAN": "America/Detroit",
        "IND": "America/Indiana/Indianapolis",
        "CVG": "America/New_York",
        "FWA": "America/Indiana/Indianapolis",
        "MDT": "America/New_York",
        "MHT": "America/New_York",
        "FAR": "America/Chicago",
        "LFT": "America/Chicago",
        "LRD": "America/Chicago",
        "MFE": "America/Chicago",
        "FAI": "America/Anchorage",
        "YMX": "America/Toronto",

        // East Asia
        "NRT": "Asia/Tokyo",
        "HND": "Asia/Tokyo",
        "KIX": "Asia/Tokyo",
        "KKJ": "Asia/Tokyo",
        "ICN": "Asia/Seoul",
        "PVG": "Asia/Shanghai",
        "TPE": "Asia/Taipei",
        "HKG": "Asia/Hong_Kong",
        "SZX": "Asia/Shanghai",
        "CGO": "Asia/Shanghai",
        "HAN": "Asia/Ho_Chi_Minh",
        "SGN": "Asia/Ho_Chi_Minh",
        "DAD": "Asia/Ho_Chi_Minh",
        "BKK": "Asia/Bangkok",
        "SIN": "Asia/Singapore",
        "PEN": "Asia/Kuala_Lumpur",
        "KUL": "Asia/Kuala_Lumpur",
        "BLR": "Asia/Kolkata",
        "DEL": "Asia/Kolkata",
        "BOM": "Asia/Kolkata",
        "CRK": "Asia/Manila",

        // Middle East
        "DWC": "Asia/Dubai",
        "DXB": "Asia/Dubai",
        "DOH": "Asia/Qatar",
        "TLV": "Asia/Jerusalem",

        // Europe
        "AMS": "Europe/Amsterdam",
        "ARN": "Europe/Stockholm",
        "BCN": "Europe/Madrid",
        "BUD": "Europe/Budapest",
        "CGN": "Europe/Berlin",
        "CDG": "Europe/Paris",
        "DUB": "Europe/Dublin",
        "EMA": "Europe/London",
        "FCO": "Europe/Rome",
        "FRA": "Europe/Berlin",
        "IST": "Europe/Istanbul",
        "MAD": "Europe/Madrid",
        "MMX": "Europe/Stockholm",
        "MUC": "Europe/Berlin",
        "OSL": "Europe/Oslo",
        "PRG": "Europe/Prague",
        "SNN": "Europe/Dublin",
        "STN": "Europe/London",
        "VCE": "Europe/Rome",
        "VLC": "Europe/Madrid",
        "WAW": "Europe/Warsaw",

        // Mexico
        "GDL": "America/Mexico_City",
        "MTY": "America/Monterrey",
        "NLU": "America/Mexico_City",

        // Oceania
        "SYD": "Australia/Sydney",

        // South America
        "SCL": "America/Santiago",
        "VCP": "America/Sao_Paulo"
    ]

    private struct AirportMetadata {
        let airport_name: String
        let city_name: String
    }

    private static let builtInMetadata: [String: AirportMetadata] = [
        "SDF": .init(airport_name: "Louisville Muhammad Ali International Airport", city_name: "Louisville"),
        "ANC": .init(airport_name: "Ted Stevens Anchorage International Airport", city_name: "Anchorage"),
        "ONT": .init(airport_name: "Ontario International Airport", city_name: "Ontario"),
        "MIA": .init(airport_name: "Miami International Airport", city_name: "Miami"),
        "LAX": .init(airport_name: "Los Angeles International Airport", city_name: "Los Angeles"),
        "SBD": .init(airport_name: "San Bernardino International Airport", city_name: "San Bernardino"),
        "ORD": .init(airport_name: "O'Hare International Airport", city_name: "Chicago"),
        "JFK": .init(airport_name: "John F. Kennedy International Airport", city_name: "New York"),
        "EWR": .init(airport_name: "Newark Liberty International Airport", city_name: "Newark"),
        "LGA": .init(airport_name: "LaGuardia Airport", city_name: "New York"),
        "CLT": .init(airport_name: "Charlotte Douglas International Airport", city_name: "Charlotte"),
        "PHL": .init(airport_name: "Philadelphia International Airport", city_name: "Philadelphia"),
        "PDX": .init(airport_name: "Portland International Airport", city_name: "Portland"),
        "DFW": .init(airport_name: "Dallas/Fort Worth International Airport", city_name: "Dallas"),
        "DEN": .init(airport_name: "Denver International Airport", city_name: "Denver"),
        "MEM": .init(airport_name: "Memphis International Airport", city_name: "Memphis"),
        "BNA": .init(airport_name: "Nashville International Airport", city_name: "Nashville"),
        "SEA": .init(airport_name: "Seattle-Tacoma International Airport", city_name: "Seattle"),
        "BFI": .init(airport_name: "Boeing Field / King County International Airport", city_name: "Seattle"),
        "HNL": .init(airport_name: "Daniel K. Inouye International Airport", city_name: "Honolulu"),
        "SJU": .init(airport_name: "Luis Munoz Marin International Airport", city_name: "San Juan"),
        "GUM": .init(airport_name: "Antonio B. Won Pat International Airport", city_name: "Guam"),
        "KOA": .init(airport_name: "Ellison Onizuka Kona International Airport", city_name: "Kona"),
        "MSP": .init(airport_name: "Minneapolis-Saint Paul International Airport", city_name: "Minneapolis"),
        "ATL": .init(airport_name: "Hartsfield-Jackson Atlanta International Airport", city_name: "Atlanta"),
        "DTW": .init(airport_name: "Detroit Metropolitan Wayne County Airport", city_name: "Detroit"),
        "LAN": .init(airport_name: "Capital Region International Airport", city_name: "Lansing"),
        "IND": .init(airport_name: "Indianapolis International Airport", city_name: "Indianapolis"),
        "CVG": .init(airport_name: "Cincinnati/Northern Kentucky International Airport", city_name: "Cincinnati"),
        "ABQ": .init(airport_name: "Albuquerque International Sunport", city_name: "Albuquerque"),
        "ABY": .init(airport_name: "Southwest Georgia Regional Airport", city_name: "Albany"),
        "ALB": .init(airport_name: "Albany International Airport", city_name: "Albany"),
        "AUS": .init(airport_name: "Austin-Bergstrom International Airport", city_name: "Austin"),
        "BGR": .init(airport_name: "Bangor International Airport", city_name: "Bangor"),
        "BHM": .init(airport_name: "Birmingham-Shuttlesworth International Airport", city_name: "Birmingham"),
        "BIL": .init(airport_name: "Billings Logan International Airport", city_name: "Billings"),
        "BOI": .init(airport_name: "Boise Airport", city_name: "Boise"),
        "BOS": .init(airport_name: "Logan International Airport", city_name: "Boston"),
        "BDL": .init(airport_name: "Bradley International Airport", city_name: "Hartford"),
        "DCA": .init(airport_name: "Ronald Reagan Washington National Airport", city_name: "Washington"),
        "BUF": .init(airport_name: "Buffalo Niagara International Airport", city_name: "Buffalo"),
        "BUR": .init(airport_name: "Hollywood Burbank Airport", city_name: "Burbank"),
        "BWI": .init(airport_name: "Baltimore/Washington International Thurgood Marshall Airport", city_name: "Baltimore"),
        "CAE": .init(airport_name: "Columbia Metropolitan Airport", city_name: "Columbia"),
        "CID": .init(airport_name: "The Eastern Iowa Airport", city_name: "Cedar Rapids"),
        "CLE": .init(airport_name: "Cleveland Hopkins International Airport", city_name: "Cleveland"),
        "CMH": .init(airport_name: "John Glenn Columbus International Airport", city_name: "Columbus"),
        "DAL": .init(airport_name: "Dallas Love Field", city_name: "Dallas"),
        "DSM": .init(airport_name: "Des Moines International Airport", city_name: "Des Moines"),
        "ELP": .init(airport_name: "El Paso International Airport", city_name: "El Paso"),
        "FAT": .init(airport_name: "Fresno Yosemite International Airport", city_name: "Fresno"),
        "HOU": .init(airport_name: "William P. Hobby Airport", city_name: "Houston"),
        "FAR": .init(airport_name: "Hector International Airport", city_name: "Fargo"),
        "FLL": .init(airport_name: "Fort Lauderdale-Hollywood International Airport", city_name: "Fort Lauderdale"),
        "FSD": .init(airport_name: "Sioux Falls Regional Airport", city_name: "Sioux Falls"),
        "FWA": .init(airport_name: "Fort Wayne International Airport", city_name: "Fort Wayne"),
        "GEG": .init(airport_name: "Spokane International Airport", city_name: "Spokane"),
        "GSO": .init(airport_name: "Piedmont Triad International Airport", city_name: "Greensboro"),
        "GYY": .init(airport_name: "Gary/Chicago International Airport", city_name: "Gary"),
        "HSV": .init(airport_name: "Huntsville International Airport", city_name: "Huntsville"),
        "IAD": .init(airport_name: "Washington Dulles International Airport", city_name: "Washington"),
        "IAH": .init(airport_name: "George Bush Intercontinental Airport", city_name: "Houston"),
        "ICT": .init(airport_name: "Wichita Dwight D. Eisenhower National Airport", city_name: "Wichita"),
        "JAN": .init(airport_name: "Jackson-Medgar Wiley Evers International Airport", city_name: "Jackson"),
        "JAX": .init(airport_name: "Jacksonville International Airport", city_name: "Jacksonville"),
        "LAS": .init(airport_name: "Harry Reid International Airport", city_name: "Las Vegas"),
        "LBB": .init(airport_name: "Lubbock Preston Smith International Airport", city_name: "Lubbock"),
        "LCK": .init(airport_name: "Rickenbacker International Airport", city_name: "Columbus"),
        "LFT": .init(airport_name: "Lafayette Regional Airport", city_name: "Lafayette"),
        "LGB": .init(airport_name: "Long Beach Airport", city_name: "Long Beach"),
        "LIH": .init(airport_name: "Lihue Airport", city_name: "Lihue"),
        "LIT": .init(airport_name: "Clinton National Airport", city_name: "Little Rock"),
        "LRD": .init(airport_name: "Laredo International Airport", city_name: "Laredo"),
        "MCI": .init(airport_name: "Kansas City International Airport", city_name: "Kansas City"),
        "MCO": .init(airport_name: "Orlando International Airport", city_name: "Orlando"),
        "MDT": .init(airport_name: "Harrisburg International Airport", city_name: "Harrisburg"),
        "MDW": .init(airport_name: "Chicago Midway International Airport", city_name: "Chicago"),
        "MFE": .init(airport_name: "McAllen International Airport", city_name: "McAllen"),
        "MHR": .init(airport_name: "Sacramento Mather Airport", city_name: "Sacramento"),
        "MHT": .init(airport_name: "Manchester-Boston Regional Airport", city_name: "Manchester"),
        "OAK": .init(airport_name: "Oakland International Airport", city_name: "Oakland"),
        "OGG": .init(airport_name: "Kahului Airport", city_name: "Kahului"),
        "OKC": .init(airport_name: "Will Rogers World Airport", city_name: "Oklahoma City"),
        "OMA": .init(airport_name: "Eppley Airfield", city_name: "Omaha"),
        "ORF": .init(airport_name: "Norfolk International Airport", city_name: "Norfolk"),
        "PBI": .init(airport_name: "Palm Beach International Airport", city_name: "West Palm Beach"),
        "PHX": .init(airport_name: "Phoenix Sky Harbor International Airport", city_name: "Phoenix"),
        "PIA": .init(airport_name: "General Wayne A. Downing Peoria International Airport", city_name: "Peoria"),
        "PIT": .init(airport_name: "Pittsburgh International Airport", city_name: "Pittsburgh"),
        "PNS": .init(airport_name: "Pensacola International Airport", city_name: "Pensacola"),
        "PVD": .init(airport_name: "Rhode Island T. F. Green International Airport", city_name: "Providence"),
        "RDU": .init(airport_name: "Raleigh-Durham International Airport", city_name: "Raleigh"),
        "RFD": .init(airport_name: "Chicago Rockford International Airport", city_name: "Rockford"),
        "RIC": .init(airport_name: "Richmond International Airport", city_name: "Richmond"),
        "RNO": .init(airport_name: "Reno-Tahoe International Airport", city_name: "Reno"),
        "RSW": .init(airport_name: "Southwest Florida International Airport", city_name: "Fort Myers"),
        "SAN": .init(airport_name: "San Diego International Airport", city_name: "San Diego"),
        "SAT": .init(airport_name: "San Antonio International Airport", city_name: "San Antonio"),
        "SHV": .init(airport_name: "Shreveport Regional Airport", city_name: "Shreveport"),
        "SAV": .init(airport_name: "Savannah/Hilton Head International Airport", city_name: "Savannah"),
        "SBN": .init(airport_name: "South Bend International Airport", city_name: "South Bend"),
        "SDQ": .init(airport_name: "Las Americas International Airport", city_name: "Santo Domingo"),
        "SJO": .init(airport_name: "Juan Santamaria International Airport", city_name: "San Jose"),
        "GUA": .init(airport_name: "La Aurora International Airport", city_name: "Guatemala City"),
        "MGA": .init(airport_name: "Augusto C. Sandino International Airport", city_name: "Managua"),
        "PTY": .init(airport_name: "Tocumen International Airport", city_name: "Panama City"),
        "BOG": .init(airport_name: "El Dorado International Airport", city_name: "Bogota"),
        "UIO": .init(airport_name: "Mariscal Sucre International Airport", city_name: "Quito"),
        "SFO": .init(airport_name: "San Francisco International Airport", city_name: "San Francisco"),
        "SGF": .init(airport_name: "Springfield-Branson National Airport", city_name: "Springfield"),
        "SJC": .init(airport_name: "Norman Y. Mineta San Jose International Airport", city_name: "San Jose"),
        "SLC": .init(airport_name: "Salt Lake City International Airport", city_name: "Salt Lake City"),
        "SMF": .init(airport_name: "Sacramento International Airport", city_name: "Sacramento"),
        "SNA": .init(airport_name: "John Wayne Airport", city_name: "Santa Ana"),
        "STL": .init(airport_name: "St. Louis Lambert International Airport", city_name: "St. Louis"),
        "SYR": .init(airport_name: "Syracuse Hancock International Airport", city_name: "Syracuse"),
        "TPA": .init(airport_name: "Tampa International Airport", city_name: "Tampa"),
        "TUL": .init(airport_name: "Tulsa International Airport", city_name: "Tulsa"),
        "TYS": .init(airport_name: "McGhee Tyson Airport", city_name: "Knoxville"),
        "YYC": .init(airport_name: "Calgary International Airport", city_name: "Calgary"),
        "YWG": .init(airport_name: "Winnipeg James Armstrong Richardson International Airport", city_name: "Winnipeg"),
        "YMX": .init(airport_name: "Montreal-Mirabel International Airport", city_name: "Montreal"),
        "FAI": .init(airport_name: "Fairbanks International Airport", city_name: "Fairbanks"),

        "NRT": .init(airport_name: "Narita International Airport", city_name: "Tokyo"),
        "HND": .init(airport_name: "Haneda Airport", city_name: "Tokyo"),
        "KIX": .init(airport_name: "Kansai International Airport", city_name: "Osaka"),
        "KKJ": .init(airport_name: "Kitakyushu Airport", city_name: "Kitakyushu"),
        "ICN": .init(airport_name: "Incheon International Airport", city_name: "Seoul"),
        "PVG": .init(airport_name: "Shanghai Pudong International Airport", city_name: "Shanghai"),
        "TPE": .init(airport_name: "Taiwan Taoyuan International Airport", city_name: "Taipei"),
        "HKG": .init(airport_name: "Hong Kong International Airport", city_name: "Hong Kong"),
        "SZX": .init(airport_name: "Shenzhen Bao'an International Airport", city_name: "Shenzhen"),
        "CGO": .init(airport_name: "Zhengzhou Xinzheng International Airport", city_name: "Zhengzhou"),
        "HAN": .init(airport_name: "Noi Bai International Airport", city_name: "Hanoi"),
        "SGN": .init(airport_name: "Tan Son Nhat International Airport", city_name: "Ho Chi Minh City"),
        "DAD": .init(airport_name: "Da Nang International Airport", city_name: "Da Nang"),
        "BKK": .init(airport_name: "Suvarnabhumi Airport", city_name: "Bangkok"),
        "SIN": .init(airport_name: "Singapore Changi Airport", city_name: "Singapore"),
        "PEN": .init(airport_name: "Penang International Airport", city_name: "Penang"),
        "KUL": .init(airport_name: "Kuala Lumpur International Airport", city_name: "Kuala Lumpur"),
        "CRK": .init(airport_name: "Clark International Airport", city_name: "Clark"),
        "BLR": .init(airport_name: "Kempegowda International Airport", city_name: "Bengaluru"),
        "DEL": .init(airport_name: "Indira Gandhi International Airport", city_name: "Delhi"),
        "BOM": .init(airport_name: "Chhatrapati Shivaji Maharaj International Airport", city_name: "Mumbai"),

        "DWC": .init(airport_name: "Al Maktoum International Airport", city_name: "Dubai"),
        "DXB": .init(airport_name: "Dubai International Airport", city_name: "Dubai"),
        "DOH": .init(airport_name: "Hamad International Airport", city_name: "Doha"),
        "TLV": .init(airport_name: "Ben Gurion Airport", city_name: "Tel Aviv"),

        "AMS": .init(airport_name: "Amsterdam Airport Schiphol", city_name: "Amsterdam"),
        "ARN": .init(airport_name: "Stockholm Arlanda Airport", city_name: "Stockholm"),
        "BCN": .init(airport_name: "Barcelona-El Prat Airport", city_name: "Barcelona"),
        "BUD": .init(airport_name: "Budapest Ferenc Liszt International Airport", city_name: "Budapest"),
        "CGN": .init(airport_name: "Cologne Bonn Airport", city_name: "Cologne"),
        "CDG": .init(airport_name: "Charles de Gaulle Airport", city_name: "Paris"),
        "DUB": .init(airport_name: "Dublin Airport", city_name: "Dublin"),
        "EMA": .init(airport_name: "East Midlands Airport", city_name: "East Midlands"),
        "FCO": .init(airport_name: "Leonardo da Vinci Fiumicino Airport", city_name: "Rome"),
        "FRA": .init(airport_name: "Frankfurt Airport", city_name: "Frankfurt"),
        "IST": .init(airport_name: "Istanbul Airport", city_name: "Istanbul"),
        "MAD": .init(airport_name: "Adolfo Suarez Madrid-Barajas Airport", city_name: "Madrid"),
        "MMX": .init(airport_name: "Malmo Airport", city_name: "Malmo"),
        "MUC": .init(airport_name: "Munich Airport", city_name: "Munich"),
        "OSL": .init(airport_name: "Oslo Airport", city_name: "Oslo"),
        "PRG": .init(airport_name: "Vaclav Havel Airport Prague", city_name: "Prague"),
        "SNN": .init(airport_name: "Shannon Airport", city_name: "Shannon"),
        "STN": .init(airport_name: "London Stansted Airport", city_name: "London"),
        "VCE": .init(airport_name: "Venice Marco Polo Airport", city_name: "Venice"),
        "VLC": .init(airport_name: "Valencia Airport", city_name: "Valencia"),
        "WAW": .init(airport_name: "Warsaw Chopin Airport", city_name: "Warsaw"),

        "GDL": .init(airport_name: "Guadalajara International Airport", city_name: "Guadalajara"),
        "MTY": .init(airport_name: "Monterrey International Airport", city_name: "Monterrey"),
        "NLU": .init(airport_name: "Felipe Angeles International Airport", city_name: "Mexico City"),

        "SYD": .init(airport_name: "Sydney Kingsford Smith Airport", city_name: "Sydney"),

        "SCL": .init(airport_name: "Arturo Merino Benitez International Airport", city_name: "Santiago"),
        "VCP": .init(airport_name: "Viracopos International Airport", city_name: "Campinas")
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

    func airportName(_ iata: String) -> String? {
        let key = normalizedIATA(iata)
        guard !key.isEmpty else { return nil }
        return Self.builtInMetadata[key]?.airport_name
    }

    func cityName(_ iata: String) -> String? {
        let key = normalizedIATA(iata)
        guard !key.isEmpty else { return nil }
        return Self.builtInMetadata[key]?.city_name
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
