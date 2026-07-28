import CloudKit
import XCTest
@testable import TripDataHub

final class FriendScheduleMatchingTests: XCTestCase {
    func test_restWindow_usesDutyEndAndNextDutyStart() {
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
        XCTAssertEqual(snapshot.restWindows[0].startUTC, iso("2026-05-01T10:30:00Z"))
        XCTAssertEqual(snapshot.restWindows[0].endUTC, iso("2026-05-01T20:30:00Z"))
        XCTAssertEqual(snapshot.restWindows[0].durationMinutes, 600)
    }

    func test_restWindow_usesSixtyMinuteReportForLower48Flight() {
        let arrivalLeg = makeLeg(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            leg: 1,
            flight: "100",
            depAirport: "ANC",
            arrAirport: "SDF",
            depUTC: "2026-05-01T06:00:00Z",
            arrUTC: "2026-05-01T10:00:00Z"
        )
        let departureLeg = makeLeg(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            leg: 2,
            flight: "101",
            depAirport: "SDF",
            arrAirport: "ONT",
            depUTC: "2026-05-01T22:00:00Z",
            arrUTC: "2026-05-02T02:00:00Z"
        )

        let snapshot = SharedScheduleExporter.snapshot(
            ownerGEMSID: "123456",
            schedules: [makeSchedule(legs: [arrivalLeg, departureLeg])]
        )

        XCTAssertEqual(snapshot.restWindows.count, 1)
        XCTAssertEqual(snapshot.restWindows[0].station, "SDF")
        XCTAssertEqual(snapshot.restWindows[0].startUTC, iso("2026-05-01T10:30:00Z"))
        XCTAssertEqual(snapshot.restWindows[0].endUTC, iso("2026-05-01T21:00:00Z"))
        XCTAssertEqual(snapshot.restWindows[0].durationMinutes, 630)
    }

    func test_timelineRestInfo_usesSixtyMinuteReportForAsiaAndEuropeFlights() {
        let arrDate = iso("2026-05-01T10:00:00Z")
        let asiaLeg = makeLeg(
            leg: 2,
            flight: "101",
            depAirport: "HKG",
            arrAirport: "ICN",
            depUTC: "2026-05-01T22:00:00Z",
            arrUTC: "2026-05-02T02:00:00Z"
        )
        let europeLeg = makeLeg(
            leg: 2,
            flight: "102",
            depAirport: "CGN",
            arrAirport: "CDG",
            depUTC: "2026-05-01T22:00:00Z",
            arrUTC: "2026-05-02T02:00:00Z"
        )

        let asiaInfo = TimelineLayoverSupport.restInfo(arrDate: arrDate, nextLeg: asiaLeg)
        let europeInfo = TimelineLayoverSupport.restInfo(arrDate: arrDate, nextLeg: europeLeg)

        XCTAssertEqual(asiaInfo?.dutyEndUTC, iso("2026-05-01T10:30:00Z"))
        XCTAssertEqual(asiaInfo?.dutyStartUTC, iso("2026-05-01T21:00:00Z"))
        XCTAssertEqual(asiaInfo?.totalMinutes, 630)
        XCTAssertEqual(europeInfo?.dutyStartUTC, iso("2026-05-01T21:00:00Z"))
        XCTAssertEqual(europeInfo?.totalMinutes, 630)
    }

    func test_timelineRestInfo_usesNinetyMinuteReportWhenFlightLeavesReducedReportRegion() {
        let nextLeg = makeLeg(
            leg: 2,
            flight: "101",
            depAirport: "HKG",
            arrAirport: "ANC",
            depUTC: "2026-05-01T22:00:00Z",
            arrUTC: "2026-05-02T02:00:00Z"
        )

        let info = TimelineLayoverSupport.restInfo(
            arrDate: iso("2026-05-01T10:00:00Z"),
            nextLeg: nextLeg
        )

        XCTAssertEqual(info?.dutyEndUTC, iso("2026-05-01T10:30:00Z"))
        XCTAssertEqual(info?.dutyStartUTC, iso("2026-05-01T20:30:00Z"))
        XCTAssertEqual(info?.totalMinutes, 600)
    }

    func test_timelineRestInfo_remainingAndPastUseDutyStart() {
        let nextLeg = makeLeg(
            leg: 2,
            flight: "101",
            depAirport: "SDF",
            arrAirport: "ONT",
            depUTC: "2026-05-01T22:00:00Z",
            arrUTC: "2026-05-02T02:00:00Z"
        )
        let arrDate = iso("2026-05-01T10:00:00Z")

        XCTAssertEqual(
            TimelineLayoverSupport.remainingText(
                arrDate: arrDate,
                nextLeg: nextLeg,
                now: iso("2026-05-01T20:00:00Z")
            ),
            "1:00"
        )
        XCTAssertFalse(
            TimelineLayoverSupport.isPastLayover(
                arrDate: arrDate,
                nextLeg: nextLeg,
                now: iso("2026-05-01T20:59:00Z")
            )
        )
        XCTAssertTrue(
            TimelineLayoverSupport.isPastLayover(
                arrDate: arrDate,
                nextLeg: nextLeg,
                now: iso("2026-05-01T21:01:00Z")
            )
        )
    }

    func test_friendConnectionDisplayName_trimsNicknameAndFallsBackToEmployeeID() {
        XCTAssertEqual(
            FriendConnection(employeeID: "0554744", nickname: " James ", status: .accepted).displayName,
            "James"
        )
        XCTAssertEqual(
            FriendConnection(employeeID: "0554744", nickname: "   ", status: .accepted).displayName,
            "0554744"
        )
        XCTAssertEqual(
            FriendConnection(employeeID: "0554744", nickname: nil, status: .accepted).displayName,
            "0554744"
        )
    }

    func test_friendConnectionCodable_preservesNicknameAcrossPersistenceRoundTrip() throws {
        let connection = FriendConnection(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            employeeID: "0554744",
            nickname: "James",
            status: .accepted,
            requestedAt: Date(timeIntervalSince1970: 10),
            linkedAt: Date(timeIntervalSince1970: 20)
        )

        let data = try JSONEncoder().encode([connection])
        let decoded = try JSONDecoder().decode([FriendConnection].self, from: data)

        XCTAssertEqual(decoded.first?.nickname, "James")
        XCTAssertEqual(decoded.first?.displayName, "James")
    }

