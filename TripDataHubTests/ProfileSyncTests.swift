import CloudKit
import XCTest
@testable import TripDataHub

@MainActor
final class ProfileSyncTests: XCTestCase {

    func test_profileIdentityInput_repairsClearlySwappedDemoFields() {
        let input = ProfileIdentityInput(
            displayName: "0000001",
            gemsID: "Test Pilot One"
        )

        XCTAssertEqual(
            input.repairingClearlySwappedFields(),
            ProfileIdentityInput(displayName: "Test Pilot One", gemsID: "0000001")
        )
    }

    func test_profileIdentityInput_preservesNormalFields() {
        let input = ProfileIdentityInput(
            displayName: "Test Pilot One",
            gemsID: "0000001"
        )

        XCTAssertEqual(input.repairingClearlySwappedFields(), input)
    }

    func test_appReviewPilotOneSchedules_includeScreenshotTrips() {
        let schedules = AppViewModel.appReviewPilotOneSchedules(
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let trips = Dictionary(
            uniqueKeysWithValues: schedules.compactMap { schedule in
                schedule.legs.first.map { ($0.pairing, schedule.legs) }
            }
        )

        XCTAssertEqual(Set(trips.keys), ["A00001", "A00010", "A00020"])
        XCTAssertEqual(trips["A00001"]?.map(\.flight), ["XX001", "XX002", "XX003"])
        XCTAssertEqual(trips["A00010"]?.map(\.flight), ["XX010", "XX011", "XX012", "XX013", "XX014", "XX015"])
        XCTAssertEqual(trips["A00020"]?.map(\.flight), ["XX020", "XX021"])
        XCTAssertEqual(trips["A00010"]?.first?.depUTC, "2026-06-30T23:10:00Z")
        XCTAssertEqual(trips["A00010"]?.last?.arrUTC, "2026-07-10T18:35:00Z")
        XCTAssertEqual(trips["A00020"]?.first?.depUTC, "2026-06-01T18:00:00Z")
        XCTAssertEqual(trips["A00020"]?.last?.arrUTC, "2026-06-04T23:10:00Z")
    }

    func test_tripLegDisplay_preservesExplicitAirlinePrefix() {
        let leg = TripLeg(
            payPeriod: "PP26-07",
            pairing: "A00001",
            leg: 1,
            flight: "XX001",
            depAirport: "ANC",
            depLocal: "2026-06-14 05:00",
            arrAirport: "CVG",
            arrLocal: "2026-06-14 15:00",
            status: "-",
            block: "06:00"
        )

        XCTAssertEqual(leg.displayFlightNumberText, "XX001")
    }

    func test_appReviewSchedules_matchFriendFlightAndLayover() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let mySchedules = AppViewModel.appReviewPilotOneSchedules(updatedAt: now)
        let friendSchedule = AppViewModel.appReviewPilotTwoSchedule(updatedAt: now)

        let matches = FriendScheduleMatchDetector.detect(
            mySchedules: mySchedules,
            friendSchedules: [(gemsID: "0000002", schedules: [friendSchedule])],
            now: now
        )
        let currentTrip = try XCTUnwrap(
            mySchedules.first { $0.legs.first?.pairing == "A00001" }
        )
        let hndArrivalLeg = try XCTUnwrap(currentTrip.legs.first { $0.arrAirport == "HND" })
        let sharedFlightLeg = try XCTUnwrap(currentTrip.legs.first { $0.flight == "XX003" })

        XCTAssertEqual(matches.flightMatchesByLegID[sharedFlightLeg.id]?.count, 1)
        XCTAssertEqual(matches.restOverlapsByArrivalLegID[hndArrivalLeg.id]?.count, 1)
    }

    func test_iataResolver_resolvesHangzhouAirport() {
        let resolver = IATATimeZoneResolver.shared

        XCTAssertEqual(resolver.resolve("HGH"), "Asia/Shanghai")
        XCTAssertEqual(resolver.resolve(" hgh "), "Asia/Shanghai")
        XCTAssertEqual(resolver.airportName("HGH"), "Hangzhou Xiaoshan International Airport")
        XCTAssertEqual(resolver.cityName("HGH"), "Hangzhou")
    }

    // MARK: - ProfileSnapshot encode/decode

    func test_profileSnapshot_roundTrip() throws {
        let original = ProfileSnapshot(
            gemsID: "G12345",
            displayName: "Tony",
            fleet: "757",
            base: "ANC",
            position: "CA",
            avatarImageData: Data([0xFF, 0xD8, 0xFF]),
            faaMedicalExpiryDate: "2027-06",
            passportExpiryDate: "2031-04-12",
            chinaVisaExpiryDate: "2028-09-30",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProfileSnapshot.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_profileSnapshot_persistsReadinessDatesLocally() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "profile_dates_\(UUID())"))
        let snapshot = ProfileSnapshot(
            gemsID: "1234567",
            displayName: "Pilot",
            fleet: "747",
            base: "ANC",
            position: "FO",
            avatarImageData: nil,
            faaMedicalExpiryDate: "2027-06",
            passportExpiryDate: "2031-04-12",
            chinaVisaExpiryDate: "2028-09-30",
            updatedAt: Date(timeIntervalSince1970: 2_000),
            lastSeenAt: nil
        )

