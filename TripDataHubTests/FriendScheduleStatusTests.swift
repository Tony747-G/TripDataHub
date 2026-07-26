import XCTest
@testable import TripDataHub

/// Green / Amber / Red for each accepted friend.
///
/// Both friend lists iterate `acceptedFriendConnections` and call
/// `AppViewModel.scheduleSyncHealth(for:)`, so these tests drive that one function and assert the
/// rows it will be asked about actually exist.
@MainActor
final class FriendScheduleStatusTests: XCTestCase {

    /// Fixed "now" so "tomorrow" is unambiguous: 2026-07-25 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_784_980_800)

    // MARK: - Green

    func test_fetchSucceeded_withTripTomorrow_isGreen() {
        let friend = acceptedFriend(schedules: [schedule(legs: [
            leg(depUTC: "2026-07-26T09:00:00Z", arrUTC: "2026-07-26T13:00:00Z")
        ])])
        let vm = makeViewModel(friends: [friend], outcomes: [friend.employeeID: .succeeded])

        XCTAssertEqual(vm.scheduleSyncHealth(for: friend, now: now), .synchronizedWithUpcomingSchedule)
    }

    /// Departs today, lands tomorrow: still operating when tomorrow begins, so green.
    func test_tripCrossingIntoTomorrow_isGreen() {
        let friend = acceptedFriend(schedules: [schedule(legs: [
            leg(depUTC: "2026-07-25T20:00:00Z", arrUTC: "2026-07-26T06:00:00Z")
        ])])
        let vm = makeViewModel(friends: [friend], outcomes: [friend.employeeID: .succeeded])

        XCTAssertEqual(vm.scheduleSyncHealth(for: friend, now: now), .synchronizedWithUpcomingSchedule)
    }

    func test_tripStartingAndEndingTomorrow_isGreen() {
        let friend = acceptedFriend(schedules: [schedule(legs: [
            leg(depUTC: "2026-07-26T02:00:00Z", arrUTC: "2026-07-26T08:00:00Z")
        ])])
        let vm = makeViewModel(friends: [friend], outcomes: [friend.employeeID: .succeeded])

        XCTAssertEqual(vm.scheduleSyncHealth(for: friend, now: now), .synchronizedWithUpcomingSchedule)
    }

    // MARK: - Amber

    /// Fetched cleanly, nothing published. Must never be red.
    func test_fetchSucceeded_withEmptySchedule_isAmber() {
        let friend = acceptedFriend(schedules: [])
        let vm = makeViewModel(friends: [friend], outcomes: [friend.employeeID: .succeeded])

        XCTAssertEqual(vm.scheduleSyncHealth(for: friend, now: now), .synchronizedWithoutUpcomingSchedule)
    }

    /// A friend with an active link but no schedule record is a successful fetch of nothing.
    func test_missingScheduleRecordButHealthyLink_isAmber() {
        let friend = acceptedFriend(schedules: [schedule(legs: [])])
        let vm = makeViewModel(friends: [friend], outcomes: [friend.employeeID: .succeeded])

        XCTAssertEqual(vm.scheduleSyncHealth(for: friend, now: now), .synchronizedWithoutUpcomingSchedule)
    }

    func test_tripFinishingToday_isAmber() {
        let friend = acceptedFriend(schedules: [schedule(legs: [
            leg(depUTC: "2026-07-25T04:00:00Z", arrUTC: "2026-07-25T14:00:00Z")
        ])])
        let vm = makeViewModel(friends: [friend], outcomes: [friend.employeeID: .succeeded])

        XCTAssertEqual(vm.scheduleSyncHealth(for: friend, now: now), .synchronizedWithoutUpcomingSchedule)
    }

    func test_tripEntirelyInThePast_isAmber() {
        let friend = acceptedFriend(schedules: [schedule(legs: [
            leg(depUTC: "2026-07-20T04:00:00Z", arrUTC: "2026-07-20T10:00:00Z")
        ])])
        let vm = makeViewModel(friends: [friend], outcomes: [friend.employeeID: .succeeded])

        XCTAssertEqual(vm.scheduleSyncHealth(for: friend, now: now), .synchronizedWithoutUpcomingSchedule)
    }

    // MARK: - Red, and that the red row is actually on screen

    /// The row must survive the failure — a red dot on a row that got filtered out is useless.
    func test_fetchFailure_keepsRowAndTurnsItRed() {
        let friend = acceptedFriend(schedules: [schedule(legs: [
            leg(depUTC: "2026-07-26T09:00:00Z", arrUTC: "2026-07-26T13:00:00Z")
        ])])
        let vm = makeViewModel(friends: [friend], outcomes: [friend.employeeID: .failed(.fetchError)])

        XCTAssertEqual(
            vm.acceptedFriendConnections.map(\.employeeID),
            [friend.employeeID],
            "a failed fetch must keep the cached row visible, otherwise red is unreachable"
        )
        XCTAssertEqual(vm.scheduleSyncHealth(for: friend, now: now), .failed)
    }