    func test_restOverlap_matchesAtOneHour() {
        let mySchedules = [makeSchedule(legs: [
            makeLeg(leg: 1, flight: "100", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:00:00Z", arrUTC: "2026-05-01T10:00:00Z"),
            makeLeg(leg: 2, flight: "101", depAirport: "SDF", arrAirport: "ANC", depUTC: "2026-05-01T22:00:00Z", arrUTC: "2026-05-02T02:00:00Z")
        ])]
        let friendSchedules = [makeSchedule(legs: [
            makeLeg(leg: 1, flight: "200", depAirport: "ONT", arrAirport: "SDF", depUTC: "2026-05-01T13:00:00Z", arrUTC: "2026-05-01T19:00:00Z"),
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
            makeLeg(leg: 1, flight: "200", depAirport: "ONT", arrAirport: "SDF", depUTC: "2026-05-01T13:01:00Z", arrUTC: "2026-05-01T19:31:00Z"),
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

    func test_normalizedFlightNumber_preservesAirlinePrefixAndAddsCompanyPrefixToDigits() {
        XCTAssertEqual(SharedScheduleExporter.normalizedFlightNumber("XX003"), "XX003")
        XCTAssertEqual(SharedScheduleExporter.normalizedFlightNumber("003"), "5X003")
        XCTAssertEqual(SharedScheduleExporter.normalizedFlightNumber("5X003"), "5X003")
        XCTAssertEqual(SharedScheduleExporter.normalizedFlightNumber("UA123"), "UA123")
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
        let recordSnapshot = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        let record = try XCTUnwrap(recordSnapshot)
        XCTAssertEqual(record["requesterGEMSID"] as? String, "0222222")
        XCTAssertEqual(record["recipientGEMSID"] as? String, "0111111")
    }

    func test_friendCloudKitRequest_existingAcceptedLinkReturnsWithoutResave() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        _ = try await service.requestFriend(myGEMSID: "222222", friendGEMSID: "111111")
        _ = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")
        let savesBeforeDuplicateRequest = await database.saveCount()

        let link = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")

        XCTAssertTrue(link.isAccepted)
        let savesAfterDuplicateRequest = await database.saveCount()
        XCTAssertEqual(savesAfterDuplicateRequest, savesBeforeDuplicateRequest)
    }

    func test_friendCloudKitRequest_existingAcceptedLinkAfterResetRequiresResave() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        _ = try await service.requestFriend(myGEMSID: "222222", friendGEMSID: "111111")
        _ = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")
        let savesBeforeDuplicateRequest = await database.saveCount()

        let link = try await service.requestFriend(
            myGEMSID: "111111",
            friendGEMSID: "222222",
            friendResetAt: Date().addingTimeInterval(60)
        )

        XCTAssertTrue(link.isAccepted)
        let savesAfterDuplicateRequest = await database.saveCount()
        XCTAssertGreaterThan(savesAfterDuplicateRequest, savesBeforeDuplicateRequest)
        let recordSnapshot = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        let record = try XCTUnwrap(recordSnapshot)
        XCTAssertEqual(record["status"] as? String, "accepted")
        XCTAssertEqual((record["approvedA"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((record["approvedB"] as? NSNumber)?.boolValue, true)
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

    func test_friendCloudKitRequest_permissionFailureCreatesUserOwnedAcceptedLink() async throws {
        let database = FriendCloudKitFakeDatabase(denyCanonicalFriendLinkUpdates: true)
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        _ = try await service.requestFriend(myGEMSID: "222222", friendGEMSID: "111111")
        let link = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")

        XCTAssertTrue(link.isAccepted)
        let userOwnedRecord = await database.recordSnapshot(named: "tdh_friend_user_0111111_0222222")
        let record = try XCTUnwrap(userOwnedRecord)
        XCTAssertEqual(record["status"] as? String, "accepted")
        XCTAssertEqual((record["approvedA"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((record["approvedB"] as? NSNumber)?.boolValue, true)

        let splitDatabase = FriendCloudKitFakeDatabase()
        let splitService = FriendScheduleCloudKitService(databaseProvider: { splitDatabase })
        await splitDatabase.insertFriendLink(
            recordName: "tdh_friend_0111111_0222222",
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: true,
            approvedB: false,
            status: "pending",
            linkedAt: nil
        )
        await splitDatabase.insertFriendLink(
            recordName: "tdh_friend_user_0222222_0111111",
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: false,
            approvedB: true,
            status: "pending",
            linkedAt: nil
        )

        let splitLink = try await splitService.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")

        XCTAssertTrue(splitLink.isAccepted)
        let splitRecordSnapshot = await splitDatabase.recordSnapshot(named: "tdh_friend_0111111_0222222")
        let splitRecord = try XCTUnwrap(splitRecordSnapshot)
        XCTAssertEqual(splitRecord["status"] as? String, "accepted")
        XCTAssertEqual((splitRecord["approvedA"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((splitRecord["approvedB"] as? NSNumber)?.boolValue, true)
        XCTAssertNotNil(splitRecord["linkedAt"])
    }

    func test_friendCloudKitRefresh_mergesUserOwnedAcceptedLink() async throws {
        let database = FriendCloudKitFakeDatabase(denyCanonicalFriendLinkUpdates: true)
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        _ = try await service.requestFriend(myGEMSID: "222222", friendGEMSID: "111111")
        _ = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")

        let refreshed = try await service.refreshConnections(myGEMSID: "222222", connections: []).connections

        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.employeeID, "0111111")
        XCTAssertEqual(refreshed.first?.status, .accepted)
    }

    func test_friendCloudKitCancel_marksSingleSidedPendingRequestCanceled() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        _ = try await service.requestFriend(myGEMSID: "222222", friendGEMSID: "111111")
        try await service.cancelFriendRequest(myGEMSID: "222222", friendGEMSID: "111111")

        let recordSnapshot = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        let record = try XCTUnwrap(recordSnapshot)
        XCTAssertEqual(record["status"] as? String, "canceled")
        XCTAssertNil(record["linkedAt"])
    }

    func test_friendCloudKitCancel_clearsBothApprovalBits() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        _ = try await service.requestFriend(myGEMSID: "222222", friendGEMSID: "111111")
        _ = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")
        try await service.cancelFriendRequest(myGEMSID: "111111", friendGEMSID: "222222")

        let recordSnapshot = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        let record = try XCTUnwrap(recordSnapshot)
        XCTAssertEqual((record["approvedA"] as? NSNumber)?.boolValue, false)
        XCTAssertEqual((record["approvedB"] as? NSNumber)?.boolValue, false)
        XCTAssertEqual(record["status"] as? String, "canceled")
        XCTAssertNil(record["linkedAt"])
    }

    func test_friendCloudKitRequest_afterCancelRevivesAsPendingWithoutGhostApproval() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        _ = try await service.requestFriend(myGEMSID: "222222", friendGEMSID: "111111")
        _ = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")
        await database.insertFriendLink(
            recordName: "tdh_friend_user_0222222_0111111",
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: false,
            approvedB: true,
            status: "pending",
            linkedAt: nil
        )
        try await service.cancelFriendRequest(myGEMSID: "111111", friendGEMSID: "222222")
        let deletedUserOwnedRecord = await database.recordSnapshot(named: "tdh_friend_user_0222222_0111111")
        XCTAssertNil(deletedUserOwnedRecord)

        let link = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")

        XCTAssertFalse(link.isAccepted)
        XCTAssertNil(link.linkedAt)
        let recordSnapshot = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        let record = try XCTUnwrap(recordSnapshot)
        XCTAssertEqual((record["approvedA"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((record["approvedB"] as? NSNumber)?.boolValue, false)
        XCTAssertEqual(record["status"] as? String, "pending")
        XCTAssertNil(record["linkedAt"])
    }

    func test_refreshConnections_treatsCanceledLinkWithStaleLinkedAtAsPending() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        await database.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: true,
            approvedB: true,
            status: "canceled",
            linkedAt: Date(timeIntervalSince1970: 10)
        )

        let refreshed = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: []
        ).connections

        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.status, .pending)
        XCTAssertNil(refreshed.first?.linkedAt)
        XCTAssertNil(refreshed.first?.acceptedAt)
    }

    func test_refreshConnections_preservesAcceptedLocalConnectionWhenCloudLinkMissingWithoutAcceptedAt() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        var local = FriendConnection(
            employeeID: "222222",
            status: .accepted,
            requestedAt: Date(timeIntervalSince1970: 1),
            linkedAt: nil
        )
        local.acceptedAt = nil

        let refreshed = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: [local]
        ).connections

        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.status, .accepted)
        XCTAssertEqual(refreshed.first?.linkedAt, Date(timeIntervalSince1970: 1))
        let migratedRecord = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        XCTAssertEqual(migratedRecord?["status"] as? String, "accepted")
        XCTAssertEqual(migratedRecord?["linkedAt"] as? Date, Date(timeIntervalSince1970: 1))
    }

    func test_refreshConnections_doesNotForceAcceptExistingPendingLinkFromLocalAcceptedAt() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        await database.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: false,
            approvedB: false,
            status: "pending",
            linkedAt: nil
        )
        let local = FriendConnection(
            employeeID: "222222",
            status: .accepted,
            requestedAt: Date(timeIntervalSince1970: 1),
            linkedAt: Date(timeIntervalSince1970: 2),
            acceptedAt: Date(timeIntervalSince1970: 2)
        )

        let refreshed = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: [local]
        ).connections

        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.status, .pending)
        let record = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        XCTAssertEqual(record?["status"] as? String, "pending")
        XCTAssertNil(record?["linkedAt"])
    }

    func test_friendCloudKitRequest_keepsOriginalRequestedAtWhenHealedLater() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        let first = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")
        let originalRequestedAt = try XCTUnwrap(first.requestedAt)
        let recordSnapshot = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        let record = try XCTUnwrap(recordSnapshot)
        record["updatedAt"] = originalRequestedAt.addingTimeInterval(60) as CKRecordValue
        _ = try await database.save(record)

        let second = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")

        XCTAssertEqual(second.requestedAt, originalRequestedAt)
    }