        snapshot.saveToLocalStorage(defaults: defaults)

        XCTAssertEqual(ProfileSnapshot.loadFromLocalStorage(defaults: defaults), snapshot)
    }

    func test_profileSnapshot_migratesLocalDatesIntoLegacyCloudRecord() {
        let remote = ProfileSnapshot(
            gemsID: "1234567",
            displayName: "Cloud Pilot",
            fleet: "747",
            base: "ANC",
            position: "FO",
            avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 2_000),
            lastSeenAt: nil
        )
        let local = ProfileSnapshot(
            gemsID: "1234567",
            displayName: "Local Pilot",
            fleet: "747",
            base: "ANC",
            position: "FO",
            avatarImageData: nil,
            faaMedicalExpiryDate: "2027-06",
            passportExpiryDate: "2031-04-12",
            chinaVisaExpiryDate: "2028-09-30",
            updatedAt: Date(timeIntervalSince1970: 1_000),
            lastSeenAt: nil
        )

        let migration = remote.mergingLegacyReadinessDates(from: local)

        XCTAssertTrue(migration.didMerge)
        XCTAssertEqual(migration.snapshot.displayName, "Cloud Pilot")
        XCTAssertEqual(migration.snapshot.faaMedicalExpiryDate, "2027-06")
        XCTAssertEqual(migration.snapshot.passportExpiryDate, "2031-04-12")
        XCTAssertEqual(migration.snapshot.chinaVisaExpiryDate, "2028-09-30")
    }

    func test_restoreProfileAfterVerification_restoresAvatarAndReadinessDates() async throws {
        clearStandardProfileDefaults()
        defer { clearStandardProfileDefaults() }
        let remote = ProfileSnapshot(
            gemsID: "1234567",
            displayName: "Cloud Pilot",
            fleet: "747",
            base: "ANC",
            position: "FO",
            avatarImageData: Data([0xFF, 0xD8, 0xFF]),
            faaMedicalExpiryDate: "2027-06",
            passportExpiryDate: "2031-04-12",
            chinaVisaExpiryDate: "2028-09-30",
            updatedAt: Date(timeIntervalSince1970: 2_000),
            lastSeenAt: nil
        )
        let service = MockProfileCloudKitService(fetchResult: remote)
        let vm = AppViewModel(profileCloudKitService: service)

        await vm.restoreProfileAfterIdentityVerification(gemsID: "1234567")

        let restored = ProfileSnapshot.loadFromLocalStorage()
        XCTAssertEqual(restored.displayName, "Cloud Pilot")
        XCTAssertEqual(restored.avatarImageData, remote.avatarImageData)
        XCTAssertEqual(restored.faaMedicalExpiryDate, "2027-06")
        XCTAssertEqual(restored.passportExpiryDate, "2031-04-12")
        XCTAssertEqual(restored.chinaVisaExpiryDate, "2028-09-30")
        XCTAssertFalse(service.saveCalled)
    }

    func test_restoreProfileAfterVerification_doesNotReviveClearedDatesForVerifiedAccount() async {
        clearStandardProfileDefaults()
        defer { clearStandardProfileDefaults() }

        // This device was already verified for 1234567 and still holds stale local
        // readiness dates from before another device cleared them.
        let stale = ProfileSnapshot(
            gemsID: "1234567",
            displayName: "Local Pilot",
            fleet: "747",
            base: "ANC",
            position: "FO",
            avatarImageData: nil,
            faaMedicalExpiryDate: "2027-06",
            passportExpiryDate: "2031-04-12",
            chinaVisaExpiryDate: "2028-09-30",
            updatedAt: Date(timeIntervalSince1970: 2_000),
            lastSeenAt: nil
        )
        stale.saveToLocalStorage()

        // The cloud record for the same account has the dates cleared (nil).
        let remote = ProfileSnapshot(
            gemsID: "1234567",
            displayName: "Cloud Pilot",
            fleet: "747",
            base: "ANC",
            position: "FO",
            avatarImageData: nil,
            faaMedicalExpiryDate: nil,
            passportExpiryDate: nil,
            chinaVisaExpiryDate: nil,
            updatedAt: Date(timeIntervalSince1970: 3_000),
            lastSeenAt: nil
        )
        let service = MockProfileCloudKitService(fetchResult: remote)
        let vm = AppViewModel(profileCloudKitService: service)

        await vm.restoreProfileAfterIdentityVerification(gemsID: "1234567")

        let restored = ProfileSnapshot.loadFromLocalStorage()
        XCTAssertEqual(restored.displayName, "Cloud Pilot")
        XCTAssertNil(restored.faaMedicalExpiryDate)
        XCTAssertNil(restored.passportExpiryDate)
        XCTAssertNil(restored.chinaVisaExpiryDate)
        XCTAssertFalse(service.saveCalled, "Already-verified account must not re-upload revived dates")
    }

    func test_saveProfile_serializesConcurrentWritesInEnqueueOrder() async throws {
        // First write (profile) is slow, second write (tombstone) is fast. Without
        // serialization the tombstone would commit first and the slow profile would
        // overwrite it, resurrecting the account. Serialized, the tombstone — enqueued
        // last — must be the final committed record.
        let database = OrderRecordingProfileDatabase(saveDelaysNs: [150_000_000, 0])
        let service = ProfileCloudKitService(databaseProvider: { database })

        let profile = ProfileSnapshot(
            gemsID: "1111111", displayName: "Pilot", fleet: "747", base: "ANC",
            position: "FO", avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000), lastSeenAt: nil
        )
        let tombstone = ProfileSnapshot(
            gemsID: "", displayName: "", fleet: "", base: "", position: "",
            avatarImageData: nil, updatedAt: Date(timeIntervalSince1970: 2_000), lastSeenAt: nil
        )

        async let first: Void = service.saveProfile(profile)
        try await Task.sleep(nanoseconds: 20_000_000) // ensure the profile is enqueued first
        async let second: Void = service.saveProfile(tombstone)
        _ = try await (first, second)

        let committed = await database.committedGEMSIDsInOrder
        XCTAssertEqual(committed, ["1111111", ""])
    }

    func test_saveProfile_dropsStaleWriteOlderThanCloudRecord() async throws {
        let database = FakeProfileCloudKitDatabase()
        let service = ProfileCloudKitService(databaseProvider: { database })

        // The account-delete tombstone (newest) is already on CloudKit.
        let tombstone = ProfileSnapshot(
            gemsID: "", displayName: "", fleet: "", base: "", position: "",
            avatarImageData: nil, updatedAt: Date(timeIntervalSince1970: 5_000), lastSeenAt: nil
        )
        try await service.saveProfile(tombstone)

        // A stale upload that began before the delete now executes; it must be
        // dropped rather than resurrect the account.
        let stale = ProfileSnapshot(
            gemsID: "1111111", displayName: "Stale", fleet: "747", base: "ANC",
            position: "FO", avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000), lastSeenAt: nil
        )
        try await service.saveProfile(stale)

        let saved = try XCTUnwrap(database.savedRecord)
        XCTAssertEqual(saved["gemsID"] as? String, "", "Tombstone must survive a later stale write")
        XCTAssertEqual(database.saveCallCount, 1, "Stale write must not reach the database")
    }

    func test_profileSnapshot_avatarNilRoundTrip() throws {
        let original = ProfileSnapshot(
            gemsID: "G99",
            displayName: "FO",
            fleet: "747",
            base: "SDF",
            position: "FO",
            avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            lastSeenAt: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProfileSnapshot.self, from: data)
        XCTAssertNil(decoded.avatarImageData)
        XCTAssertNil(decoded.lastSeenAt)
        XCTAssertEqual(original, decoded)
    }

    func test_profileSnapshot_saveNilLastSeen_clearsStoredLastSeen() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "profile_last_seen_clear_\(UUID())"))
        defaults.set(1_700_000_100.0, forKey: ProfileStorageKeys.lastSeenAt)

        ProfileSnapshot(
            gemsID: "G1",
            displayName: "Pilot",
            fleet: "757",
            base: "ANC",
            position: "CA",
            avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: nil
        ).saveToLocalStorage(defaults: defaults)

        XCTAssertEqual(defaults.double(forKey: ProfileStorageKeys.lastSeenAt), 0)
    }

    // MARK: - Conflict resolution

    func test_syncProfile_remoteNewer_updatesLocal() async throws {
        let local = ProfileSnapshot(
            gemsID: "G1", displayName: "Old Name", fleet: "757", base: "ANC",
            position: "CA", avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000), lastSeenAt: nil
        )
        let remote = ProfileSnapshot(
            gemsID: "G1", displayName: "New Name", fleet: "757", base: "ANC",
            position: "CA", avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 2_000), lastSeenAt: nil
        )
        let syncResult = try await ProfileSyncTests.resolveSyncPolicy(local: local, remote: remote)
        XCTAssertEqual(syncResult, .updateLocalFromRemote)
    }

    func test_syncProfile_localNewer_uploadsLocal() async throws {
        let local = ProfileSnapshot(
            gemsID: "G1", displayName: "Local Latest", fleet: "757", base: "ANC",
            position: "CA", avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 3_000), lastSeenAt: nil
        )
        // Remote is older
        let remote = ProfileSnapshot(
            gemsID: "G1", displayName: "Older", fleet: "757", base: "ANC",
            position: "CA", avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000), lastSeenAt: nil
        )
        let defaults = UserDefaults(suiteName: "test_local_newer_\(UUID())")!
        local.saveToLocalStorage(defaults: defaults)

        // Test sync logic directly
        let syncResult = try await ProfileSyncTests.resolveSyncPolicy(local: local, remote: remote)
        XCTAssertEqual(syncResult, .uploadLocal)
    }

    func test_syncProfile_equalUpdatedAt_noOp() async throws {
        let date = Date(timeIntervalSince1970: 5_000)
        let local = ProfileSnapshot(
            gemsID: "G1", displayName: "Same", fleet: "757", base: "ANC",
            position: "CA", avatarImageData: nil, updatedAt: date, lastSeenAt: nil
        )
        let remote = local  // identical
        let syncResult = try await ProfileSyncTests.resolveSyncPolicy(local: local, remote: remote)
        XCTAssertEqual(syncResult, .noOp)
    }

    func test_syncProfile_noRemote_localHasContent_uploads() async throws {
        let local = ProfileSnapshot(
            gemsID: "G1", displayName: "Me", fleet: "757", base: "ANC",
            position: "CA", avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000), lastSeenAt: nil
        )
        let syncResult = try await ProfileSyncTests.resolveSyncPolicy(local: local, remote: nil)
        XCTAssertEqual(syncResult, .uploadLocal)
    }

    func test_syncProfile_noRemote_noLocalContent_noOp() async throws {
        let local = ProfileSnapshot(
            gemsID: "", displayName: "", fleet: "", base: "", position: "",
            avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 0),  // epoch = no content
            lastSeenAt: nil
        )
        let syncResult = try await ProfileSyncTests.resolveSyncPolicy(local: local, remote: nil)
        XCTAssertEqual(syncResult, .noOp)
    }

    // MARK: - Tombstone: delete → other device should not resurrect

    func test_deleteAccount_tombstoneNewerThanOtherDevice_otherDeviceClears() async throws {
        let deleteTime = Date(timeIntervalSinceNow: 0)
        let tombstone = ProfileSnapshot(
            gemsID: "", displayName: "", fleet: "", base: "", position: "",
            avatarImageData: nil,
            updatedAt: deleteTime,  // just-deleted → recent timestamp
            lastSeenAt: nil
        )
        // Device B had a real profile, but older
        let deviceBLocal = ProfileSnapshot(
            gemsID: "G1", displayName: "Bob", fleet: "757", base: "ANC",
            position: "CA", avatarImageData: nil,
            updatedAt: deleteTime.addingTimeInterval(-3600),  // 1h older
            lastSeenAt: nil
        )
        // Tombstone is newer → device B should updateLocalFromRemote (clear)
        let decision = try await ProfileSyncTests.resolveSyncPolicy(local: deviceBLocal, remote: tombstone)
        XCTAssertEqual(decision, .updateLocalFromRemote,
                       "Device B must clear its profile when tombstone.updatedAt > local.updatedAt")
        // The tombstone content (empty fields) would overwrite device B's local profile.
        XCTAssertTrue(tombstone.displayName.isEmpty)
        XCTAssertNil(tombstone.avatarImageData)
    }

    func test_deleteAccount_localUpdatedAtResetToEpoch_preventsRacingUpload() async throws {
        // After deleteLocalProfileAccount, local updatedAt is set to 0.
        let epochLocal = ProfileSnapshot(
            gemsID: "", displayName: "", fleet: "", base: "", position: "",
            avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 0),  // cleared to epoch
            lastSeenAt: nil
        )
        // A tombstone already exists in CloudKit with updatedAt > epoch
        let tombstone = ProfileSnapshot(
            gemsID: "", displayName: "", fleet: "", base: "", position: "",
            avatarImageData: nil,
            updatedAt: Date(timeIntervalSinceNow: -60),  // 60s ago
            lastSeenAt: nil
        )
        // Tombstone is newer → no-op or updateLocalFromRemote, NOT uploadLocal
        let decision = try await ProfileSyncTests.resolveSyncPolicy(local: epochLocal, remote: tombstone)
        XCTAssertNotEqual(decision, .uploadLocal,
                          "Deleted device must not re-upload stale empty profile over a newer tombstone")
    }

    // MARK: - iPhone/iPad regression

    func test_profileSync_iPhoneAndIPad_roundTripsLatestProfileAcrossDevices() async throws {
        let iPhoneDefaultsName = "profile_sync_iphone_\(UUID())"
        let iPadDefaultsName = "profile_sync_ipad_\(UUID())"
        let iPhoneDefaults = try XCTUnwrap(UserDefaults(suiteName: iPhoneDefaultsName))
        let iPadDefaults = try XCTUnwrap(UserDefaults(suiteName: iPadDefaultsName))
        defer {
            iPhoneDefaults.removePersistentDomain(forName: iPhoneDefaultsName)
            iPadDefaults.removePersistentDomain(forName: iPadDefaultsName)
        }

        var cloudProfile: ProfileSnapshot?
        let iPhoneProfile = ProfileSnapshot(
            gemsID: "G12345",
            displayName: "iPhone Pilot",
            fleet: ProfileFleet.fleet747.rawValue,
            base: ProfileBase.sdf.rawValue,
            position: ProfilePosition.ca.rawValue,
            avatarImageData: Data([0xFF, 0xD8, 0xAA]),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        iPhoneProfile.saveToLocalStorage(defaults: iPhoneDefaults)

        let firstIPhoneDecision = try await syncProfile(defaults: iPhoneDefaults, cloudProfile: &cloudProfile)
        XCTAssertEqual(firstIPhoneDecision, .uploadLocal)
        XCTAssertEqual(cloudProfile, iPhoneProfile)

        let firstIPadDecision = try await syncProfile(defaults: iPadDefaults, cloudProfile: &cloudProfile)
        XCTAssertEqual(firstIPadDecision, .updateLocalFromRemote)
        XCTAssertEqual(ProfileSnapshot.loadFromLocalStorage(defaults: iPadDefaults), iPhoneProfile)

        let iPadProfile = ProfileSnapshot(
            gemsID: "G12345",
            displayName: "iPad Pilot",
            fleet: ProfileFleet.fleet757.rawValue,
            base: ProfileBase.anc.rawValue,
            position: ProfilePosition.fo.rawValue,
            avatarImageData: Data([0x01, 0x02, 0x03]),
            updatedAt: Date(timeIntervalSince1970: 1_700_010_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_700_010_100)
        )
        iPadProfile.saveToLocalStorage(defaults: iPadDefaults)

        let secondIPadDecision = try await syncProfile(defaults: iPadDefaults, cloudProfile: &cloudProfile)
        XCTAssertEqual(secondIPadDecision, .uploadLocal)
        XCTAssertEqual(cloudProfile, iPadProfile)

        let secondIPhoneDecision = try await syncProfile(defaults: iPhoneDefaults, cloudProfile: &cloudProfile)
        XCTAssertEqual(secondIPhoneDecision, .updateLocalFromRemote)
        XCTAssertEqual(ProfileSnapshot.loadFromLocalStorage(defaults: iPhoneDefaults), iPadProfile)
    }

    func test_profileSync_iPhoneDelete_clearsIPadProfileFromCloudTombstone() async throws {
        let iPhoneDefaultsName = "profile_delete_sync_iphone_\(UUID())"
        let iPadDefaultsName = "profile_delete_sync_ipad_\(UUID())"
        let iPhoneDefaults = try XCTUnwrap(UserDefaults(suiteName: iPhoneDefaultsName))
        let iPadDefaults = try XCTUnwrap(UserDefaults(suiteName: iPadDefaultsName))
        defer {
            iPhoneDefaults.removePersistentDomain(forName: iPhoneDefaultsName)
            iPadDefaults.removePersistentDomain(forName: iPadDefaultsName)
        }

        var cloudProfile: ProfileSnapshot?
        let originalProfile = ProfileSnapshot(
            gemsID: "G12345",
            displayName: "Pilot",
            fleet: ProfileFleet.fleet747.rawValue,
            base: ProfileBase.sdf.rawValue,
            position: ProfilePosition.ca.rawValue,
            avatarImageData: Data([0xFF, 0xD8]),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: nil
        )
        originalProfile.saveToLocalStorage(defaults: iPhoneDefaults)
        _ = try await syncProfile(defaults: iPhoneDefaults, cloudProfile: &cloudProfile)
        _ = try await syncProfile(defaults: iPadDefaults, cloudProfile: &cloudProfile)

        let tombstone = ProfileSnapshot(
            gemsID: "",
            displayName: "",
            fleet: "",
            base: "",
            position: "",
            avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_010_000),
            lastSeenAt: nil
        )
        cloudProfile = tombstone

        let iPadDeleteDecision = try await syncProfile(defaults: iPadDefaults, cloudProfile: &cloudProfile)
        let clearedIPadProfile = ProfileSnapshot.loadFromLocalStorage(defaults: iPadDefaults)
        XCTAssertEqual(iPadDeleteDecision, .updateLocalFromRemote)
        XCTAssertEqual(clearedIPadProfile.gemsID, "")
        XCTAssertEqual(clearedIPadProfile.displayName, "")
        XCTAssertNil(clearedIPadProfile.avatarImageData)
        XCTAssertEqual(clearedIPadProfile.updatedAt, tombstone.updatedAt)
    }

    func test_profileSync_tombstoneDoesNotOverwriteOperationalCrewBase() async throws {
        let defaultsName = "profile_tombstone_base_\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        defaults.set(ProfileBase.sdf.rawValue, forKey: OperationalSettings.crewBaseKey)
        let tombstone = ProfileSnapshot(
            gemsID: "",
            displayName: "",
            fleet: "",
            base: "",
            position: "",
            avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_010_000),
            lastSeenAt: nil
        )

        tombstone.saveToLocalStorage(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: OperationalSettings.crewBaseKey), ProfileBase.sdf.rawValue)
        XCTAssertEqual(defaults.string(forKey: ProfileStorageKeys.gemsID), "")
        XCTAssertEqual(defaults.string(forKey: ProfileStorageKeys.displayName), "")
        XCTAssertEqual(defaults.double(forKey: ProfileStorageKeys.updatedAt), 1_700_010_000)
    }

    func test_syncProfileWithCloudKit_uploadsFreshLocalSnapshotAfterFetchAwait() async throws {
        clearStandardProfileDefaults()
        defer { clearStandardProfileDefaults() }

        let remote = ProfileSnapshot(
            gemsID: "G1",
            displayName: "Remote Old",
            fleet: ProfileFleet.fleet757.rawValue,
            base: ProfileBase.anc.rawValue,
            position: ProfilePosition.ca.rawValue,
            avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 900),
            lastSeenAt: nil
        )
        let staleLocal = ProfileSnapshot(
            gemsID: "G1",
            displayName: "Alice",
            fleet: ProfileFleet.fleet757.rawValue,
            base: ProfileBase.anc.rawValue,
            position: ProfilePosition.ca.rawValue,
            avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            lastSeenAt: nil
        )
        let editedLocal = ProfileSnapshot(
            gemsID: "G1",
            displayName: "Bob",
            fleet: ProfileFleet.fleet747.rawValue,
            base: ProfileBase.sdf.rawValue,
            position: ProfilePosition.fo.rawValue,
            avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 2_000),
            lastSeenAt: nil
        )
        staleLocal.saveToLocalStorage()
        let mockService = MockProfileCloudKitService(fetchResult: remote, fetchDelayNanoseconds: 100_000_000)
        let vm = AppViewModel(profileCloudKitService: mockService)

        let syncTask = Task { await vm.syncProfileWithCloudKit() }
        try await Task.sleep(nanoseconds: 30_000_000)
        editedLocal.saveToLocalStorage()
        await syncTask.value

        XCTAssertEqual(mockService.lastSavedSnapshot, editedLocal)
    }

    func test_deleteAccount_blocksForegroundSyncUntilTombstoneWriteCompletes() async throws {
        clearStandardProfileDefaults()
        defer { clearStandardProfileDefaults() }

        let oldRemote = ProfileSnapshot(
            gemsID: "G1",
            displayName: "Should Not Resurrect",
            fleet: ProfileFleet.fleet747.rawValue,
            base: ProfileBase.sdf.rawValue,
            position: ProfilePosition.ca.rawValue,
            avatarImageData: Data([0xFF]),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            lastSeenAt: nil
        )
        oldRemote.saveToLocalStorage()
        let mockService = MockProfileCloudKitService(fetchResult: oldRemote, saveDelayNanoseconds: 100_000_000)
        let vm = AppViewModel(profileCloudKitService: mockService)

        vm.deleteLocalProfileAccount()
        await vm.syncProfileWithCloudKit()

        XCTAssertEqual(ProfileSnapshot.loadFromLocalStorage().displayName, "")
        XCTAssertNil(ProfileSnapshot.loadFromLocalStorage().avatarImageData)

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(mockService.saveCalled)
    }

    func test_syncProfileWithCloudKit_deduplicatesConcurrentCalls() async throws {
        clearStandardProfileDefaults()
        defer { clearStandardProfileDefaults() }

        let local = ProfileSnapshot(
            gemsID: "G1",
            displayName: "Local",
            fleet: ProfileFleet.fleet757.rawValue,
            base: ProfileBase.anc.rawValue,
            position: ProfilePosition.ca.rawValue,
            avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 2_000),
            lastSeenAt: nil
        )
        let remote = ProfileSnapshot(
            gemsID: "G1",
            displayName: "Remote",
            fleet: ProfileFleet.fleet757.rawValue,
            base: ProfileBase.anc.rawValue,
            position: ProfilePosition.ca.rawValue,
            avatarImageData: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            lastSeenAt: nil
        )
        local.saveToLocalStorage()
        let mockService = MockProfileCloudKitService(fetchResult: remote, fetchDelayNanoseconds: 100_000_000)
        let vm = AppViewModel(profileCloudKitService: mockService)

        async let first: Void = vm.syncProfileWithCloudKit()
        async let second: Void = vm.syncProfileWithCloudKit()
        _ = await (first, second)

        XCTAssertEqual(mockService.saveCallCount, 1)
    }

    func test_profileCloudKitSave_clearsLastSeenAndStillSavesWhenAvatarTempWriteFails() async throws {
        let database = FakeProfileCloudKitDatabase()
        let existingRecord = CKRecord(recordType: "Profile", recordID: ProfileCloudKitService.recordID)
        existingRecord["lastSeenAt"] = Date(timeIntervalSince1970: 1_000) as CKRecordValue
        database.seed(existingRecord)
        let service = ProfileCloudKitService(
            databaseProvider: { database },
            avatarTemporaryDirectory: URL(fileURLWithPath: "/dev/null")
        )
        let snapshot = ProfileSnapshot(
            gemsID: "G1",
            displayName: "Text Must Save",
            fleet: ProfileFleet.fleet747.rawValue,
            base: ProfileBase.sdf.rawValue,
            position: ProfilePosition.fo.rawValue,
            avatarImageData: Data([0xFF, 0xD8]),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            lastSeenAt: nil
        )

        try await service.saveProfile(snapshot)

        let saved = try XCTUnwrap(database.savedRecord)
        XCTAssertEqual(saved["displayName"] as? String, "Text Must Save")
        XCTAssertEqual(saved["faaMedicalExpiryDate"] as? String, "")
        XCTAssertEqual(saved["passportExpiryDate"] as? String, "")
        XCTAssertEqual(saved["chinaVisaExpiryDate"] as? String, "")
        XCTAssertNil(saved["lastSeenAt"])
        XCTAssertNil(saved["avatarAsset"])
        XCTAssertEqual(database.saveCallCount, 1)
    }

    // MARK: - Record ID safety

    func test_recordID_isNotGEMSID() {
        let recordID = ProfileCloudKitService.recordID
        XCTAssertEqual(recordID.recordName, "currentUserProfile")
        // Verify no GEMS ID format (e.g. "G12345") was used as record name
        XCTAssertFalse(recordID.recordName.hasPrefix("G"))
        XCTAssertFalse(recordID.recordName.contains("gems"))
        XCTAssertFalse(recordID.recordName.contains("GEMS"))
    }

    // MARK: - Delete

    func test_deleteAccount_writesTombstoneNotHardDelete() async throws {
        // Delete Account must write an empty tombstone to CloudKit (not a hard delete)
        // so other devices can detect the deletion via last-write-wins.
        let mockService = MockProfileCloudKitService(fetchResult: nil)
        let vm = AppViewModel(profileCloudKitService: mockService)
        vm.deleteLocalProfileAccount()
        // Give background Task time to execute
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(mockService.saveCalled, "Tombstone save must be called on delete")
        XCTAssertFalse(mockService.deleteCalled, "Hard CKRecord.delete must NOT be called")
        if let saved = mockService.lastSavedSnapshot {
            XCTAssertTrue(saved.displayName.isEmpty, "Tombstone displayName must be empty")
            XCTAssertNil(saved.avatarImageData, "Tombstone avatar must be nil")
            XCTAssertGreaterThan(saved.updatedAt.timeIntervalSince1970, 0,
                                 "Tombstone updatedAt must be non-epoch so other devices see it as newer")
        } else {
            XCTFail("No snapshot was saved")
        }
    }

    func test_deleteAccount_clearsLocalProfileStorage() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "profile_delete_clear_\(UUID())"))
        defaults.set(Data([0xFF, 0xD8]), forKey: ProfileStorageKeys.avatarImageData)
        defaults.set("Pilot", forKey: ProfileStorageKeys.displayName)
        defaults.set("1234567", forKey: ProfileStorageKeys.gemsID)
        defaults.set(ProfileFleet.fleet747.rawValue, forKey: ProfileStorageKeys.fleet)
        defaults.set(ProfileBase.sdf.rawValue, forKey: OperationalSettings.crewBaseKey)
        defaults.set(PilotQualification.firstOfficer.rawValue, forKey: "pilot_qualification")
        defaults.set(1_700_000_100.0, forKey: ProfileStorageKeys.lastSeenAt)
        defaults.set("2027-06", forKey: ProfileStorageKeys.faaMedicalExpiryDate)
        defaults.set("2031-04-12", forKey: ProfileStorageKeys.passportExpiryDate)
        defaults.set("2028-09-30", forKey: ProfileStorageKeys.chinaVisaExpiryDate)
        defaults.set(1_700_000_000.0, forKey: ProfileStorageKeys.updatedAt)

        AppViewModel.clearLocalProfileStorageForDelete(defaults: defaults)

        XCTAssertNil(defaults.data(forKey: ProfileStorageKeys.avatarImageData))
        XCTAssertEqual(defaults.string(forKey: ProfileStorageKeys.displayName), "")
        XCTAssertEqual(defaults.string(forKey: ProfileStorageKeys.gemsID), "")
        XCTAssertEqual(defaults.string(forKey: ProfileStorageKeys.fleet), ProfileFleet.fleet757.rawValue)
        XCTAssertEqual(defaults.string(forKey: OperationalSettings.crewBaseKey), OperationalSettings.defaultCrewBase.rawValue)
        XCTAssertEqual(defaults.string(forKey: "pilot_qualification"), PilotQualification.captain.rawValue)
        XCTAssertEqual(defaults.double(forKey: ProfileStorageKeys.lastSeenAt), 0)
        XCTAssertNil(defaults.string(forKey: ProfileStorageKeys.faaMedicalExpiryDate))
        XCTAssertNil(defaults.string(forKey: ProfileStorageKeys.passportExpiryDate))
        XCTAssertNil(defaults.string(forKey: ProfileStorageKeys.chinaVisaExpiryDate))
        XCTAssertEqual(defaults.double(forKey: ProfileStorageKeys.updatedAt), 0)
    }

    // MARK: - Sync policy pure function helper

    enum SyncDecision: Equatable {
        case uploadLocal
        case updateLocalFromRemote
        case noOp
    }

    static func resolveSyncPolicy(
        local: ProfileSnapshot,
        remote: ProfileSnapshot?
    ) async throws -> SyncDecision {
        guard let remote else {
            return local.hasContent ? .uploadLocal : .noOp
        }
        if remote.updatedAt > local.updatedAt { return .updateLocalFromRemote }
        if local.updatedAt > remote.updatedAt { return .uploadLocal }
        return .noOp
    }

    @discardableResult
    private func syncProfile(
        defaults: UserDefaults,
        cloudProfile: inout ProfileSnapshot?
    ) async throws -> SyncDecision {
        let local = ProfileSnapshot.loadFromLocalStorage(defaults: defaults)
        let decision = try await Self.resolveSyncPolicy(local: local, remote: cloudProfile)
        switch decision {
        case .uploadLocal:
            cloudProfile = local
        case .updateLocalFromRemote:
            cloudProfile?.saveToLocalStorage(defaults: defaults)
        case .noOp:
            break
        }
        return decision
    }

    private func clearStandardProfileDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ProfileStorageKeys.avatarImageData)
        defaults.removeObject(forKey: ProfileStorageKeys.displayName)
        defaults.removeObject(forKey: ProfileStorageKeys.gemsID)
        defaults.removeObject(forKey: ProfileStorageKeys.fleet)
        defaults.removeObject(forKey: OperationalSettings.crewBaseKey)
        defaults.removeObject(forKey: "pilot_qualification")
        defaults.removeObject(forKey: ProfileStorageKeys.lastSeenAt)
        defaults.removeObject(forKey: ProfileStorageKeys.faaMedicalExpiryDate)
        defaults.removeObject(forKey: ProfileStorageKeys.passportExpiryDate)
        defaults.removeObject(forKey: ProfileStorageKeys.chinaVisaExpiryDate)
        defaults.removeObject(forKey: ProfileStorageKeys.updatedAt)
    }
}

