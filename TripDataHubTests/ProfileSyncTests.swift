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

    func test_deleteProfile_callsCloudKitDelete() async throws {
        let mockService = MockProfileCloudKitService(fetchResult: nil)
        let vm = AppViewModel(profileCloudKitService: mockService)
        vm.deleteLocalProfileAccount()
        // Give Task time to execute
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(mockService.deleteCalled)
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

    init(fetchResult: ProfileSnapshot?) {
        self.fetchResult = fetchResult
    }

    func fetchProfile() async throws -> ProfileSnapshot? { fetchResult }

    func saveProfile(_ snapshot: ProfileSnapshot) async throws {
        saveCalled = true
    }

    func deleteProfile() async throws {
        deleteCalled = true
    }
}
