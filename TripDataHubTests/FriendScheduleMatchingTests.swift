import CloudKit
import XCTest
@testable import TripData_Hub

final class FriendScheduleMatchingTests: XCTestCase {
    func test_restWindow_usesArrivalPlus60AndDepartureMinus120() {
        let arrivalLeg = makeLeg(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            leg: 1,
            flight: "100",
            depAirport: "ANC",
            arrAirport: "SDF",
            depUTC: "2026-05-01T06:00:00Z",
            arrUTC: "2026-05-01T10:00:00Z"
        )
        let departureLeg = makeLeg(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            leg: 2,
            flight: "101",
            depAirport: "SDF",
            arrAirport: "ANC",
            depUTC: "2026-05-01T22:00:00Z",
            arrUTC: "2026-05-02T02:00:00Z"
        )

        let snapshot = SharedScheduleExporter.snapshot(
            ownerGEMSID: "123456",
            schedules: [makeSchedule(legs: [arrivalLeg, departureLeg])]
        )

        XCTAssertEqual(snapshot.restWindows.count, 1)
        XCTAssertEqual(snapshot.restWindows[0].station, "SDF")
        XCTAssertEqual(snapshot.restWindows[0].startUTC, iso("2026-05-01T11:00:00Z"))
        XCTAssertEqual(snapshot.restWindows[0].endUTC, iso("2026-05-01T20:00:00Z"))
        XCTAssertEqual(snapshot.restWindows[0].durationMinutes, 540)
    }

