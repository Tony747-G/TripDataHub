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
    }

    func test_friendCloudKitRefresh_mergesUserOwnedAcceptedLink() async throws {
        let database = FriendCloudKitFakeDatabase(denyCanonicalFriendLinkUpdates: true)
        let service = FriendScheduleCloudKitService(databaseProvider: { database })

        _ = try await service.requestFriend(myGEMSID: "222222", friendGEMSID: "111111")
        _ = try await service.requestFriend(myGEMSID: "111111", friendGEMSID: "222222")

        let refreshed = try await service.refreshConnections(myGEMSID: "222222", connections: [])

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
        try await service.cancelFriendRequest(myGEMSID: "111111", friendGEMSID: "222222")

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
        )

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
        )

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
        )

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
        )

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
        )

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

        await vm.syncFriendCloudKit(reason: "friend refresh")

        XCTAssertEqual(notificationService.notifiedFriendIDs, ["0222222"])
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
        )

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

    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws {
        uploadScheduleCallCount += 1
    }

    func uploadScheduleSnapshot(gemsID: String, ownerDisplayName: String, crewAccessTrips: [CrewAccessTripJSON]) async throws {}

    func requestFriend(myGEMSID: String, friendGEMSID: String) async throws -> FriendScheduleCloudKitLink {
        requestCallCount += 1
        return FriendScheduleCloudKitLink(
            friendGEMSID: GEMSIDNormalizer.normalize(friendGEMSID),
            isAccepted: nextRequestIsAccepted,
            linkedAt: nextRequestIsAccepted ? Date(timeIntervalSince1970: 2) : nil,
            requestedAt: Date(timeIntervalSince1970: 1)
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

    func refreshConnections(myGEMSID: String, connections: [FriendConnection]) async throws -> [FriendConnection] {
        refreshCallCount += 1
        return refreshedConnections ?? connections
    }
}

private final class CapturingFriendLinkNotificationService: FriendLinkNotificationScheduling, @unchecked Sendable {
    private(set) var notifiedFriendIDs: [String] = []

    func notifyFriendLinked(_ friend: FriendConnection) async {
        notifiedFriendIDs.append(friend.employeeID)
    }
}

private actor FriendCloudKitFakeDatabase: FriendScheduleCloudKitDatabase {
    private var records: [String: CKRecord] = [:]
    private var conflictFirstFriendLinkSaveWithOtherApproval: Bool
    private var denyCanonicalFriendLinkUpdates: Bool
    private var saveCallCount = 0

    init(
        conflictFirstFriendLinkSaveWithOtherApproval: Bool = false,
        denyCanonicalFriendLinkUpdates: Bool = false
    ) {
        self.conflictFirstFriendLinkSaveWithOtherApproval = conflictFirstFriendLinkSaveWithOtherApproval
        self.denyCanonicalFriendLinkUpdates = denyCanonicalFriendLinkUpdates
    }

    func record(for recordID: CKRecord.ID) async throws -> CKRecord {
        guard let record = records[recordID.recordName] else {
            throw CKError(.unknownItem)
        }
        return record
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
