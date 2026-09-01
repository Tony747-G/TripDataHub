import Foundation

protocol IATATimeZoneResolving: AnyObject, Sendable {
    var mappingVersion: String { get }
    func resolve(_ iata: String) -> String?
    func airportName(_ iata: String) -> String?
    func cityName(_ iata: String) -> String?
    func coordinate(_ iata: String) -> HomeWidgetAirportCoordinate?
    func setOverride(iata: String, tzID: String?)
    func currentOverrides() -> [String: String]
}

extension IATATimeZoneResolving {
    func coordinate(_ iata: String) -> HomeWidgetAirportCoordinate? { nil }
}

final class IATATimeZoneResolver: IATATimeZoneResolving, @unchecked Sendable {
    static let shared = IATATimeZoneResolver()

    private static let baseMappingVersion = "iata-tz-2026-06-09"
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
        "HGH": "Asia/Shanghai",
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

    /// Airport coordinates are a filtered snapshot of the public-domain OurAirports dataset,
    /// pinned to commit 9e51f13487de777bdc473a37d271981a2d0b30ca (2026-08-31).
    /// The table covers every IATA code in `builtInMap`; PBI uses the same pinned dataset's
    /// KPBI coordinates because that source temporarily lists DJT as the primary IATA code.
    private static let builtInCoordinates: [String: HomeWidgetAirportCoordinate] = [
        "ABQ": .init(latitude: 35.039976, longitude: -106.608925),
        "ABY": .init(latitude: 31.532946, longitude: -84.196215),
        "ALB": .init(latitude: 42.748299, longitude: -73.801697),
        "AMS": .init(latitude: 52.308601, longitude: 4.763890),
        "ANC": .init(latitude: 61.179004, longitude: -149.992561),
        "ARN": .init(latitude: 59.648490, longitude: 17.928829),
        "ATL": .init(latitude: 33.636700, longitude: -84.428101),
        "AUS": .init(latitude: 30.197535, longitude: -97.662015),
        "BCN": .init(latitude: 41.297100, longitude: 2.078460),
        "BDL": .init(latitude: 41.938555, longitude: -72.688016),
        "BFI": .init(latitude: 47.527042, longitude: -122.299950),
        "BGR": .init(latitude: 44.806364, longitude: -68.826668),
        "BHM": .init(latitude: 33.562877, longitude: -86.750712),
        "BIL": .init(latitude: 45.808932, longitude: -108.541242),
        "BKK": .init(latitude: 13.681100, longitude: 100.747002),
        "BLR": .init(latitude: 13.197900, longitude: 77.706299),
        "BNA": .init(latitude: 36.124500, longitude: -86.678200),
        "BOG": .init(latitude: 4.701590, longitude: -74.146900),
        "BOI": .init(latitude: 43.564400, longitude: -116.223000),
        "BOM": .init(latitude: 19.088699, longitude: 72.867897),
        "BOS": .init(latitude: 42.361970, longitude: -71.007900),
        "BUD": .init(latitude: 47.430180, longitude: 19.262393),
        "BUF": .init(latitude: 42.940498, longitude: -78.732201),
        "BUR": .init(latitude: 34.202834, longitude: -118.358050),
        "BWI": .init(latitude: 39.175400, longitude: -76.668297),
        "CAE": .init(latitude: 33.938172, longitude: -81.123022),
        "CDG": .init(latitude: 49.008960, longitude: 2.554117),
        "CGN": .init(latitude: 50.865898, longitude: 7.142740),
        "CGO": .init(latitude: 34.526497, longitude: 113.849165),
        "CID": .init(latitude: 41.884701, longitude: -91.710800),
        "CLE": .init(latitude: 41.411701, longitude: -81.849800),
        "CLT": .init(latitude: 35.214001, longitude: -80.943100),
        "CMH": .init(latitude: 39.998001, longitude: -82.891899),
        "CRK": .init(latitude: 15.186000, longitude: 120.559998),
        "CVG": .init(latitude: 39.048801, longitude: -84.667801),
        "DAD": .init(latitude: 16.043900, longitude: 108.198997),
        "DAL": .init(latitude: 32.844776, longitude: -96.847653),
        "DCA": .init(latitude: 38.852100, longitude: -77.037697),
        "DEL": .init(latitude: 28.555630, longitude: 77.095190),
        "DEN": .init(latitude: 39.860027, longitude: -104.673792),
        "DFW": .init(latitude: 32.896801, longitude: -97.038002),
        "DOH": .init(latitude: 25.273056, longitude: 51.608056),
        "DSM": .init(latitude: 41.534027, longitude: -93.656719),
        "DTW": .init(latitude: 42.213770, longitude: -83.353786),
        "DUB": .init(latitude: 53.428713, longitude: -6.262121),
        "DWC": .init(latitude: 24.896171, longitude: 55.162350),
        "DXB": .init(latitude: 25.249790, longitude: 55.370992),
        "ELP": .init(latitude: 31.809908, longitude: -106.375607),
        "EMA": .init(latitude: 52.831100, longitude: -1.328060),
        "EWR": .init(latitude: 40.689400, longitude: -74.170545),
        "FAI": .init(latitude: 64.815102, longitude: -147.856003),
        "FAR": .init(latitude: 46.920700, longitude: -96.815804),
        "FAT": .init(latitude: 36.775767, longitude: -119.718018),
        "FCO": .init(latitude: 41.804532, longitude: 12.251998),
        "FLL": .init(latitude: 26.072599, longitude: -80.152702),
        "FRA": .init(latitude: 50.026706, longitude: 8.558350),
        "FSD": .init(latitude: 43.585463, longitude: -96.741152),
        "FWA": .init(latitude: 40.978896, longitude: -85.194465),
        "GDL": .init(latitude: 20.523342, longitude: -103.310108),
        "GEG": .init(latitude: 47.619900, longitude: -117.533997),
        "GSO": .init(latitude: 36.099370, longitude: -79.937262),
        "GUA": .init(latitude: 14.582896, longitude: -90.527515),
        "GUM": .init(latitude: 13.485000, longitude: 144.797282),
        "GYY": .init(latitude: 41.617087, longitude: -87.413206),
        "HAN": .init(latitude: 21.221201, longitude: 105.806999),
        "HGH": .init(latitude: 30.236090, longitude: 120.428865),
        "HKG": .init(latitude: 22.311840, longitude: 113.914862),
        "HND": .init(latitude: 35.549678, longitude: 139.786958),
        "HNL": .init(latitude: 21.318387, longitude: -157.925670),
        "HOU": .init(latitude: 29.645336, longitude: -95.276812),
        "HSV": .init(latitude: 34.636244, longitude: -86.774378),
        "IAD": .init(latitude: 38.944500, longitude: -77.455803),
        "IAH": .init(latitude: 29.984400, longitude: -95.341400),
        "ICN": .init(latitude: 37.469101, longitude: 126.450996),
        "ICT": .init(latitude: 37.650314, longitude: -97.428583),
        "IND": .init(latitude: 39.717300, longitude: -86.294403),
        "IST": .init(latitude: 41.274874, longitude: 28.732136),
        "JAN": .init(latitude: 32.311199, longitude: -90.075897),
        "JAX": .init(latitude: 30.492469, longitude: -81.687813),
        "JFK": .init(latitude: 40.639447, longitude: -73.779317),
        "KIX": .init(latitude: 34.427299, longitude: 135.244003),
        "KKJ": .init(latitude: 33.845901, longitude: 131.035004),
        "KOA": .init(latitude: 19.738783, longitude: -156.045603),
        "KUL": .init(latitude: 2.745580, longitude: 101.709999),
        "LAN": .init(latitude: 42.777582, longitude: -84.585721),
        "LAS": .init(latitude: 36.083361, longitude: -115.151817),
        "LAX": .init(latitude: 33.942501, longitude: -118.407997),
        "LBB": .init(latitude: 33.663601, longitude: -101.822998),
        "LCK": .init(latitude: 39.813801, longitude: -82.927803),
        "LFT": .init(latitude: 30.205299, longitude: -91.987602),
        "LGA": .init(latitude: 40.777199, longitude: -73.872597),
        "LGB": .init(latitude: 33.816523, longitude: -118.149891),
        "LIH": .init(latitude: 21.974393, longitude: -159.337146),
        "LIT": .init(latitude: 34.729222, longitude: -92.223591),
        "LRD": .init(latitude: 27.543800, longitude: -99.461601),
        "MAD": .init(latitude: 40.493407, longitude: -3.572249),
        "MCI": .init(latitude: 39.301699, longitude: -94.713893),
        "MCO": .init(latitude: 28.429399, longitude: -81.308998),
        "MDT": .init(latitude: 40.192838, longitude: -76.762333),
        "MDW": .init(latitude: 41.785999, longitude: -87.752403),
        "MEM": .init(latitude: 35.043845, longitude: -89.976340),
        "MFE": .init(latitude: 26.176141, longitude: -98.237965),
        "MGA": .init(latitude: 12.141500, longitude: -86.168198),
        "MHR": .init(latitude: 38.554744, longitude: -121.297989),
        "MHT": .init(latitude: 42.932598, longitude: -71.435699),
        "MIA": .init(latitude: 25.796011, longitude: -80.289751),
        "MMX": .init(latitude: 55.535564, longitude: 13.376327),
        "MSP": .init(latitude: 44.880081, longitude: -93.221741),
        "MTY": .init(latitude: 25.778521, longitude: -100.106989),
        "MUC": .init(latitude: 48.353802, longitude: 11.786100),
        "NLU": .init(latitude: 19.743824, longitude: -99.015070),
        "NRT": .init(latitude: 35.768580, longitude: 140.388714),
        "OAK": .init(latitude: 37.720085, longitude: -122.221184),
        "OGG": .init(latitude: 20.896263, longitude: -156.431837),
        "OKC": .init(latitude: 35.393388, longitude: -97.598248),
        "OMA": .init(latitude: 41.303200, longitude: -95.894096),
        "ONT": .init(latitude: 34.056000, longitude: -117.600998),
        "ORD": .init(latitude: 41.978600, longitude: -87.904800),
        "ORF": .init(latitude: 36.895341, longitude: -76.201000),
        "OSL": .init(latitude: 60.193901, longitude: 11.100400),
        "PBI": .init(latitude: 26.683201, longitude: -80.095596),
        "PDX": .init(latitude: 45.588699, longitude: -122.598000),
        "PEN": .init(latitude: 5.296303, longitude: 100.276185),
        "PHL": .init(latitude: 39.871899, longitude: -75.241096),
        "PHX": .init(latitude: 33.435302, longitude: -112.005905),
        "PIA": .init(latitude: 40.663841, longitude: -89.692631),
        "PIT": .init(latitude: 40.491501, longitude: -80.232903),
        "PNS": .init(latitude: 30.472718, longitude: -87.186639),
        "PRG": .init(latitude: 50.100874, longitude: 14.259911),
        "PTY": .init(latitude: 9.071360, longitude: -79.383499),
        "PVD": .init(latitude: 41.725038, longitude: -71.425668),
        "PVG": .init(latitude: 31.143400, longitude: 121.805000),
        "RDU": .init(latitude: 35.878659, longitude: -78.787300),
        "RFD": .init(latitude: 42.195400, longitude: -89.097198),
        "RIC": .init(latitude: 37.505199, longitude: -77.319702),
        "RNO": .init(latitude: 39.499100, longitude: -119.767998),
        "RSW": .init(latitude: 26.534685, longitude: -81.752816),
        "SAN": .init(latitude: 32.733601, longitude: -117.190002),
        "SAT": .init(latitude: 29.533701, longitude: -98.469803),
        "SAV": .init(latitude: 32.126591, longitude: -81.199980),
        "SBD": .init(latitude: 34.096717, longitude: -117.236596),
        "SBN": .init(latitude: 41.708304, longitude: -86.316922),
        "SCL": .init(latitude: -33.393002, longitude: -70.785797),
        "SDF": .init(latitude: 38.170600, longitude: -85.735076),
        "SDQ": .init(latitude: 18.429701, longitude: -69.668900),
        "SEA": .init(latitude: 47.447943, longitude: -122.310276),
        "SFO": .init(latitude: 37.619806, longitude: -122.374821),
        "SGF": .init(latitude: 37.245047, longitude: -93.388596),
        "SGN": .init(latitude: 10.818800, longitude: 106.652000),
        "SHV": .init(latitude: 32.444747, longitude: -93.826741),
        "SIN": .init(latitude: 1.350190, longitude: 103.994003),
        "SJC": .init(latitude: 37.362452, longitude: -121.929188),
        "SJO": .init(latitude: 9.993860, longitude: -84.208801),
        "SJU": .init(latitude: 18.439400, longitude: -66.001801),
        "SLC": .init(latitude: 40.788860, longitude: -111.979866),
        "SMF": .init(latitude: 38.695400, longitude: -121.591003),
        "SNA": .init(latitude: 33.675063, longitude: -117.869281),
        "SNN": .init(latitude: 52.702000, longitude: -8.924820),
        "STL": .init(latitude: 38.748697, longitude: -90.370003),
        "STN": .init(latitude: 51.884998, longitude: 0.235000),
        "SYD": .init(latitude: -33.946098, longitude: 151.177002),
        "SYR": .init(latitude: 43.111198, longitude: -76.106300),
        "SZX": .init(latitude: 22.639474, longitude: 113.803262),
        "TLV": .init(latitude: 32.011398, longitude: 34.886700),
        "TPA": .init(latitude: 27.975500, longitude: -82.533203),
        "TPE": .init(latitude: 25.077700, longitude: 121.233002),
        "TUL": .init(latitude: 36.197084, longitude: -95.886225),
        "TYS": .init(latitude: 35.811001, longitude: -83.994003),
        "UIO": .init(latitude: -0.125399, longitude: -78.354306),
        "VCE": .init(latitude: 45.505299, longitude: 12.351900),
        "VCP": .init(latitude: -23.007404, longitude: -47.134502),
        "VLC": .init(latitude: 39.489162, longitude: -0.480961),
        "WAW": .init(latitude: 52.165699, longitude: 20.967100),
        "YMX": .init(latitude: 45.679501, longitude: -74.038696),
        "YWG": .init(latitude: 49.910000, longitude: -97.239899),
        "YYC": .init(latitude: 51.118822, longitude: -114.009933),
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
        "HGH": .init(airport_name: "Hangzhou Xiaoshan International Airport", city_name: "Hangzhou"),
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

    func coordinate(_ iata: String) -> HomeWidgetAirportCoordinate? {
        Self.builtInCoordinates[normalizedIATA(iata)]
    }

    func setOverride(iata: String, tzID: String?) {
        let key = normalizedIATA(iata)
        guard !key.isEmpty else { return }

        lock.lock()
        if let tzID = tzID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tzID.isEmpty,
           TimeZone(identifier: tzID) != nil {
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
            guard let tz = value as? String,
                  !tz.isEmpty,
                  TimeZone(identifier: tz) != nil else { continue }
            out[key.uppercased()] = tz
        }
        return out
    }
}