    func test_friendCloudKitUploadSchedule_doesNotPersistOwnerRecordName() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        try await service.uploadSchedule(
            gemsID: "111111",
            cloudKitRecordName: "_internal_cloudkit_record",
            schedules: [makeSchedule(legs: [])]
        )

        let record = await database.recordSnapshot(named: "tdh_schedule_0111111")
        XCTAssertNotNil(record)
        XCTAssertNil(record?["ownerRecordName"])
        XCTAssertEqual(record?["ownerGEMSID"] as? String, "0111111")
    }

    /// "Last Updated" in FriendsTabView is derived from the record's modification date, and this
    /// method runs on every app open. Re-saving identical content would advance that timestamp
    /// against unchanged schedules — the exact symptom seen on device.
    func test_friendCloudKitUploadSchedule_skipsSaveWhenContentIsUnchanged() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        let schedules = [makeSchedule(legs: [makeLeg(leg: 1, flight: "100", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:00:00Z", arrUTC: "2026-05-01T10:00:00Z")])]

        try await service.uploadSchedule(gemsID: "111111", cloudKitRecordName: "_rec", schedules: schedules)
        let savesAfterFirst = await database.saveCount()

        try await service.uploadSchedule(gemsID: "111111", cloudKitRecordName: "_rec", schedules: schedules)
        try await service.uploadSchedule(gemsID: "111111", cloudKitRecordName: "_rec", schedules: schedules)
        let savesAfterRepeats = await database.saveCount()

        XCTAssertEqual(savesAfterFirst, 1)
        XCTAssertEqual(savesAfterRepeats, 1, "identical content must not be republished")
    }

    func test_friendCloudKitUploadSchedule_savesWhenContentChanges() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        let first = [makeSchedule(legs: [makeLeg(leg: 1, flight: "100", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:00:00Z", arrUTC: "2026-05-01T10:00:00Z")])]
        let second = [makeSchedule(legs: [makeLeg(leg: 1, flight: "999", depAirport: "ANC", arrAirport: "NRT", depUTC: "2026-06-01T06:00:00Z", arrUTC: "2026-06-01T16:00:00Z")])]

        try await service.uploadSchedule(gemsID: "111111", cloudKitRecordName: "_rec", schedules: first)
        try await service.uploadSchedule(gemsID: "111111", cloudKitRecordName: "_rec", schedules: second)

        let saveCount = await database.saveCount()
        XCTAssertEqual(saveCount, 2)

        let snapshot = await database.recordSnapshot(named: "tdh_schedule_0111111")
        let record = try XCTUnwrap(snapshot)
        let data = try XCTUnwrap(record["schedulesData"] as? Data)
        let decoded = try JSONDecoder().decode([PayPeriodSchedule].self, from: data)
        XCTAssertEqual(decoded.flatMap { $0.legs.map(\.flight) }, ["999"])
    }

    func test_friendCloudKitUploadSchedule_allowsEmptyScheduleToClearRemoteData() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        try await service.uploadSchedule(
            gemsID: "111111",
            cloudKitRecordName: "_internal_cloudkit_record",
            schedules: [makeSchedule(legs: [makeLeg(leg: 1, flight: "100", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:00:00Z", arrUTC: "2026-05-01T10:00:00Z")])]
        )
        try await service.uploadSchedule(
            gemsID: "111111",
            cloudKitRecordName: "_internal_cloudkit_record",
            schedules: []
        )

        let recordSnapshot = await database.recordSnapshot(named: "tdh_schedule_0111111")
        let record = try XCTUnwrap(recordSnapshot)
        let data = try XCTUnwrap(record["schedulesData"] as? Data)
        let schedules = try JSONDecoder().decode([PayPeriodSchedule].self, from: data)
        XCTAssertTrue(schedules.isEmpty)
    }

    func test_deleteSharedScheduleData_removesScheduleAndSnapshotRecords() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        try await service.uploadSchedule(
            gemsID: "111111",
            cloudKitRecordName: "_internal_cloudkit_record",
            schedules: [makeSchedule(legs: [])]
        )
        try await service.uploadScheduleSnapshot(
            gemsID: "111111",
            ownerDisplayName: "Test Pilot",
            crewAccessTrips: []
        )

        try await service.deleteSharedScheduleData(gemsID: "111111")

        let scheduleRecord = await database.recordSnapshot(named: "tdh_schedule_0111111")
        let snapshotRecord = await database.recordSnapshot(named: "tdh_snapshot_0111111")
        XCTAssertNil(scheduleRecord)
        XCTAssertNil(snapshotRecord)
    }

    func test_deleteFriendSharingData_removesOwnApprovalAndDeletesSharedScheduleData() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        await database.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: true,
            approvedB: true,
            status: "accepted",
            linkedAt: Date(timeIntervalSince1970: 2)
        )
        await database.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0333333",
            approvedA: true,
            approvedB: true,
            status: "accepted",
            linkedAt: Date(timeIntervalSince1970: 3)
        )
        try await service.uploadSchedule(
            gemsID: "111111",
            cloudKitRecordName: "_internal_cloudkit_record",
            schedules: [makeSchedule(legs: [])]
        )
        try await service.uploadScheduleSnapshot(
            gemsID: "111111",
            ownerDisplayName: "Test Pilot",
            crewAccessTrips: []
        )

        try await service.deleteFriendSharingData(gemsID: "111111")

        let firstRecord = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        let first = try XCTUnwrap(firstRecord)
        XCTAssertEqual(first["status"] as? String, "pending")
        XCTAssertEqual((first["approvedA"] as? NSNumber)?.boolValue, false)
        XCTAssertEqual((first["approvedB"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual(first["requesterGEMSID"] as? String, "0222222")
        XCTAssertEqual(first["recipientGEMSID"] as? String, "0111111")
        XCTAssertNil(first["linkedAt"])
        let secondRecord = await database.recordSnapshot(named: "tdh_friend_0111111_0333333")
        let second = try XCTUnwrap(secondRecord)
        XCTAssertEqual(second["status"] as? String, "pending")
        let scheduleRecord = await database.recordSnapshot(named: "tdh_schedule_0111111")
        let snapshotRecord = await database.recordSnapshot(named: "tdh_snapshot_0111111")
        XCTAssertNil(scheduleRecord)
        XCTAssertNil(snapshotRecord)
    }

    func test_requestFriend_afterAccountDeleteRestoresWhenOtherApprovalRemains() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        await database.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: true,
            approvedB: true,
            status: "accepted",
            linkedAt: Date(timeIntervalSince1970: 2)
        )

        try await service.deleteFriendSharingData(gemsID: "111111")
        let link = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")

        XCTAssertTrue(link.isAccepted)
        let recordSnapshot = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        let record = try XCTUnwrap(recordSnapshot)
        XCTAssertEqual(record["status"] as? String, "accepted")
        XCTAssertEqual((record["approvedA"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((record["approvedB"] as? NSNumber)?.boolValue, true)

        let resetDatabase = FriendCloudKitFakeDatabase()
        let resetService = FriendScheduleCloudKitService(databaseProvider: { resetDatabase })
        let oldDate = Date(timeIntervalSince1970: 10)
        let resetAt = Date(timeIntervalSince1970: 20)
        await resetDatabase.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: true,
            approvedB: false,
            status: "pending",
            linkedAt: nil,
            requestedAt: oldDate
        )
        await resetDatabase.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0333333",
            approvedA: false,
            approvedB: true,
            status: "pending",
            linkedAt: nil,
            requestedAt: oldDate
        )

        let refreshed = try await resetService.refreshConnections(
            myGEMSID: "111111",
            connections: [],
            friendResetAt: resetAt
        ).connections

        XCTAssertEqual(refreshed.map(\.employeeID), ["0333333"])
        XCTAssertEqual(refreshed.first?.status, .pending)
        XCTAssertEqual(refreshed.first?.requestDirection, .incoming)

        let staleRequestDatabase = FriendCloudKitFakeDatabase()
        let staleRequestService = FriendScheduleCloudKitService(databaseProvider: { staleRequestDatabase })
        await staleRequestDatabase.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: true,
            approvedB: false,
            status: "pending",
            linkedAt: nil,
            requestedAt: oldDate
        )

        let restartedLink = try await staleRequestService.requestFriend(
            myGEMSID: "111111",
            friendGEMSID: "222222",
            friendResetAt: resetAt
        )

        XCTAssertFalse(restartedLink.isAccepted)
        XCTAssertEqual(restartedLink.requestDirection, .outgoing)
        XCTAssertNotEqual(restartedLink.requestedAt, oldDate)
        let staleRecordSnapshot = await staleRequestDatabase.recordSnapshot(named: "tdh_friend_0111111_0222222")
        let staleRecord = try XCTUnwrap(staleRecordSnapshot)
        XCTAssertEqual(staleRecord["status"] as? String, "pending")
        XCTAssertEqual((staleRecord["approvedA"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((staleRecord["approvedB"] as? NSNumber)?.boolValue, false)
        XCTAssertEqual(staleRecord["requesterGEMSID"] as? String, "0111111")
        XCTAssertEqual(staleRecord["recipientGEMSID"] as? String, "0222222")
    }

    func test_refreshConnections_dropsAcceptedCloudLinkWhenOlderThanLocalReset() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        let linkedAt = Date(timeIntervalSince1970: 10)
        let resetAt = Date(timeIntervalSince1970: 20)
        await database.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: true,
            approvedB: true,
            status: "accepted",
            linkedAt: linkedAt,
            requestedAt: linkedAt
        )

        let refreshed = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: [],
            friendResetAt: resetAt
        ).connections

        XCTAssertTrue(refreshed.isEmpty)
    }

    func test_refreshConnections_restoresAcceptedConnectionWhenFriendLinkMissing() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        let local = FriendConnection(
            employeeID: "222222",
            status: .accepted,
            requestedAt: Date(timeIntervalSince1970: 1),
            linkedAt: Date(timeIntervalSince1970: 2),
            sharedSchedules: [makeSchedule(legs: [makeLeg(leg: 1, flight: "100", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:00:00Z", arrUTC: "2026-05-01T10:00:00Z")])]
        )

        let refreshed = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: [local]
        ).connections

        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.status, .accepted)
        XCTAssertEqual(refreshed.first?.linkedAt, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(refreshed.first?.acceptedAt, Date(timeIntervalSince1970: 2))
        XCTAssertFalse(refreshed.first?.sharedSchedules.isEmpty == true)

        let migratedRecord = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        XCTAssertEqual(migratedRecord?["gemsA"] as? String, "0111111")
        XCTAssertEqual(migratedRecord?["gemsB"] as? String, "0222222")
        XCTAssertEqual(migratedRecord?["approvedA"] as? Bool, true)
        XCTAssertEqual(migratedRecord?["approvedB"] as? Bool, true)
        XCTAssertEqual(migratedRecord?["status"] as? String, "accepted")
    }

    func test_refreshConnections_doesNotRestoreAcceptedConnectionOlderThanReset() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        let local = FriendConnection(
            employeeID: "222222",
            status: .accepted,
            requestedAt: Date(timeIntervalSince1970: 1),
            linkedAt: Date(timeIntervalSince1970: 2),
            acceptedAt: Date(timeIntervalSince1970: 2)
        )

        let refreshed = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: [local],
            friendResetAt: Date(timeIntervalSince1970: 3)
        ).connections

        XCTAssertEqual(refreshed.first?.status, .accepted)
        let migratedRecord = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        XCTAssertNil(migratedRecord)
    }

    func test_cancelFriendRequest_createsCancellationWhenCanonicalLinkIsMissing() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        try await service.cancelFriendRequest(myGEMSID: "111111", friendGEMSID: "222222")

        let record = await database.recordSnapshot(named: "tdh_friend_0111111_0222222")
        XCTAssertEqual(record?["status"] as? String, "canceled")
        XCTAssertEqual(record?["approvedA"] as? Bool, false)
        XCTAssertEqual(record?["approvedB"] as? Bool, false)
    }

    /// A missing Queryable index on gemsA/gemsB in Production made the link query throw, which
    /// aborted the whole refresh and left every friend showing cached data. Known friends are
    /// fetched by record ID and need no index, so they must still refresh.
    func test_refreshConnections_degradesToRecordIDFetchWhenLinkQueryFails() async throws {
        let database = FriendCloudKitFakeDatabase()
        await database.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: true,
            approvedB: true,
            status: "accepted",
            linkedAt: Date(timeIntervalSince1970: 1000)
        )
        await database.failQueries()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        let refreshed = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: [FriendConnection(employeeID: "0222222", status: .pending)]
        ).connections

        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(
            refreshed.first?.status,
            .accepted,
            "a known friend must still refresh by record ID when the discovery query fails"
        )
    }

    func test_refreshConnections_preservesOnlyFailedFriendAndKeepsOtherResults() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        let failed = FriendConnection(
            employeeID: "222222",
            status: .accepted,
            requestedAt: Date(timeIntervalSince1970: 1),
            linkedAt: Date(timeIntervalSince1970: 2)
        )
        let succeeds = FriendConnection(
            employeeID: "333333",
            status: .accepted,
            requestedAt: Date(timeIntervalSince1970: 1),
            linkedAt: Date(timeIntervalSince1970: 2)
        )
        await database.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0333333",
            approvedA: false,
            approvedB: false,
            status: "canceled",
            linkedAt: nil
        )
        await database.failRecordFetch(named: "tdh_friend_0111111_0222222")

        let refreshed = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: [failed, succeeds]
        ).connections

        XCTAssertEqual(refreshed.first(where: { $0.employeeID == "0222222" })?.status, .accepted)
        XCTAssertEqual(refreshed.first(where: { $0.employeeID == "0333333" })?.status, .pending)
    }

    func test_refreshConnections_reportsScheduleFetchFailureAndPreservesCachedFriend() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        let cachedSchedule = makeSchedule(legs: [
            makeLeg(
                leg: 1,
                flight: "100",
                depAirport: "ANC",
                arrAirport: "SDF",
                depUTC: "2026-05-01T06:00:00Z",
                arrUTC: "2026-05-01T10:00:00Z"
            )
        ])
        let cached = FriendConnection(
            employeeID: "0222222",
            status: .pending,
            requestedAt: Date(timeIntervalSince1970: 1),
            sharedSchedules: [cachedSchedule]
        )
        await database.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: true,
            approvedB: true,
            status: "accepted",
            linkedAt: Date(timeIntervalSince1970: 2)
        )
        await database.failRecordFetch(named: "tdh_schedule_0222222")

        let result = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: [cached]
        )

        XCTAssertEqual(result.connections.first?.sharedSchedules, [cachedSchedule])
        XCTAssertEqual(result.connections.first?.status, .accepted)
        XCTAssertEqual(result.connections.first?.linkedAt, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(result.outcomes["0222222"], .failed(.fetchError))
    }

    func test_refreshConnections_preservesCachedScheduleWhenAcceptedFriendHasNoScheduleRecord() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        let cachedSchedule = makeSchedule(legs: [
            makeLeg(
                leg: 1,
                flight: "100",
                depAirport: "ANC",
                arrAirport: "SDF",
                depUTC: "2026-05-01T06:00:00Z",
                arrUTC: "2026-05-01T10:00:00Z"
            )
        ])
        let cached = FriendConnection(
            employeeID: "0222222",
            status: .accepted,
            requestedAt: Date(timeIntervalSince1970: 1),
            linkedAt: Date(timeIntervalSince1970: 2),
            sharedSchedules: [cachedSchedule]
        )
        await database.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: true,
            approvedB: true,
            status: "accepted",
            linkedAt: Date(timeIntervalSince1970: 2)
        )

        let result = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: [cached]
        )

        XCTAssertEqual(result.connections.first?.sharedSchedules, [cachedSchedule])
        XCTAssertEqual(result.connections.first?.status, .accepted)
        XCTAssertEqual(result.outcomes["0222222"], .succeeded)
    }

    func test_refreshConnections_clearsSharedSchedulesWhenFriendLinkIsCanceled() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        await database.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: true,
            approvedB: false,
            status: "canceled",
            linkedAt: nil
        )
        let local = FriendConnection(
            employeeID: "222222",
            status: .accepted,
            requestedAt: Date(timeIntervalSince1970: 1),
            linkedAt: Date(timeIntervalSince1970: 2),
            sharedSchedules: [makeSchedule(legs: [makeLeg(leg: 1, flight: "100", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:00:00Z", arrUTC: "2026-05-01T10:00:00Z")])]
        )

        let refreshed = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: [local]
        ).connections

        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.status, .pending)
        XCTAssertNil(refreshed.first?.linkedAt)
        XCTAssertTrue(refreshed.first?.sharedSchedules.isEmpty == true)
    }

    @MainActor
    func test_submitFriendRequest_rejectsSelfRequestBeforeCloudKitCall() async throws {
        let service = CapturingFriendCloudKitService()
        let vm = AppViewModel(friendScheduleCloudKitService: service)
        setVerifiedIdentity(on: vm, gemsID: "111111")
        vm.friendConnections = []

        await vm.submitFriendRequest(employeeID: "111111")

        XCTAssertEqual(service.requestCallCount, 0)
        XCTAssertEqual(vm.friendActionMessage, "You cannot add yourself as a friend.")
    }

    @MainActor
    func test_submitFriendRequest_reappliesDuplicatePendingRequestWithoutAddingLocalDuplicate() async throws {
        let service = CapturingFriendCloudKitService()
        let vm = AppViewModel(friendScheduleCloudKitService: service)
        setVerifiedIdentity(on: vm, gemsID: "111111")
        vm.friendConnections = [
            FriendConnection(employeeID: "0222222", status: .pending)
        ]

        await vm.submitFriendRequest(employeeID: "222222")

        XCTAssertEqual(service.requestCallCount, 1)
        XCTAssertEqual(vm.friendConnections.count, 1)
        XCTAssertEqual(vm.friendConnections.first?.employeeID, "0222222")
        XCTAssertEqual(vm.friendActionMessage, "Request saved. Ask GEMS 0222222 to add your GEMS ID too.")
    }

    @MainActor
    func test_submitFriendRequest_doesNotUploadSharedScheduleForSingleSidedPendingRequest() async throws {
        let service = CapturingFriendCloudKitService()
        let vm = AppViewModel(friendScheduleCloudKitService: service)
        setVerifiedIdentity(on: vm, gemsID: "111111")

        await vm.submitFriendRequest(employeeID: "222222")

        XCTAssertEqual(vm.friendConnections.first?.status, .pending)
        XCTAssertEqual(vm.friendConnections.first?.requestDirection, .outgoing)
        XCTAssertEqual(vm.pendingFriendConnections.count, 1)
        XCTAssertTrue(vm.incomingFriendRequestConnections.isEmpty)
        XCTAssertFalse(vm.isScheduleSharingEnabled)
        XCTAssertEqual(service.uploadScheduleCallCount, 0)
    }

    @MainActor
    func test_submitFriendRequest_uploadsSharedScheduleOnlyAfterMutualAcceptance() async throws {
        let service = CapturingFriendCloudKitService()
        service.nextRequestIsAccepted = true
        let notificationService = CapturingFriendLinkNotificationService()
        let vm = AppViewModel(
            friendLinkNotificationService: notificationService,
            friendScheduleCloudKitService: service
        )
        setVerifiedIdentity(on: vm, gemsID: "111111")
        vm.crewAccessSchedules = [makeSchedule(legs: [])]

        await vm.submitFriendRequest(employeeID: "222222")

        XCTAssertEqual(vm.friendConnections.first?.status, .accepted)
        XCTAssertTrue(vm.isScheduleSharingEnabled)
        XCTAssertEqual(service.uploadScheduleCallCount, 1)
        XCTAssertEqual(notificationService.notifiedFriendIDs, ["0222222"])
    }

    @MainActor
    func test_syncFriendCloudKit_notifiesWhenPendingFriendBecomesAccepted() async throws {
        let service = CapturingFriendCloudKitService()
        service.refreshedConnections = [
            FriendConnection(employeeID: "0222222", status: .accepted)
        ]
        let notificationService = CapturingFriendLinkNotificationService()
        let vm = AppViewModel(
            friendLinkNotificationService: notificationService,
            friendScheduleCloudKitService: service
        )
        setVerifiedIdentity(on: vm, gemsID: "111111")
        vm.friendConnections = [
            FriendConnection(employeeID: "0222222", status: .pending)
        ]
        vm.isScheduleSharingEnabled = false
        vm.crewAccessSchedules = [makeSchedule(legs: [])]

        await vm.syncFriendCloudKit(reason: "friend refresh")

        XCTAssertTrue(vm.isScheduleSharingEnabled)
        XCTAssertEqual(service.uploadScheduleCallCount, 1)
        XCTAssertEqual(notificationService.notifiedFriendIDs, ["0222222"])

        let incomingService = CapturingFriendCloudKitService()
        incomingService.refreshedConnections = [
            FriendConnection(employeeID: "0333333", status: .pending, requestDirection: .incoming)
        ]
        let incomingNotificationService = CapturingFriendLinkNotificationService()
        let incomingVM = AppViewModel(
            friendLinkNotificationService: incomingNotificationService,
            friendScheduleCloudKitService: incomingService
        )
        setVerifiedIdentity(on: incomingVM, gemsID: "111111")

        await incomingVM.syncFriendCloudKit(reason: "friend refresh")

        XCTAssertEqual(incomingVM.incomingFriendRequestConnections.map(\.employeeID), ["0333333"])
        XCTAssertTrue(incomingVM.pendingFriendConnections.isEmpty)
        XCTAssertEqual(incomingNotificationService.notifiedRequestIDs, ["0333333"])
    }

    @MainActor
    func test_syncFriendCloudKit_doesNotAutoResumeSharingAfterFreshInstall() async throws {
        let service = CapturingFriendCloudKitService()
        service.refreshedConnections = [
            FriendConnection(employeeID: "0222222", status: .accepted)
        ]
        let vm = AppViewModel(friendScheduleCloudKitService: service)
        setVerifiedIdentity(on: vm, gemsID: "111111")
        vm.friendConnections = []
        vm.isScheduleSharingEnabled = false
        vm.crewAccessSchedules = [makeSchedule(legs: [])]

        await vm.syncFriendCloudKit(reason: "identity verified")

        XCTAssertEqual(service.refreshCallCount, 1)
        XCTAssertEqual(vm.friendConnections.first?.status, .accepted)
        XCTAssertFalse(vm.isScheduleSharingEnabled)
        XCTAssertEqual(service.uploadScheduleCallCount, 0)
    }

    @MainActor
    func test_syncFriendCloudKit_replaysRequestThatArrivesDuringActiveSync() async throws {
        let service = CapturingFriendCloudKitService()
        service.refreshDelayNanoseconds = 100_000_000
        let vm = AppViewModel(friendScheduleCloudKitService: service)
        setVerifiedIdentity(on: vm, gemsID: "111111")

        let first = Task {
            await vm.syncFriendCloudKit(reason: "app active")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = Task {
            await vm.syncFriendCloudKit(reason: "friends opened")
        }

        await first.value
        await second.value

        XCTAssertEqual(service.refreshCallCount, 2)
    }

    // MARK: - What gets published, not just how often

    /// The reported real-device symptom was a fresh "Last Updated" against stale content, which
    /// call-count assertions cannot detect. This is the sequence that produces it: the app opens
    /// with a stale cache, a friend upload starts, device sync then loads newer schedules, and the
    /// coalesced upload must publish the newer data.
    @MainActor
    func test_friendUpload_coalescedRequestPublishesSchedulesLoadedDuringUpload() async throws {
        let service = CapturingFriendCloudKitService()
        let vm = AppViewModel(
            friendLinkNotificationService: CapturingFriendLinkNotificationService(),
            friendScheduleCloudKitService: service
        )
        setVerifiedIdentity(on: vm, gemsID: "111111")
        vm.friendConnections = [FriendConnection(employeeID: "0222222", status: .accepted)]
        vm.isScheduleSharingEnabled = true

        let staleLeg = makeLeg(leg: 1, flight: "100", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:00:00Z", arrUTC: "2026-05-01T10:00:00Z")
        let freshLeg = makeLeg(leg: 1, flight: "999", depAirport: "ANC", arrAirport: "NRT", depUTC: "2026-06-01T06:00:00Z", arrUTC: "2026-06-01T16:00:00Z")
        vm.crewAccessSchedules = [makeSchedule(legs: [staleLeg])]
        vm.schedules = [makeSchedule(legs: [staleLeg])]

        let freshSchedule = makeSchedule(legs: [freshLeg])
        let secondUpload = expectation(description: "coalesced upload publishes newer schedules")
        service.onUploadRecorded = { count in
            if count == 2 { secondUpload.fulfill() }
        }
        // Device sync lands while the first upload is provably still in flight.
        service.onFirstUploadInFlight = { [weak vm] in
            guard let vm else { return }
            vm.crewAccessSchedules = [freshSchedule]
            vm.schedules = [freshSchedule]
            vm.handleSchedulesChangedForSharing()
        }

        await vm.syncFriendCloudKit(reason: "app opened")
        await fulfillment(of: [secondUpload], timeout: 5)

        let published = try XCTUnwrap(service.lastUploadedSchedules)
        XCTAssertEqual(
            published.flatMap { $0.legs.map(\.flight) },
            ["999"],
            "the last published payload must be the post-device-sync schedule, not the stale cache"
        )
    }

    /// A schedule change that arrives while sharing is off must not be silently dropped:
    /// refreshFriendSchedulesFromCloud can enable sharing part-way through the same sync.
    @MainActor
    func test_friendUpload_republishesScheduleChangeDeferredWhileSharingWasDisabled() async throws {
        let service = CapturingFriendCloudKitService()
        service.refreshedConnections = [
            FriendConnection(employeeID: "0222222", status: .accepted)
        ]
        // pending → accepted fires notifyFriendLinked. The real service asks the Simulator for
        // notification authorization and blocks the test, so inject the capturing double.
        let vm = AppViewModel(
            friendLinkNotificationService: CapturingFriendLinkNotificationService(),
            friendScheduleCloudKitService: service
        )
        setVerifiedIdentity(on: vm, gemsID: "111111")
        vm.friendConnections = [FriendConnection(employeeID: "0222222", status: .pending)]
        vm.isScheduleSharingEnabled = false

        let freshLeg = makeLeg(leg: 1, flight: "777", depAirport: "ANC", arrAirport: "ICN", depUTC: "2026-06-02T06:00:00Z", arrUTC: "2026-06-02T16:00:00Z")
        vm.crewAccessSchedules = [makeSchedule(legs: [freshLeg])]
        vm.schedules = [makeSchedule(legs: [freshLeg])]

        let published = expectation(description: "deferred schedule change is republished")
        service.onUploadRecorded = { _ in published.fulfill() }
        published.assertForOverFulfill = false

        // Device sync finishes before sharing is enabled — previously this notification was dropped.
        vm.handleSchedulesChangedForSharing()
        XCTAssertEqual(service.uploadScheduleCallCount, 0, "precondition: nothing published while sharing was off")

        await vm.syncFriendCloudKit(reason: "app opened")
        await fulfillment(of: [published], timeout: 5)

        XCTAssertTrue(vm.isScheduleSharingEnabled)
        let uploaded = try XCTUnwrap(service.lastUploadedSchedules)
        XCTAssertEqual(uploaded.flatMap { $0.legs.map(\.flight) }, ["777"])
    }

    /// `schedules` is the merged crew+bidpro array and is what gets published. If it were ever
    /// stale relative to its inputs the friend would see pre-sync data.
    @MainActor
    func test_friendUpload_publishesMergedSchedulesNotOnlyCrewAccess() async throws {
        let service = CapturingFriendCloudKitService()
        let vm = AppViewModel(
            friendLinkNotificationService: CapturingFriendLinkNotificationService(),
            friendScheduleCloudKitService: service
        )
        setVerifiedIdentity(on: vm, gemsID: "111111")
        vm.friendConnections = [FriendConnection(employeeID: "0222222", status: .accepted)]
        vm.isScheduleSharingEnabled = true

        let crewLeg = makeLeg(leg: 1, flight: "100", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-05-01T06:00:00Z", arrUTC: "2026-05-01T10:00:00Z")
        let bidproLeg = makeLeg(leg: 2, flight: "200", depAirport: "SDF", arrAirport: "ANC", depUTC: "2026-05-02T06:00:00Z", arrUTC: "2026-05-02T10:00:00Z")
        vm.crewAccessSchedules = [makeSchedule(legs: [crewLeg])]
        vm.schedules = [makeSchedule(legs: [crewLeg, bidproLeg])]

        await vm.syncFriendCloudKit(reason: "manual")

        let published = try XCTUnwrap(service.lastUploadedSchedules)
        XCTAssertEqual(
            Set(published.flatMap { $0.legs.map(\.flight) }),
            Set(["100", "200"]),
            "the merged schedules array must be published, not crewAccessSchedules alone"
        )
    }

    func test_newerFriendSchedules_prefersScheduleWithLatestLastUpdated() {
        let older = PayPeriodSchedule(
            id: "PP26-01",
            label: "Old",
            tripCount: 0,
            legCount: 0,
            openTimeCount: 0,
            updatedAt: Date(timeIntervalSince1970: 100),
            legs: [],
            openTimeTrips: []
        )
        let newer = PayPeriodSchedule(
            id: "PP26-01",
            label: "New",
            tripCount: 0,
            legCount: 0,
            openTimeCount: 0,
            updatedAt: Date(timeIntervalSince1970: 200),
            legs: [],
            openTimeTrips: []
        )

        let merged = AppViewModel.newerFriendSchedules([older], [newer])

        XCTAssertEqual(merged.map(\.label), ["New"])
        XCTAssertEqual(merged.map(\.updatedAt).max(), newer.updatedAt)
    }

    func test_newerFriendSchedules_preservesPayPeriodsKnownOnlyToOneDevice() {
        let localOnly = PayPeriodSchedule(
            id: "PP26-01",
            label: "Local",
            tripCount: 0,
            legCount: 0,
            openTimeCount: 0,
            updatedAt: Date(timeIntervalSince1970: 200),
            legs: [],
            openTimeTrips: []
        )
        let remoteOnly = PayPeriodSchedule(
            id: "PP26-02",
            label: "Remote",
            tripCount: 0,
            legCount: 0,
            openTimeCount: 0,
            updatedAt: Date(timeIntervalSince1970: 100),
            legs: [],
            openTimeTrips: []
        )

        let merged = AppViewModel.newerFriendSchedules([localOnly], [remoteOnly])

        XCTAssertEqual(Set(merged.map(\.id)), Set(["PP26-01", "PP26-02"]))
    }

    func test_newerFriendSchedules_keepsNonemptyScheduleWhenOtherCacheIsEmpty() {
        let cached = PayPeriodSchedule(
            id: "PP26-01",
            label: "Cached",
            tripCount: 0,
            legCount: 0,
            openTimeCount: 0,
            updatedAt: Date(timeIntervalSince1970: 100),
            legs: [],
            openTimeTrips: []
        )

        XCTAssertEqual(
            AppViewModel.newerFriendSchedules([cached], []).map(\.id),
            ["PP26-01"]
        )
        XCTAssertEqual(
            AppViewModel.newerFriendSchedules([], [cached]).map(\.id),
            ["PP26-01"]
        )
    }

    /// Both arrays arrive from another user's device. A CrewAccess schedule id is the import
    /// label, built one-per-file, so the same trip present under both a legacy and a current
    /// file name yields duplicate ids. Merging must collapse them, never trap.
    func test_newerFriendSchedules_collapsesDuplicateIDsWithoutTrapping() {
        func schedule(label: String, updatedAt: Date) -> PayPeriodSchedule {
            PayPeriodSchedule(
                id: "CA26-07-A70606",
                label: label,
                tripCount: 0,
                legCount: 0,
                openTimeCount: 0,
                updatedAt: updatedAt,
                legs: [],
                openTimeTrips: []
            )
        }

        let legacyNamed = schedule(label: "Legacy", updatedAt: Date(timeIntervalSince1970: 100))
        let currentNamed = schedule(label: "Current", updatedAt: Date(timeIntervalSince1970: 200))
        let remote = schedule(label: "Remote", updatedAt: Date(timeIntervalSince1970: 150))

        let merged = AppViewModel.newerFriendSchedules([legacyNamed, currentNamed], [remote])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.map(\.id), ["CA26-07-A70606"])
        XCTAssertEqual(merged.first?.label, "Current", "the newest copy of a duplicated id wins")

        // Duplicates on the incoming side must be tolerated too.
        let mergedReversed = AppViewModel.newerFriendSchedules([remote], [legacyNamed, currentNamed])
        XCTAssertEqual(mergedReversed.count, 1)
        XCTAssertEqual(mergedReversed.first?.label, "Current")

        // An empty counterpart must not short-circuit the merge: a lone array can carry
        // duplicate ids of its own and they still have to be collapsed.
        let mergedLHSOnly = AppViewModel.newerFriendSchedules([legacyNamed, currentNamed], [])
        XCTAssertEqual(mergedLHSOnly.count, 1)
        XCTAssertEqual(mergedLHSOnly.first?.label, "Current")

        let mergedRHSOnly = AppViewModel.newerFriendSchedules([], [legacyNamed, currentNamed])
        XCTAssertEqual(mergedRHSOnly.count, 1)
        XCTAssertEqual(mergedRHSOnly.first?.label, "Current")
    }

    @MainActor
    func test_removeFriend_cancelsCloudKitApprovalAndRemovesLocalConnection() async throws {
        let service = CapturingFriendCloudKitService()
        let vm = AppViewModel(friendScheduleCloudKitService: service)
        setVerifiedIdentity(on: vm, gemsID: "111111")
        let friend = FriendConnection(employeeID: "0222222", status: .accepted)
        vm.friendConnections = [friend]

        await vm.removeFriend(friend.id)

        XCTAssertEqual(service.cancelCallCount, 1)
        XCTAssertEqual(service.lastCanceledMyGEMSID, "111111")
        XCTAssertEqual(service.lastCanceledFriendGEMSID, "0222222")
        XCTAssertTrue(vm.friendConnections.isEmpty)
        XCTAssertEqual(service.deleteSharedScheduleCallCount, 1)
        XCTAssertEqual(service.lastDeletedSharedScheduleGEMSID, "111111")
    }

    @MainActor
    func test_deleteAccount_removesFriendSharingPublicDataAndLocalFriendCache() async throws {
        let service = CapturingFriendCloudKitService()
        let vm = AppViewModel(friendScheduleCloudKitService: service)
        setVerifiedIdentity(on: vm, gemsID: "111111")
        vm.friendConnections = [
            FriendConnection(employeeID: "0222222", status: .accepted)
        ]
        vm.isScheduleSharingEnabled = true

        vm.deleteLocalProfileAccount()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(vm.friendConnections.isEmpty)
        XCTAssertFalse(vm.isScheduleSharingEnabled)
        XCTAssertEqual(service.deleteFriendSharingDataCallCount, 1)
        XCTAssertEqual(service.lastDeletedFriendSharingGEMSID, "111111")
    }

    // test_refreshConnections_loadsFriendTimelineCardsFromSnapshot was removed:
    // refreshConnection no longer fetches TripScheduleSnapshot in the iOS app
    // because Friends Timeline now uses TDHSharedSchedule (TripLeg) directly.
    // TripScheduleSnapshot remains uploaded for the future web viewer only.

    func test_refreshConnections_restoresAcceptedFriendLinksFromCloudWhenLocalCacheIsEmpty() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        _ = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")
        _ = try await service.requestFriend(myGEMSID: "222222", friendGEMSID: "111111")

        let refreshed = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: []
        ).connections

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
        ).connections

        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.employeeID, "0222222")
        XCTAssertEqual(refreshed.first?.status, .accepted)
        XCTAssertEqual(refreshed.first?.linkedAt, Date(timeIntervalSince1970: 10))
    }

    func test_refreshConnections_preservesLocalNicknameWhenCloudLinkHasNoNicknameField() async throws {
        let database = FriendCloudKitFakeDatabase()
        let service = FriendScheduleCloudKitService(databaseProvider: { database })
        await database.insertFriendLink(
            gemsA: "0111111",
            gemsB: "0222222",
            approvedA: true,
            approvedB: true,
            status: "accepted",
            linkedAt: Date(timeIntervalSince1970: 10)
        )
        let local = FriendConnection(
            employeeID: "222222",
            nickname: "James",
            status: .accepted,
            requestedAt: Date(timeIntervalSince1970: 1),
            linkedAt: Date(timeIntervalSince1970: 10)
        )

        let refreshed = try await service.refreshConnections(
            myGEMSID: "111111",
            connections: [local]
        ).connections

        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.employeeID, "0222222")
        XCTAssertEqual(refreshed.first?.nickname, "James")
        XCTAssertEqual(refreshed.first?.displayName, "James")
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

    @MainActor
    private func setVerifiedIdentity(on vm: AppViewModel, gemsID: String) {
        let recordName = "_cloudkit_record_\(gemsID)"
        vm.verifiedIdentity = VerifiedIdentityProfile(
            cloudKitRecordName: recordName,
            name: "Test Pilot",
            gemsID: gemsID,
            domicile: "ANC",
            equipment: "747",
            seat: "CA",
            dateOfHire: "2000-01-01",
            isAdminEligible: false,
            adminPolicyFingerprint: nil,
            verifiedAt: Date()
        )
        vm.currentCloudKitRecordName = recordName
    }
}

