import Foundation

struct PayPeriodSchedule: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let label: String
    let tripCount: Int
    let legCount: Int
    let openTimeCount: Int
    let updatedAt: Date
    let legs: [TripLeg]
    let openTimeTrips: [OpenTimeTrip]
}

/// # Time semantics (INV-012)
///
/// Two different questions are answered by two different fields, and they must not be conflated:
///
/// - **Display / historical result** resolves `Actual > Current Scheduled > Original Scheduled`.
///   `depUTC` / `arrUTC` carry that resolved value and are what the Timeline renders.
/// - **Identity / planning** (Bid Period assignment, trip keys, report windows) resolves
///   `Current Scheduled > Original Scheduled`, via `plannedDepartureUTC` / `plannedArrivalUTC`.
///   An Actual time must never move a trip across a Bid Period identity boundary or shift a
///   report time, because those are properties of the schedule, not of what happened.
///
/// Every optional history field means *unknown* when `nil`. `nil` is never backfilled from a
/// neighbouring field: `originalSTDUTC == nil` means "no original schedule was ever observed",
/// not "the original equals the current". Both `init` and the synthesized `Codable` conformance
/// obey this, so a decoded leg and a constructed leg with the same inputs are `==`.
///
/// Properties are `var` deliberately. Copy-and-mutate (`var copy = leg; copy.depUTC = x`) is the
/// only supported way to derive a modified leg — hand-written memberwise reconstruction silently
/// drops any field the author forgets, which has already caused history/registration loss once.
struct TripLeg: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var payPeriod: String
    var pairing: String
    var leg: Int
    var flight: String
    var depAirport: String
    var depLocal: String
    var arrAirport: String
    var arrLocal: String
    /// Resolved departure for display: Actual > Current Scheduled > Original Scheduled.
    var depUTC: String?
    /// Resolved arrival for display: Actual > Current Scheduled > Original Scheduled.
    var arrUTC: String?
    var status: String
    var block: String
    // レイオーバー情報（到着後の滞在。既存JSONにない場合は nil）
    var layoverStation: String?
    var layoverHotelName: String?
    var layoverDuration: String?
    // Scheduled / Actual times for LogTen CSV export
    // PDF import time: stdUTC/staUTC are set from parsed times; atdUTC/ataUTC are nil until actual data is available
    var stdUTC: String?   // Scheduled Time of Departure (UTC)
    var staUTC: String?   // Scheduled Time of Arrival (UTC)
    var atdUTC: String?   // Actual Time of Departure (UTC)
    var ataUTC: String?   // Actual Time of Arrival (UTC)
    // CrewAccess leg history. stdUTC/staUTC remain the current scheduled values.
    // `nil` means "not observed" and is never synthesized from another field.
    var originalSTDUTC: String?
    var originalSTAUTC: String?
    var scheduledDepartureObservedAtUTC: String?
    var scheduledArrivalObservedAtUTC: String?
    var actualDepartureObservedAtUTC: String?
    var actualArrivalObservedAtUTC: String?
    /// TripDataHub import-operation timestamps. These are distinct from CrewAccess PDF
    /// observation timestamps above.
    var tripImportedAtUTC: String?
    var actualsImportedAtUTC: String?
    var aircraftType: String?
    var aircraftRegistration: String?

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
        ataUTC: String? = nil,
        originalSTDUTC: String? = nil,
        originalSTAUTC: String? = nil,
        scheduledDepartureObservedAtUTC: String? = nil,
        scheduledArrivalObservedAtUTC: String? = nil,
        actualDepartureObservedAtUTC: String? = nil,
        actualArrivalObservedAtUTC: String? = nil,
        tripImportedAtUTC: String? = nil,
        actualsImportedAtUTC: String? = nil,
        aircraftType: String? = nil,
        aircraftRegistration: String? = nil
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
        // No `?? stdUTC` fallback: the synthesized Decodable initializer cannot apply it, so
        // adding it here would make a constructed leg and the decoded copy of that same leg
        // compare unequal under the synthesized Equatable, and would fabricate an "original"
        // schedule for sources that never observed one.
        self.originalSTDUTC = originalSTDUTC
        self.originalSTAUTC = originalSTAUTC
        self.scheduledDepartureObservedAtUTC = scheduledDepartureObservedAtUTC
        self.scheduledArrivalObservedAtUTC = scheduledArrivalObservedAtUTC
        self.actualDepartureObservedAtUTC = actualDepartureObservedAtUTC
        self.actualArrivalObservedAtUTC = actualArrivalObservedAtUTC
        self.tripImportedAtUTC = tripImportedAtUTC
        self.actualsImportedAtUTC = actualsImportedAtUTC
        self.aircraftType = aircraftType
        self.aircraftRegistration = aircraftRegistration
    }

    /// Returns a copy of this leg with the layoverHotelName filled in.
    /// Used to enrich CloudKit uploads without mutating the local model.
    func withHotelName(_ name: String) -> TripLeg {
        var copy = self
        copy.layoverHotelName = name
        return copy
    }

    /// Planning / identity departure: Current Scheduled, then Original Scheduled, and only as a
    /// last resort the resolved display value. Deliberately does **not** prefer `atdUTC` — see the
    /// type-level note. Used by Bid Period keys and report-window calculations.
    var plannedDepartureUTC: String? { stdUTC ?? originalSTDUTC ?? depUTC }

    /// Planning / identity arrival. Same ordering rules as `plannedDepartureUTC`.
    var plannedArrivalUTC: String? { staUTC ?? originalSTAUTC ?? arrUTC }

    /// At least one actual endpoint has been observed. The leg may still be airborne.
    var hasActualTimes: Bool { atdUTC != nil || ataUTC != nil }

    /// Both actual endpoints observed — the leg is flown and closed out.
    /// Distinct from `hasActualTimes`, which is also true for an in-progress leg with only an ATD.
    var isCompleted: Bool { atdUTC != nil && ataUTC != nil }

    /// A schedule revision was observed before the endpoint occurred. `nil` originals mean the
    /// original was never observed, which is not evidence of a revision.
    var hasRevisedSchedule: Bool {
        (originalSTDUTC != nil && stdUTC != nil && originalSTDUTC != stdUTC)
            || (originalSTAUTC != nil && staUTC != nil && originalSTAUTC != staUTC)
    }
}

struct OpenTimeTrip: Identifiable, Codable, Hashable, Sendable {
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

enum FriendRequestDirection: String, Codable {
    case incoming
    case outgoing
}

struct FriendConnection: Identifiable, Codable, Hashable {
    let id: UUID
    let employeeID: String
    var nickname: String?
    var avatarImageData: Data?
    var status: FriendConnectionStatus
    var requestDirection: FriendRequestDirection?
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
        requestDirection: FriendRequestDirection? = nil,
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
        self.requestDirection = status == .pending ? (requestDirection ?? .outgoing) : nil
        self.requestedAt = requestedAt
        self.linkedAt = linkedAt
        self.acceptedAt = acceptedAt ?? (status == .accepted ? (linkedAt ?? requestedAt) : nil)
        self.sharedSchedules = sharedSchedules
        self.sharedTimelineCards = sharedTimelineCards
    }

    var isIncomingRequest: Bool {
        status == .pending && requestDirection == .incoming
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
