import XCTest
@testable import TripDataHub

final class WatchSnapshotTests: XCTestCase {

    // MARK: - Codable round-trip

    func testTripSnapshotRoundTrip() throws {
        let decoded = try roundTrip(WatchOperationalSnapshot.mockTrip)
        XCTAssertEqual(WatchOperationalSnapshot.mockTrip, decoded)
    }

    func testReserveSnapshotRoundTrip() throws {
        let decoded = try roundTrip(WatchOperationalSnapshot.mockReserve)
        XCTAssertEqual(WatchOperationalSnapshot.mockReserve, decoded)
    }

    func testTrainingSnapshotRoundTrip() throws {
        let decoded = try roundTrip(WatchOperationalSnapshot.mockTraining)
        XCTAssertEqual(WatchOperationalSnapshot.mockTraining, decoded)
    }

    func testOffDutySnapshotRoundTrip() throws {
        let decoded = try roundTrip(WatchOperationalSnapshot.mockOffDuty)
        XCTAssertEqual(WatchOperationalSnapshot.mockOffDuty, decoded)
    }

    // MARK: - validatePayloadForMode: valid snapshots pass

    func testAllMockSnapshotsPassValidation() throws {
        try WatchOperationalSnapshot.mockTrip.validatePayloadForMode()
        try WatchOperationalSnapshot.mockReserve.validatePayloadForMode()
        try WatchOperationalSnapshot.mockTraining.validatePayloadForMode()
        try WatchOperationalSnapshot.mockOffDuty.validatePayloadForMode()
    }

    // MARK: - validatePayloadForMode: missing payload throws

    func testMissingTripPayloadThrows() {
        let snapshot = emptySnapshot(mode: .trip)
        XCTAssertThrowsError(try snapshot.validatePayloadForMode()) { error in
            XCTAssertEqual(error as? WatchSnapshotValidationError, .missingPayload(.trip))
        }
    }

    func testMissingReservePayloadThrows() {
        let snapshot = emptySnapshot(mode: .reserve)
        XCTAssertThrowsError(try snapshot.validatePayloadForMode()) { error in
            XCTAssertEqual(error as? WatchSnapshotValidationError, .missingPayload(.reserve))
        }
    }

    func testMissingTrainingPayloadThrows() {
        let snapshot = emptySnapshot(mode: .training)
        XCTAssertThrowsError(try snapshot.validatePayloadForMode()) { error in
            XCTAssertEqual(error as? WatchSnapshotValidationError, .missingPayload(.training))
        }
    }

    func testMissingOffDutyPayloadThrows() {
        let snapshot = emptySnapshot(mode: .offDuty)
        XCTAssertThrowsError(try snapshot.validatePayloadForMode()) { error in
            XCTAssertEqual(error as? WatchSnapshotValidationError, .missingPayload(.offDuty))
        }
    }

    // MARK: - Invariants

    func testIataCodesAreThreeUppercaseLetters() {
        let trip = WatchOperationalSnapshot.mockTrip.trip!
        for iata in [trip.depIata, trip.arrIata] {
            XCTAssertEqual(iata.count, 3, "\(iata) must be 3 characters")
            XCTAssertTrue(iata.allSatisfy(\.isUppercase), "\(iata) must be uppercase")
        }
    }

    func testDepUtcIsBeforeArrUtc() {
        let trip = WatchOperationalSnapshot.mockTrip.trip!
        XCTAssertLessThan(trip.depUtc, trip.arrUtc)
    }

    func testReserveWindowEndIsAfterStart() {
        let reserve = WatchOperationalSnapshot.mockReserve.reserve!
        XCTAssertGreaterThan(reserve.windowEndUtc, reserve.windowStartUtc)
    }

    func testTimeZoneIdentifiersAreValid() {
        let trip = WatchOperationalSnapshot.mockTrip.trip!
        XCTAssertNotNil(TimeZone(identifier: trip.depTimeZoneIdentifier),
                        "Invalid dep TZ: \(trip.depTimeZoneIdentifier)")
        XCTAssertNotNil(TimeZone(identifier: trip.arrTimeZoneIdentifier),
                        "Invalid arr TZ: \(trip.arrTimeZoneIdentifier)")

        let reserve = WatchOperationalSnapshot.mockReserve.reserve!
        XCTAssertNotNil(TimeZone(identifier: reserve.ldtTimeZoneIdentifier),
                        "Invalid reserve LDT TZ: \(reserve.ldtTimeZoneIdentifier)")
    }

    func testGeneratedAtUTCPreservesSubSecondPrecision() throws {
        let now = Date()
        let snapshot = WatchOperationalSnapshot(
            mode: .offDuty,
            generatedAtUTC: now,
            trip: nil,
            reserve: nil,
            training: nil,
            offDuty: WatchOperationalSnapshot.mockOffDuty.offDuty
        )
        let decoded = try roundTrip(snapshot)
        XCTAssertEqual(decoded.generatedAtUTC.timeIntervalSinceReferenceDate,
                       now.timeIntervalSinceReferenceDate,
                       accuracy: 0.001)
    }

    // MARK: - Helpers

    private func roundTrip(_ snapshot: WatchOperationalSnapshot) throws -> WatchOperationalSnapshot {
        let data = try snapshot.encode()
        return try WatchOperationalSnapshot.decode(from: data)
    }

    private func emptySnapshot(mode: WatchOperationalMode) -> WatchOperationalSnapshot {
        WatchOperationalSnapshot(
            mode: mode,
            generatedAtUTC: Date(),
            trip: nil,
            reserve: nil,
            training: nil,
            offDuty: nil
        )
    }
}
