import Foundation

struct PayPeriodSchedule: Identifiable, Codable, Hashable {
    let id: String
    let label: String
    let tripCount: Int
    let legCount: Int
    let openTimeCount: Int
    let updatedAt: Date
    let legs: [TripLeg]
    let openTimeTrips: [OpenTimeTrip]
}

struct TripLeg: Identifiable, Codable, Hashable {
    let id: UUID
    let payPeriod: String
    let pairing: String
    let leg: Int
    let flight: String
    let depAirport: String
    let depLocal: String
    let arrAirport: String
    let arrLocal: String
    let depUTC: String?
    let arrUTC: String?
    let status: String
    let block: String
    // レイオーバー情報（到着後の滞在。既存JSONにない場合は nil）
    let layoverStation: String?
    let layoverHotelName: String?
    let layoverDuration: String?
    // Scheduled / Actual times for LogTen CSV export
    // PDF import time: stdUTC/staUTC are set from parsed times; atdUTC/ataUTC are nil until actual data is available
    let stdUTC: String?   // Scheduled Time of Departure (UTC)
    let staUTC: String?   // Scheduled Time of Arrival (UTC)
    let atdUTC: String?   // Actual Time of Departure (UTC)
    let ataUTC: String?   // Actual Time of Arrival (UTC)

    init(
        id: UUID = UUID(),
        payPeriod: String,
        pairing: String,
        leg: Int,
        flight: String,
        depAirport: String,
        depLocal: String,
        arrAirport: String,
        arrLocal: String,
        depUTC: String? = nil,
        arrUTC: String? = nil,
        status: String,
        block: String,
        layoverStation: String? = nil,
        layoverHotelName: String? = nil,
        layoverDuration: String? = nil,
        stdUTC: String? = nil,
        staUTC: String? = nil,
        atdUTC: String? = nil,
        ataUTC: String? = nil
    ) {
        self.id = id
        self.payPeriod = payPeriod
        self.pairing = pairing
        self.leg = leg
        self.flight = flight
        self.depAirport = depAirport
        self.depLocal = depLocal
        self.arrAirport = arrAirport
        self.arrLocal = arrLocal
        self.depUTC = depUTC
        self.arrUTC = arrUTC
        self.status = status
        self.block = block
        self.layoverStation = layoverStation
        self.layoverHotelName = layoverHotelName
        self.layoverDuration = layoverDuration
        self.stdUTC = stdUTC
        self.staUTC = staUTC
        self.atdUTC = atdUTC
        self.ataUTC = ataUTC
    }

    /// Returns a copy of this leg with the layoverHotelName filled in.
    /// Used to enrich CloudKit uploads without mutating the local model.
    func withHotelName(_ name: String) -> TripLeg {
        TripLeg(
            id: id, payPeriod: payPeriod, pairing: pairing, leg: leg,
            flight: flight, depAirport: depAirport, depLocal: depLocal,
            arrAirport: arrAirport, arrLocal: arrLocal, depUTC: depUTC,
            arrUTC: arrUTC, status: status, block: block,
            layoverStation: layoverStation, layoverHotelName: name,
            layoverDuration: layoverDuration, stdUTC: stdUTC, staUTC: staUTC,
            atdUTC: atdUTC, ataUTC: ataUTC
        )
    }
}

struct OpenTimeTrip: Identifiable, Codable, Hashable {
    let id: UUID
    let payPeriod: String
    let pairing: String
    let startLocal: String
    let endLocal: String
    let route: String
    let credit: String
    let requestType: String
    let status: String
    let legs: [TripLeg]

    init(
        id: UUID = UUID(),
        payPeriod: String,
        pairing: String,
        startLocal: String,
        endLocal: String,
        route: String,
        credit: String,
        requestType: String,
        status: String,
        legs: [TripLeg] = []
    ) {
        self.id = id
        self.payPeriod = payPeriod
        self.pairing = pairing
        self.startLocal = startLocal
        self.endLocal = endLocal
        self.route = route
        self.credit = credit
        self.requestType = requestType
        self.status = status
        self.legs = legs
    }
}