// MARK: - Mock

final class MockProfileCloudKitService: ProfileCloudKitServicing, @unchecked Sendable {
    var fetchResult: ProfileSnapshot?
    let fetchDelayNanoseconds: UInt64
    let saveDelayNanoseconds: UInt64
    private(set) var saveCalled = false
    private(set) var saveCallCount = 0
    private(set) var deleteCalled = false
    private(set) var lastSavedSnapshot: ProfileSnapshot?

    init(
        fetchResult: ProfileSnapshot?,
        fetchDelayNanoseconds: UInt64 = 0,
        saveDelayNanoseconds: UInt64 = 0
    ) {
        self.fetchResult = fetchResult
        self.fetchDelayNanoseconds = fetchDelayNanoseconds
        self.saveDelayNanoseconds = saveDelayNanoseconds
    }

    func fetchProfile() async throws -> ProfileSnapshot? {
        if fetchDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: fetchDelayNanoseconds)
        }
        return fetchResult
    }

    func saveProfile(_ snapshot: ProfileSnapshot) async throws {
        if saveDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: saveDelayNanoseconds)
        }
        saveCalled = true
        saveCallCount += 1
        lastSavedSnapshot = snapshot
    }

    func deleteProfile() async throws {
        deleteCalled = true
    }
}

final class FakeProfileCloudKitDatabase: ProfileCloudKitDatabase, @unchecked Sendable {
    private var record: CKRecord?
    private(set) var savedRecord: CKRecord?
    private(set) var saveCallCount = 0