    func test_restOverlap_matchesAtOneHour() {
        let mySchedules = [makeSchedule(legs: [
            makeLeg(leg: 1, flight: "100", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:00:00Z", arrUTC: "2026-05-01T10:00:00Z"),
            makeLeg(leg: 2, flight: "101", depAirport: "SDF", arrAirport: "ANC", depUTC: "2026-05-01T22:00:00Z", arrUTC: "2026-05-02T02:00:00Z")
        ])]
        let friendSchedules = [makeSchedule(legs: [
            makeLeg(leg: 1, flight: "200", depAirport: "ONT", arrAirport: "SDF", depUTC: "2026-05-01T13:00:00Z", arrUTC: "2026-05-01T18:00:00Z"),
            makeLeg(leg: 2, flight: "201", depAirport: "SDF", arrAirport: "ONT", depUTC: "2026-05-01T23:00:00Z", arrUTC: "2026-05-02T03:00:00Z")
        ])]

        let matches = FriendScheduleMatchDetector.detect(
            mySchedules: mySchedules,
            friendSchedules: [(gemsID: "654321", schedules: friendSchedules)]
        )

        let overlapCount = matches.restOverlapsByArrivalLegID.values.flatMap { $0 }.count
        XCTAssertEqual(overlapCount, 1)
        XCTAssertEqual(matches.restOverlapsByArrivalLegID.values.flatMap { $0 }[0].overlapMinutes, 60)
    }

    func test_restOverlap_doesNotMatchBelowOneHour() {
        let mySchedules = [makeSchedule(legs: [
            makeLeg(leg: 1, flight: "100", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:00:00Z", arrUTC: "2026-05-01T10:00:00Z"),
            makeLeg(leg: 2, flight: "101", depAirport: "SDF", arrAirport: "ANC", depUTC: "2026-05-01T22:00:00Z", arrUTC: "2026-05-02T02:00:00Z")
        ])]
        let friendSchedules = [makeSchedule(legs: [
            makeLeg(leg: 1, flight: "200", depAirport: "ONT", arrAirport: "SDF", depUTC: "2026-05-01T13:01:00Z", arrUTC: "2026-05-01T18:01:00Z"),
            makeLeg(leg: 2, flight: "201", depAirport: "SDF", arrAirport: "ONT", depUTC: "2026-05-01T23:00:00Z", arrUTC: "2026-05-02T03:00:00Z")
        ])]

        let matches = FriendScheduleMatchDetector.detect(
            mySchedules: mySchedules,
            friendSchedules: [(gemsID: "654321", schedules: friendSchedules)]
        )

        XCTAssertTrue(matches.restOverlapsByArrivalLegID.isEmpty)
    }

    func test_flightMatch_allowsThirtyMinuteDepartureTolerance() {
        let myLegID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let mySchedules = [makeSchedule(legs: [
            makeLeg(id: myLegID, leg: 1, flight: "123", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:00:00Z", arrUTC: "2026-05-01T10:00:00Z")
        ])]
        let friendSchedules = [makeSchedule(legs: [
            makeLeg(leg: 1, flight: "5X123", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:30:00Z", arrUTC: "2026-05-01T10:30:00Z")
        ])]

        let matches = FriendScheduleMatchDetector.detect(
            mySchedules: mySchedules,
            friendSchedules: [(gemsID: "654321", schedules: friendSchedules)]
        )

        XCTAssertEqual(matches.flightMatchesByLegID[myLegID]?.count, 1)
    }

    func test_friendCloudKitRequest_usesOneRecordForBothDirections() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        let first = try await service.requestFriend(myGEMSID: "222222", friendGEMSID: "111111")
        let second = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")

        XCTAssertFalse(first.isAccepted)
        XCTAssertTrue(second.isAccepted)
        let recordNames = await database.friendLinkRecordNames()
        XCTAssertEqual(recordNames, ["tdh_friend_0111111_0222222"])
    }

    func test_friendCloudKitRequest_retriesRaceConflictAndAccepts() async throws {
        let database = FriendCloudKitFakeDatabase(conflictFirstFriendLinkSaveWithOtherApproval: true)
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        let link = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")

        XCTAssertTrue(link.isAccepted)
        let recordSnapshot = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        let record = try XCTUnwrap(recordSnapshot)
        XCTAssertEqual((record["approvedA"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((record["approvedB"] as? NSNumber)?.boolValue, true)
    }

    func test_friendCloudKitCancel_deletesSingleSidedPendingRequest() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        _ = try await service.requestFriend(myGEMSID: "222222", friendGEMSID: "111111")
        try await service.cancelFriendRequest(myGEMSID: "222222", friendGEMSID: "111111")

        let recordNames = await database.friendLinkRecordNames()
        XCTAssertTrue(recordNames.isEmpty)
    }

    func test_friendCloudKitCancel_preservesOtherPilotsApproval() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        _ = try await service.requestFriend(myGEMSID: "222222", friendGEMSID: "111111")
        _ = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")
        try await service.cancelFriendRequest(myGEMSID: "111111", friendGEMSID: "222222")

        let recordSnapshot = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        let record = try XCTUnwrap(recordSnapshot)
        XCTAssertEqual((record["approvedA"] as? NSNumber)?.boolValue, false)
        XCTAssertEqual((record["approvedB"] as? NSNumber)?.boolValue, true)
        XCTAssertNil(record["linkedAt"])
    }

    func test_refreshConnections_loadsFriendTimelineCardsFromSnapshot() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        _ = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")
        _ = try await service.requestFriend(myGEMSID: "222222", friendGEMSID: "111111")
        try await service.uploadScheduleSnapshot(
            gemsID: "222222",
            ownerDisplayName: "222222",
            crewAccessTrips: [makeCrewAccessTrip()]
        )

        let refreshed = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: [
                FriendConnection(employeeID: "222222", status: .pending)
            ]
        )

        XCTAssertEqual(refreshed.first?.status, .accepted)
        XCTAssertEqual(refreshed.first?.sharedTimelineCards.map(\.type), ["flight", "layover", "flight"])
        XCTAssertEqual(refreshed.first?.sharedTimelineCards[1].hotelName, "Test Hotel")
    }

    func test_refreshConnections_restoresAcceptedFriendLinksFromCloudWhenLocalCacheIsEmpty() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        _ = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")
        _ = try await service.requestFriend(myGEMSID: "222222", friendGEMSID: "111111")

        let refreshed = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: []
        )

        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.employeeID, "0222222")
        XCTAssertEqual(refreshed.first?.status, .accepted)
        XCTAssertNotNil(refreshed.first?.linkedAt)
    }

    func test_refreshConnections_keepsAcceptedStatusFromPersistedCloudStatus() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        await database.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: true,
            approvedB: false,
            status: "accepted",
            linkedAt: Date(timeIntervalSince1970: 10)
        )

        let refreshed = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: []
        )

        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.employeeID, "0222222")
        XCTAssertEqual(refreshed.first?.status, .accepted)
        XCTAssertEqual(refreshed.first?.linkedAt, Date(timeIntervalSince1970: 10))
    }

    private func makeSchedule(legs: [TripLeg]) -> PayPeriodSchedule {
        PayPeriodSchedule(
            id: "PP26-05",
            label: "PP26-05",
            tripCount: 1,
            legCount: legs.count,
            openTimeCount: 0,
            updatedAt: Date(timeIntervalSince1970: 0),
            legs: legs,
            openTimeTrips: []
        )
    }

    private func makeLeg(
        id: UUID = UUID(),
        leg: Int,
        flight: String,
        depAirport: String,
        arrAirport: String,
        depUTC: String,
        arrUTC: String
    ) -> TripLeg {
        TripLeg(
            id: id,
            payPeriod: "PP26-05",
            pairing: "A123",
            leg: leg,
            flight: flight,
            depAirport: depAirport,
            depLocal: depUTC.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: ":00Z", with: ""),
            arrAirport: arrAirport,
            arrLocal: arrUTC.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: ":00Z", with: ""),
            depUTC: depUTC,
            arrUTC: arrUTC,
            status: "-",
            block: "4:00"
        )
    }

    private func iso(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func makeCrewAccessTrip() -> CrewAccessTripJSON {
        CrewAccessTripJSON(
            schemaVersion: 1,
            source: "crewaccess-pdf",
            sourceVersion: "test",
            mappingVersion: "test",
            generatedAt: "2026-05-04T00:00:00Z",
            tripId: "A70628",
            tripInformationDate: "2026-04-27",
            creditTime: "15:00",
            tripDays: "2",
            tafb: "36:00",
            dutyTotals: ["Duty 1 Time 12:30 Block 9:00 Rest 24:00"],
            hotelDetails: ["Hotel details SDF: Test Hotel / +1 555 0100"],
            crew: [],
            items: [
                makeCrewAccessItem(
                    sequence: 1,
                    flight: "5X100",
                    depAirport: "ANC",
                    arrAirport: "SDF",
                    startUTC: "2026-04-27T07:24:00Z",
                    endUTC: "2026-04-27T19:45:00Z"
                ),
                makeCrewAccessItem(
                    sequence: 2,
                    flight: "5X101",
                    depAirport: "SDF",
                    arrAirport: "ONT",
                    startUTC: "2026-04-28T21:45:00Z",
                    endUTC: "2026-04-29T00:15:00Z"
                )
            ]
        )
    }

    private func makeCrewAccessItem(
        sequence: Int,
        flight: String,
        depAirport: String,
        arrAirport: String,
        startUTC: String,
        endUTC: String
    ) -> CrewAccessTripItemJSON {
        CrewAccessTripItemJSON(
            sequence: sequence,
            depAirport: depAirport,
            arrAirport: arrAirport,
            deadhead: false,
            flight: flight,
            startUtc: startUTC,
            endUtc: endUTC,
            startLocalDisplay: startUTC,
            endLocalDisplay: endUTC,
            originTz: "America/Anchorage",
            destinationTz: "America/New_York",
            timeDerivation: "pdf",
            aircraft: "747",
            block: "4:00",
            stdUtc: startUTC,
            staUtc: endUTC,
            atdUtc: nil,
            ataUtc: nil,
            tailNumber: nil
        )
    }
}