    /// Both friend lists render `acceptedFriendConnections`; this is the value each row receives.
    func test_redFriendIsPresentInTheListBothScreensRender() {
        let failing = acceptedFriend(employeeID: "0222222", schedules: [schedule(legs: [])])
        let healthy = acceptedFriend(employeeID: "0333333", schedules: [schedule(legs: [
            leg(depUTC: "2026-07-26T09:00:00Z", arrUTC: "2026-07-26T13:00:00Z")
        ])])
        let vm = makeViewModel(
            friends: [failing, healthy],
            outcomes: [
                failing.employeeID: .failed(.fetchError),
                healthy.employeeID: .succeeded
            ]
        )

        let rendered = vm.acceptedFriendConnections
        XCTAssertEqual(Set(rendered.map(\.employeeID)), ["0222222", "0333333"])

        let healths = Dictionary(
            uniqueKeysWithValues: rendered.map { ($0.employeeID, vm.scheduleSyncHealth(for: $0, now: now)) }
        )
        XCTAssertEqual(healths["0222222"], .failed)
        XCTAssertEqual(healths["0333333"], .synchronizedWithUpcomingSchedule)
    }

    /// One friend failing must not drag the others down.
    func test_oneFriendFails_othersKeepTheirOwnStatus() {
        let failing = acceptedFriend(employeeID: "0222222", schedules: [schedule(legs: [])])
        let green = acceptedFriend(employeeID: "0333333", schedules: [schedule(legs: [
            leg(depUTC: "2026-07-27T09:00:00Z", arrUTC: "2026-07-27T13:00:00Z")
        ])])
        let amber = acceptedFriend(employeeID: "0444444", schedules: [])
        let vm = makeViewModel(
            friends: [failing, green, amber],
            outcomes: [
                failing.employeeID: .failed(.fetchError),
                green.employeeID: .succeeded,
                amber.employeeID: .succeeded
            ]
        )

        XCTAssertEqual(vm.scheduleSyncHealth(for: failing, now: now), .failed)
        XCTAssertEqual(vm.scheduleSyncHealth(for: green, now: now), .synchronizedWithUpcomingSchedule)
        XCTAssertEqual(vm.scheduleSyncHealth(for: amber, now: now), .synchronizedWithoutUpcomingSchedule)
    }

    /// A CloudKit link-query failure degrades to per-friend record fetches, so each friend still
    /// gets its own verdict rather than the whole list going red.
    func test_linkQueryFailure_stillYieldsPerFriendOutcomes() async throws {
        let service = StatusFriendService()
        service.result = FriendConnectionRefreshResult(
            connections: [
                acceptedFriend(employeeID: "0222222", schedules: [schedule(legs: [])]),
                acceptedFriend(employeeID: "0333333", schedules: [schedule(legs: [
                    leg(depUTC: "2026-07-26T09:00:00Z", arrUTC: "2026-07-26T13:00:00Z")
                ])])
            ],
            outcomes: [
                "0222222": .failed(.fetchError),
                "0333333": .succeeded
            ]
        )
        let vm = AppViewModel(friendScheduleCloudKitService: service)
        setVerifiedIdentity(on: vm)
        vm.friendConnections = service.result.connections

        await vm.refreshFriendSchedulesFromCloud()

        let byID = Dictionary(
            uniqueKeysWithValues: vm.acceptedFriendConnections.map {
                ($0.employeeID, vm.scheduleSyncHealth(for: $0, now: now))
            }
        )
        XCTAssertEqual(byID["0222222"], .failed)
        XCTAssertEqual(byID["0333333"], .synchronizedWithUpcomingSchedule)
    }

    /// A friend never refreshed in this session shows its cached data rather than a false failure.
    func test_friendWithNoRecordedOutcome_isNotRed() {
        let friend = acceptedFriend(schedules: [schedule(legs: [
            leg(depUTC: "2026-07-26T09:00:00Z", arrUTC: "2026-07-26T13:00:00Z")
        ])])
        let vm = makeViewModel(friends: [friend], outcomes: [:])

        XCTAssertEqual(vm.scheduleSyncHealth(for: friend, now: now), .synchronizedWithUpcomingSchedule)
    }

    // MARK: - Accessibility

    func test_accessibilityValues() {
        XCTAssertEqual(
            FriendScheduleSyncHealth.synchronizedWithUpcomingSchedule.accessibilityValue,
            "Schedule synchronized"
        )
        XCTAssertEqual(
            FriendScheduleSyncHealth.synchronizedWithoutUpcomingSchedule.accessibilityValue,
            "Synchronized, no upcoming schedule"
        )
        XCTAssertEqual(
            FriendScheduleSyncHealth.failed.accessibilityValue,
            "Schedule sync failed"
        )
    }

    // MARK: - Backward compatibility

