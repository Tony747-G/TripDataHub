import CloudKit
import XCTest
@testable import TripDataHub

@MainActor
final class ProfileSyncTests: XCTestCase {

    // MARK: - ProfileSnapshot encode/decode

    func test_profileSnapshot_roundTrip() throws {
        let original = ProfileSnapshot(
            gemsID: "G12345",
            displayName: "Tony",
            fleet: "757",
            base: "ANC",
            position: "CA",
            avatarImageData: Data([0xFF, 0xD8, 0xFF]),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProfileSnapshot.self, from: data)
        XCTAssertEqual(original, decoded)
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
        defaults.set(1_700_000_000.0, forKey: ProfileStorageKeys.updatedAt)

        AppViewModel.clearLocalProfileStorageForDelete(defaults: defaults)

        XCTAssertNil(defaults.data(forKey: ProfileStorageKeys.avatarImageData))
        XCTAssertEqual(defaults.string(forKey: ProfileStorageKeys.displayName), "")
        XCTAssertEqual(defaults.string(forKey: ProfileStorageKeys.gemsID), "")
        XCTAssertEqual(defaults.string(forKey: ProfileStorageKeys.fleet), ProfileFleet.fleet757.rawValue)
        XCTAssertEqual(defaults.string(forKey: OperationalSettings.crewBaseKey), OperationalSettings.defaultCrewBase.rawValue)
        XCTAssertEqual(defaults.string(forKey: "pilot_qualification"), PilotQualification.captain.rawValue)
        XCTAssertEqual(defaults.double(forKey: ProfileStorageKeys.lastSeenAt), 0)
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