private final class CapturingFriendCloudKitService: FriendScheduleCloudKitServicing, @unchecked Sendable {
    private(set) var requestCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var uploadScheduleCallCount = 0
    private(set) var deleteSharedScheduleCallCount = 0
    private(set) var deleteFriendSharingDataCallCount = 0
    private(set) var lastCanceledMyGEMSID: String?
    private(set) var lastCanceledFriendGEMSID: String?
    private(set) var lastDeletedSharedScheduleGEMSID: String?
    private(set) var lastDeletedFriendSharingGEMSID: String?
    var refreshedConnections: [FriendConnection]?
    var nextRequestIsAccepted = false
    var refreshDelayNanoseconds: UInt64 = 0

    /// Every payload this fake was asked to publish, in order. Counting calls is not enough —
    /// the bug class we care about is publishing the *wrong* schedule, not the wrong number of times.
    private(set) var uploadedSchedulesHistory: [[PayPeriodSchedule]] = []
    var lastUploadedSchedules: [PayPeriodSchedule]? { uploadedSchedulesHistory.last }

    /// Runs once, while the first upload is still in flight. Lets a test simulate device sync
    /// landing mid-upload without a fixed `Task.sleep`, so the ordering is guaranteed rather
    /// than hoped for.
    var onFirstUploadInFlight: (@MainActor () -> Void)?
    /// Called after each upload is recorded, with the running call count. Pair with an
    /// XCTestExpectation to await a specific upload instead of sleeping.
    var onUploadRecorded: ((Int) -> Void)?

    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws {
        uploadScheduleCallCount += 1
        uploadedSchedulesHistory.append(schedules)
        if let hook = onFirstUploadInFlight {
            onFirstUploadInFlight = nil
            await hook()
        }
        onUploadRecorded?(uploadScheduleCallCount)
    }