enum FriendConnectionStatus: String, Codable {
    case pending
    case accepted
}

struct FriendConnection: Identifiable, Codable, Hashable {
    let id: UUID
    let employeeID: String
    var nickname: String?
    var avatarImageData: Data?
    var status: FriendConnectionStatus
    var requestedAt: Date
    var linkedAt: Date?
    var acceptedAt: Date?
    var sharedSchedules: [PayPeriodSchedule]
    // TODO: Phase B 以降で削除予定。iOS アプリ内では未使用（Web ビューア専用）。
    var sharedTimelineCards: [WebTimelineCard]

    var displayName: String {
        let trimmedNickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedNickname.isEmpty ? employeeID : trimmedNickname
    }

    init(
        id: UUID = UUID(),
        employeeID: String,
        nickname: String? = nil,
        avatarImageData: Data? = nil,
        status: FriendConnectionStatus,
        requestedAt: Date = Date(),
        linkedAt: Date? = nil,
        acceptedAt: Date? = nil,
        sharedSchedules: [PayPeriodSchedule] = [],
        sharedTimelineCards: [WebTimelineCard] = []
    ) {
        self.id = id
        self.employeeID = employeeID
        self.nickname = nickname
        self.avatarImageData = avatarImageData
        self.status = status
        self.requestedAt = requestedAt
        self.linkedAt = linkedAt
        self.acceptedAt = acceptedAt ?? (status == .accepted ? (linkedAt ?? requestedAt) : nil)
        self.sharedSchedules = sharedSchedules
        self.sharedTimelineCards = sharedTimelineCards
    }
}

struct PilotSeniorityRecord: Identifiable, Codable, Hashable {
    var id: String { gemsID }
    let seniorityNumber: String
    let name: String
    let gemsID: String
    let domicile: String
    let equipment: String
    let seat: String
    let dateOfHire: String
    let dateOfBirth: String
}

struct VerifiedIdentityProfile: Codable, Hashable {
    let cloudKitRecordName: String
    let name: String
    let gemsID: String
    let domicile: String
    let equipment: String
    let seat: String
    let dateOfHire: String
    let isAdminEligible: Bool
    let adminPolicyFingerprint: String?
    let verifiedAt: Date

    private enum CodingKeys: String, CodingKey {
        case cloudKitRecordName
        case name
        case gemsID
        case domicile
        case equipment
        case seat
        case dateOfHire
        case isAdminEligible
        case adminPolicyFingerprint
        case verifiedAt
    }

    init(
        cloudKitRecordName: String,
        name: String,
        gemsID: String,
        domicile: String,
        equipment: String,
        seat: String,
        dateOfHire: String,
        isAdminEligible: Bool,
        adminPolicyFingerprint: String?,
        verifiedAt: Date
    ) {
        self.cloudKitRecordName = cloudKitRecordName
        self.name = name
        self.gemsID = gemsID
        self.domicile = domicile
        self.equipment = equipment
        self.seat = seat
        self.dateOfHire = dateOfHire
        self.isAdminEligible = isAdminEligible
        self.adminPolicyFingerprint = adminPolicyFingerprint
        self.verifiedAt = verifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cloudKitRecordName = try container.decode(String.self, forKey: .cloudKitRecordName)
        name = try container.decode(String.self, forKey: .name)
        gemsID = try container.decode(String.self, forKey: .gemsID)
        domicile = try container.decode(String.self, forKey: .domicile)
        equipment = try container.decode(String.self, forKey: .equipment)
        seat = try container.decode(String.self, forKey: .seat)
        dateOfHire = try container.decode(String.self, forKey: .dateOfHire)
        isAdminEligible = try container.decodeIfPresent(Bool.self, forKey: .isAdminEligible) ?? false
        adminPolicyFingerprint = try container.decodeIfPresent(String.self, forKey: .adminPolicyFingerprint)
        verifiedAt = try container.decode(Date.self, forKey: .verifiedAt)
    }
}
