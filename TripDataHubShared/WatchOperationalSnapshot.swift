import Foundation

// MARK: - Snapshot

struct WatchOperationalSnapshot: Codable, Equatable {
    let mode: WatchOperationalMode
    let generatedAtUTC: Date
    let trip: TripPayload?
    let reserve: ReservePayload?
    let training: TrainingPayload?
    let offDuty: OffDutyPayload?
}

// MARK: - Payloads

struct TripPayload: Codable, Equatable {
    let depIata: String
    let depTimeZoneIdentifier: String
    let arrIata: String
    let arrTimeZoneIdentifier: String
    let depUtc: Date
    let arrUtc: Date
    /// Non-nil when this leg departs from crew domicile (first leg of a pairing).
    /// Set to depUtc - 1h30m. Watch counts down to Report, not to departure.
    /// Nil at layover stations — Watch counts down to departure.
    let reportUtc: Date?
}

struct ReservePayload: Codable, Equatable {
    let domicile: String
    let ldtTimeZoneIdentifier: String
    let reserveType: String
    let windowStartUtc: Date
    let windowEndUtc: Date
}

struct TrainingPayload: Codable, Equatable {
    let eventName: String
    let startUtc: Date
    let startLdtFormatted: String
    let dateLabelFormatted: String
}

struct OffDutyPayload: Codable, Equatable {
    let nextDutyStartUtc: Date
    let nextDutyType: String
    let dutyTimeLabel: String
    let reportLdtFormatted: String
    let dateLabelFormatted: String
    let dayOfWeekFormatted: String
}

// MARK: - Validation

enum WatchSnapshotValidationError: Error, Equatable {
    case missingPayload(WatchOperationalMode)
}

extension WatchOperationalSnapshot {
    func validatePayloadForMode() throws {
        let valid: Bool
        switch mode {
        case .trip:     valid = trip != nil
        case .reserve:  valid = reserve != nil
        case .training: valid = training != nil
        case .offDuty:  valid = offDuty != nil
        }
        if !valid {
            throw WatchSnapshotValidationError.missingPayload(mode)
        }
    }
}

// MARK: - Content equality (ignores generatedAtUTC for deduplication)

extension WatchOperationalSnapshot {
    func contentEquals(_ other: WatchOperationalSnapshot) -> Bool {
        mode == other.mode &&
        trip == other.trip &&
        reserve == other.reserve &&
        training == other.training &&
        offDuty == other.offDuty
    }
}

// MARK: - Data encode/decode helpers

extension WatchOperationalSnapshot {
    func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(from data: Data) throws -> WatchOperationalSnapshot {
        try JSONDecoder().decode(WatchOperationalSnapshot.self, from: data)
    }
}

// MARK: - Debug mock snapshots

#if DEBUG
extension WatchOperationalSnapshot {
    static let mockTrip = WatchOperationalSnapshot(
        mode: .trip,
        generatedAtUTC: Date(),
        trip: TripPayload(
            depIata: "ANC",
            depTimeZoneIdentifier: "America/Anchorage",
            arrIata: "SDF",
            arrTimeZoneIdentifier: "America/Kentucky/Louisville",
            depUtc: Date().addingTimeInterval(2.5 * 3600),
            arrUtc: Date().addingTimeInterval(6.0 * 3600),
            reportUtc: Date().addingTimeInterval(2.5 * 3600 - 90 * 60)
        ),
        reserve: nil,
        training: nil,
        offDuty: nil
    )

    static let mockReserve = WatchOperationalSnapshot(
        mode: .reserve,
        generatedAtUTC: Date(),
        trip: nil,
        reserve: ReservePayload(
            domicile: "ANC",
            ldtTimeZoneIdentifier: "America/Anchorage",
            reserveType: "RSV-C",
            windowStartUtc: Date().addingTimeInterval(-2.0 * 3600),
            windowEndUtc: Date().addingTimeInterval(2.0 * 3600)
        ),
        training: nil,
        offDuty: nil
    )

    static let mockTraining = WatchOperationalSnapshot(
        mode: .training,
        generatedAtUTC: Date(),
        trip: nil,
        reserve: nil,
        training: TrainingPayload(
            eventName: "CQ12",
            startUtc: Date().addingTimeInterval(1.3 * 3600),
            startLdtFormatted: "09:00 LDT",
            dateLabelFormatted: "Tue · May 27"
        ),
        offDuty: nil
    )

    static let mockOffDuty = WatchOperationalSnapshot(
        mode: .offDuty,
        generatedAtUTC: Date(),
        trip: nil,
        reserve: nil,
        training: nil,
        offDuty: OffDutyPayload(
            nextDutyStartUtc: Date().addingTimeInterval(86400 + 14.5 * 3600),
            nextDutyType: "TRIP",
            dutyTimeLabel: "Report",
            reportLdtFormatted: "14:30 LDT",
            dateLabelFormatted: "MAY 28",
            dayOfWeekFormatted: "Wed"
        )
    )
}
#endif