    func uploadScheduleSnapshot(gemsID: String, ownerDisplayName: String, crewAccessTrips: [CrewAccessTripJSON]) async throws {}

    func requestFriend(myGEMSID: String, friendGEMSID: String, friendResetAt: Date?) async throws -> FriendScheduleCloudKitLink {
        requestCallCount += 1
        return FriendScheduleCloudKitLink(
            friendGEMSID: GEMSIDNormalizer.normalize(friendGEMSID),
            isAccepted: nextRequestIsAccepted,
            linkedAt: nextRequestIsAccepted ? Date() : nil,
            requestedAt: Date()
        )
    }

    func cancelFriendRequest(myGEMSID: String, friendGEMSID: String) async throws {
        cancelCallCount += 1
        lastCanceledMyGEMSID = myGEMSID
        lastCanceledFriendGEMSID = friendGEMSID
    }

    func deleteSharedScheduleData(gemsID: String) async throws {
        deleteSharedScheduleCallCount += 1
        lastDeletedSharedScheduleGEMSID = gemsID
    }

    func deleteFriendSharingData(gemsID: String) async throws {
        deleteFriendSharingDataCallCount += 1
        lastDeletedFriendSharingGEMSID = gemsID
    }

    /// Per-friend outcomes a test can dictate, so Green/Amber/Red can be exercised directly.
    var refreshOutcomes: [String: FriendScheduleSyncOutcome] = [:]

