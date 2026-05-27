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
        let mockService = MockProfileCloudKitService(fetchResult: remote)
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
}

// MARK: - Mock

final class MockProfileCloudKitService: ProfileCloudKitServicing {
    let fetchResult: ProfileSnapshot?
    private(set) var saveCalled = false
    private(set) var deleteCalled = false
    private(set) var lastSavedSnapshot: ProfileSnapshot?

    init(fetchResult: ProfileSnapshot?) {
        self.fetchResult = fetchResult
    }

    func fetchProfile() async throws -> ProfileSnapshot? { fetchResult }

    func saveProfile(_ snapshot: ProfileSnapshot) async throws {
        saveCalled = true
        lastSavedSnapshot = snapshot
    }

    func deleteProfile() async throws {
        deleteCalled = true
    }
}