    func seed(_ record: CKRecord) {
        self.record = record
    }

    func record(for recordID: CKRecord.ID) async throws -> CKRecord {
        if let record {
            return record
        }
        throw CKError(.unknownItem)
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        saveCallCount += 1
        self.record = record
        savedRecord = record
        return record
    }

    func deleteRecord(withID recordID: CKRecord.ID) async throws -> CKRecord.ID {
        record = nil
        return recordID
    }
}

/// Records the order in which saves *commit*, applying a per-call delay so tests can
/// force out-of-order completion and verify the service serializes writes. If the
/// service ever issued concurrent saves, the slow first save would yield (actor
/// reentrancy / lock release) and the fast second save would commit first, changing
/// the recorded order and failing the assertion.
actor OrderRecordingProfileDatabase: ProfileCloudKitDatabase {
    private let saveDelaysNs: [UInt64]
    private var saveIndex = 0
    private var current: CKRecord?
    private(set) var committedGEMSIDsInOrder: [String] = []

    init(saveDelaysNs: [UInt64]) {
        self.saveDelaysNs = saveDelaysNs
    }

    func record(for recordID: CKRecord.ID) async throws -> CKRecord {
        if let current { return current }
        throw CKError(.unknownItem)
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        let index = saveIndex
        saveIndex += 1
        let delay = index < saveDelaysNs.count ? saveDelaysNs[index] : 0
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        current = record
        committedGEMSIDsInOrder.append(record["gemsID"] as? String ?? "")
        return record
    }

    func deleteRecord(withID recordID: CKRecord.ID) async throws -> CKRecord.ID {
        current = nil
        return recordID
    }
}