    func refreshConnections(myGEMSID: String, connections: [FriendConnection], friendResetAt: Date?) async throws -> FriendConnectionRefreshResult {
        refreshCallCount += 1
        if refreshDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: refreshDelayNanoseconds)
        }
        let resolved = refreshedConnections ?? connections
        let outcomes = refreshOutcomes.isEmpty
            ? Dictionary(uniqueKeysWithValues: resolved.map { (GEMSIDNormalizer.normalize($0.employeeID), FriendScheduleSyncOutcome.succeeded) })
            : refreshOutcomes
        return FriendConnectionRefreshResult(connections: resolved, outcomes: outcomes)
    }
}

private final class CapturingFriendLinkNotificationService: FriendLinkNotificationScheduling, @unchecked Sendable {
    private(set) var notifiedFriendIDs: [String] = []
    private(set) var notifiedRequestIDs: [String] = []

    func notifyFriendLinked(_ friend: FriendConnection) async {
        notifiedFriendIDs.append(friend.employeeID)
    }

    func notifyFriendRequestReceived(_ friend: FriendConnection) async {
        notifiedRequestIDs.append(friend.employeeID)
    }
}

private actor FriendCloudKitFakeDatabase: FriendScheduleCloudKitDatabase {
    private var records: [String: CKRecord] = [:]
    private var failedRecordFetches: Set<String> = []
    private var conflictFirstFriendLinkSaveWithOtherApproval: Bool
    private var denyCanonicalFriendLinkUpdates: Bool
    private var saveCallCount = 0
    private var queryFailureCode: CKError.Code?

    init(
        conflictFirstFriendLinkSaveWithOtherApproval: Bool = false,
        denyCanonicalFriendLinkUpdates: Bool = false
    ) {
        self.conflictFirstFriendLinkSaveWithOtherApproval = conflictFirstFriendLinkSaveWithOtherApproval
        self.denyCanonicalFriendLinkUpdates = denyCanonicalFriendLinkUpdates
    }

    func record(for recordID: CKRecord.ID) async throws -> CKRecord {
        if failedRecordFetches.contains(recordID.recordName) {
            throw CKError(.networkFailure)
        }
        guard let record = records[recordID.recordName] else {
            throw CKError(.unknownItem)
        }
        return record
    }

    func failRecordFetch(named recordName: String) {
        failedRecordFetches.insert(recordName)
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        saveCallCount += 1
        let recordName = record.recordID.recordName
        if conflictFirstFriendLinkSaveWithOtherApproval,
           Self.isCanonicalFriendLinkRecordName(recordName) {
            conflictFirstFriendLinkSaveWithOtherApproval = false
            let serverRecord = CKRecord(recordType: "TDHFriendLink", recordID: record.recordID)
            serverRecord["gemsA"] = "0111111" as CKRecordValue
            serverRecord["gemsB"] = "0222222" as CKRecordValue
            serverRecord["approvedB"] = true as CKRecordValue
            records[recordName] = serverRecord
            throw CKError(.serverRecordChanged)
        }
        if denyCanonicalFriendLinkUpdates,
           Self.isCanonicalFriendLinkRecordName(recordName),
           records[recordName] != nil {
            throw CKError(.permissionFailure)
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

    /// Simulates a CloudKit environment where gemsA/gemsB have no Queryable index — the usual
    /// Development-vs-Production schema gap.
    func failQueries(with code: CKError.Code = .invalidArguments) {
        queryFailureCode = code
    }

    func records(matching query: CKQuery) async throws -> [CKRecord] {
        if let queryFailureCode {
            throw CKError(queryFailureCode)
        }
        return records.values.filter { record in
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
        recordName: String? = nil,
        gemsA: String,
        gemsB: String,
        approvedA: Bool,
        approvedB: Bool,
        status: String?,
        linkedAt: Date?,
        requestedAt: Date? = nil
    ) {
        let recordID = CKRecord.ID(recordName: recordName ?? "tdh_friend_\(gemsA)_\(gemsB)")
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
        if let requestedAt {
            record["requestedAt"] = requestedAt as CKRecordValue
        }
        records[recordID.recordName] = record
    }

    func friendLinkRecordNames() -> [String] {
        records.keys
            .filter { $0.hasPrefix("tdh_friend_") }
            .sorted()
    }

    func saveCount() -> Int {
        saveCallCount
    }

    func recordSnapshot(named recordName: String) -> CKRecord? {
        records[recordName]
    }

    private static func isCanonicalFriendLinkRecordName(_ recordName: String) -> Bool {
        recordName.hasPrefix("tdh_friend_") && !recordName.hasPrefix("tdh_friend_user_")
    }
}