    /// The health model deliberately adds no stored property to `FriendConnection`, so a cache
    /// written by 1.2.4 must decode byte-for-byte under this build. The fixture mirrors 1.2.4's
    /// shape: every non-optional key present, optionals (`avatarImageData`, `acceptedAt`,
    /// `requestDirection`) absent.
    func test_legacyFriendConnectionCacheStillDecodes() throws {
        let legacyJSON = """
        [{
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "employeeID": "0222222",
          "nickname": "Legacy Friend",
          "status": "accepted",
          "requestedAt": 774000000,
          "linkedAt": 774000100,
          "sharedSchedules": [],
          "sharedTimelineCards": []
        }]
        """
        let decoded = try JSONDecoder().decode([FriendConnection].self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].employeeID, "0222222")
        XCTAssertEqual(decoded[0].status, .accepted)
        XCTAssertNil(decoded[0].avatarImageData)

        // And it evaluates without a recorded outcome.
        let vm = makeViewModel(friends: decoded, outcomes: [:])
        XCTAssertEqual(vm.scheduleSyncHealth(for: decoded[0], now: now), .synchronizedWithoutUpcomingSchedule)
    }

    // MARK: - Evaluator boundary

    func test_startOfTomorrowBoundaryIsInclusive() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let boundary = FriendScheduleHealthEvaluator.startOfTomorrow(now: now, calendar: calendar)

        let exactlyAtBoundary = [schedule(legs: [
            leg(
                depUTC: ISO8601DateFormatter().string(from: boundary),
                arrUTC: ISO8601DateFormatter().string(from: boundary.addingTimeInterval(3600))
            )
        ])]
        XCTAssertTrue(
            FriendScheduleHealthEvaluator.hasUpcomingSchedule(exactlyAtBoundary, now: now, calendar: calendar),
            "a departure exactly at the start of tomorrow counts as upcoming"
        )
    }

    // MARK: - Helpers

    private func makeViewModel(
        friends: [FriendConnection],
        outcomes: [String: FriendScheduleSyncOutcome]
    ) -> AppViewModel {
        let service = StatusFriendService()
        service.result = FriendConnectionRefreshResult(connections: friends, outcomes: outcomes)
        let vm = AppViewModel(friendScheduleCloudKitService: service)
        setVerifiedIdentity(on: vm)
        vm.friendConnections = friends
        vm.applyFriendScheduleSyncOutcomesForTesting(outcomes)
        return vm
    }

    private func setVerifiedIdentity(on vm: AppViewModel, gemsID: String = "7793942") {
        vm.verifiedIdentity = VerifiedIdentityProfile(
            cloudKitRecordName: "_rec_\(gemsID)",
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
        vm.currentCloudKitRecordName = "_rec_\(gemsID)"
    }

    private func acceptedFriend(
        employeeID: String = "0222222",
        schedules: [PayPeriodSchedule]
    ) -> FriendConnection {
        FriendConnection(
            employeeID: employeeID,
            status: .accepted,
            requestedAt: Date(),
            linkedAt: Date(),
            sharedSchedules: schedules
        )
    }

    private func schedule(legs: [TripLeg]) -> PayPeriodSchedule {
        PayPeriodSchedule(
            id: "PP26-08",
            label: "PP26-08",
            tripCount: legs.isEmpty ? 0 : 1,
            legCount: legs.count,
            openTimeCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_785_000_000),
            legs: legs,
            openTimeTrips: []
        )
    }

    private func leg(depUTC: String, arrUTC: String) -> TripLeg {
        TripLeg(
            id: UUID(),
            payPeriod: "PP26-08",
            pairing: "A700004",
            leg: 1,
            flight: "100",
            depAirport: "ANC",
            depLocal: "",
            arrAirport: "SDF",
            arrLocal: "",
            depUTC: depUTC,
            arrUTC: arrUTC,
            status: "SCH",
            block: "4:00",
            layoverStation: nil,
            layoverHotelName: nil,
            layoverDuration: nil,
            stdUTC: nil,
            staUTC: nil,
            atdUTC: nil,
            ataUTC: nil
        )
    }
}

private final class StatusFriendService: FriendScheduleCloudKitServicing, @unchecked Sendable {
    var result = FriendConnectionRefreshResult(connections: [])

    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws {}
    func uploadScheduleSnapshot(gemsID: String, ownerDisplayName: String, crewAccessTrips: [CrewAccessTripJSON]) async throws {}
    func requestFriend(myGEMSID: String, friendGEMSID: String, friendResetAt: Date?) async throws -> FriendScheduleCloudKitLink {
        FriendScheduleCloudKitLink(friendGEMSID: friendGEMSID, isAccepted: false, linkedAt: nil, requestedAt: Date())
    }
    func cancelFriendRequest(myGEMSID: String, friendGEMSID: String) async throws {}
    func deleteSharedScheduleData(gemsID: String) async throws {}
    func deleteFriendSharingData(gemsID: String) async throws {}
    func refreshConnections(myGEMSID: String, connections: [FriendConnection], friendResetAt: Date?) async throws -> FriendConnectionRefreshResult {
        result
    }
}