private actor FriendCloudKitFakeDatabase: FriendScheduleCloudKitDatabase {
    private var records: [String: CKRecord] = [:]
    private var conflictFirstFriendLinkSaveWithOtherApproval: Bool

    init(conflictFirstFriendLinkSaveWithOtherApproval: Bool = false) {
        self.conflictFirstFriendLinkSaveWithOtherApproval = conflictFirstFriendLinkSaveWithOtherApproval
    }

    func record(for recordID: CKRecord.ID) async throws -> CKRecord {
        guard let record = records[recordID.recordName] else {
            throw CKError(.unknownItem)
        }
        return record
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        let recordName = record.recordID.recordName
        if conflictFirstFriendLinkSaveWithOtherApproval,
           recordName.hasPrefix("tdh_friend_") {
            conflictFirstFriendLinkSaveWithOtherApproval = false
            let serverRecord = CKRecord(recordType: "TDHFriendLink", recordID: record.recordID)
            serverRecord["gemsA"] = "0111111" as CKRecordValue
            serverRecord["gemsB"] = "0222222" as CKRecordValue
            serverRecord["approvedB"] = true as CKRecordValue
            records[recordName] = serverRecord
            throw CKError(.serverRecordChanged)
        }

        records[recordName] = record
        return record
    }

    func deleteRecord(withID recordID: CKRecord.ID) async throws -> CKRecord.ID {
        guard records.removeValue(forKey: recordID.recordName) != nil else {
            throw CKError(.unknownItem)
        }
        return recordID
    }

    func records(matching query: CKQuery) async throws -> [CKRecord] {
        records.values.filter { record in
            guard record.recordType == query.recordType else { return false }
            guard let comparison = query.predicate as? NSComparisonPredicate,
                  comparison.leftExpression.expressionType == .keyPath,
                  comparison.rightExpression.expressionType == .constantValue,
                  let expected = comparison.rightExpression.constantValue as? String
            else { return true }
            let field = comparison.leftExpression.keyPath
            return record[field] as? String == expected
        }
    }

    func insertFriendLink(
        gemsA: String,
        gemsB: String,
        approvedA: Bool,
        approvedB: Bool,
        status: String?,
        linkedAt: Date?
    ) {
        let recordID = CKRecord.ID(recordName: "tdh_friend_\(gemsA)_\(gemsB)")
        let record = CKRecord(recordType: "TDHFriendLink", recordID: recordID)
        record["gemsA"] = gemsA as CKRecordValue
        record["gemsB"] = gemsB as CKRecordValue
        record["approvedA"] = approvedA as CKRecordValue
        record["approvedB"] = approvedB as CKRecordValue
        if let status {
            record["status"] = status as CKRecordValue
        }
        if let linkedAt {
            record["linkedAt"] = linkedAt as CKRecordValue
        }
        records[recordID.recordName] = record
    }

    func friendLinkRecordNames() -> [String] {
        records.keys
            .filter { $0.hasPrefix("tdh_friend_") }
            .sorted()
    }

    func recordSnapshot(named recordName: String) -> CKRecord? {
        records[recordName]
    }
}
