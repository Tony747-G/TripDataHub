import CloudKit
import Foundation
import os

private let logger = Logger(subsystem: "com.sfune.TripDataHub", category: "FriendLink")

struct FriendScheduleCloudKitLink: Sendable {
    let friendGEMSID: String
    let isAccepted: Bool
    let linkedAt: Date?
    let requestedAt: Date?
    let requestDirection: FriendRequestDirection?

    init(
        friendGEMSID: String,
        isAccepted: Bool,
        linkedAt: Date?,
        requestedAt: Date?,
        requestDirection: FriendRequestDirection? = nil
    ) {
        self.friendGEMSID = friendGEMSID
        self.isAccepted = isAccepted
        self.linkedAt = linkedAt
        self.requestedAt = requestedAt
        self.requestDirection = isAccepted ? nil : requestDirection
    }
}

/// Connections plus, per normalized GEMS ID, whether that friend's refresh actually succeeded.
/// Failures return the cached connection so nothing is lost, which is precisely why the outcome
/// has to be reported separately — otherwise the UI cannot distinguish stale data from fresh.
struct FriendConnectionRefreshResult: Sendable {
    let connections: [FriendConnection]
    let outcomes: [String: FriendScheduleSyncOutcome]

    init(connections: [FriendConnection], outcomes: [String: FriendScheduleSyncOutcome] = [:]) {
        self.connections = connections
        self.outcomes = outcomes
    }
}

protocol FriendScheduleCloudKitServicing: Sendable {
    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws
    func uploadScheduleSnapshot(gemsID: String, ownerDisplayName: String, crewAccessTrips: [CrewAccessTripJSON]) async throws
    func requestFriend(myGEMSID: String, friendGEMSID: String, friendResetAt: Date?) async throws -> FriendScheduleCloudKitLink
    func cancelFriendRequest(myGEMSID: String, friendGEMSID: String) async throws
    func deleteSharedScheduleData(gemsID: String) async throws
    func deleteFriendSharingData(gemsID: String) async throws
    func refreshConnections(myGEMSID: String, connections: [FriendConnection], friendResetAt: Date?) async throws -> FriendConnectionRefreshResult
}

protocol FriendScheduleCloudKitDatabase {
    func record(for recordID: CKRecord.ID) async throws -> CKRecord
    func save(_ record: CKRecord) async throws -> CKRecord
    func deleteRecord(withID recordID: CKRecord.ID) async throws -> CKRecord.ID
    func records(matching query: CKQuery) async throws -> [CKRecord]
}

extension CKDatabase: FriendScheduleCloudKitDatabase {}

final class FriendScheduleCloudKitService: FriendScheduleCloudKitServicing, @unchecked Sendable {
    private enum RecordType {
        static let sharedSchedule = "TDHSharedSchedule"
        static let friendLink = "TDHFriendLink"
        static let snapshot = "TripScheduleSnapshot"
    }

    private enum SnapshotField {
        static let ownerGEMSID = "ownerGEMSID"
        static let ownerDisplayName = "ownerDisplayName"
        static let scheduleJSON = "scheduleJSON"
        static let schemaVersion = "schemaVersion"
        static let updatedAt = "updatedAt"
    }

    private enum Field {
        static let ownerGEMSID = "ownerGEMSID"
        static let ownerRecordName = "ownerRecordName"
        static let schedulesData = "schedulesData"
        static let updatedAt = "updatedAt"
        static let gemsA = "gemsA"
        static let gemsB = "gemsB"
        static let approvedA = "approvedA"
        static let approvedB = "approvedB"
        static let linkedAt = "linkedAt"
        static let requestedAt = "requestedAt"
        static let status = "status"
        static let requesterGEMSID = "requesterGEMSID"
        static let recipientGEMSID = "recipientGEMSID"
    }

    private enum LinkStatus {
        static let pending = "pending"
        static let accepted = "accepted"
        static let canceled = "canceled"
    }

    private let containerIdentifier: String
    private let databaseProvider: () -> FriendScheduleCloudKitDatabase

    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        self.databaseProvider = {
            CKContainer(identifier: containerIdentifier).publicCloudDatabase
        }
    }

    init(databaseProvider: @escaping () -> FriendScheduleCloudKitDatabase) {
        self.containerIdentifier = "test"
        self.databaseProvider = databaseProvider
    }

    /// Publishes this user's schedule for their friends.
    ///
    /// **Skips the save entirely when the stored payload already means the same thing.**
    /// This is not just an optimisation: `fetchSchedule` reports `record.modificationDate` as each
    /// schedule's `updatedAt`, and `FriendsTabView` renders the maximum of those as "Last Updated".
    /// Because this method is called on every app open / app active / Friends tab appearance, an
    /// unconditional save would advance that timestamp every time a friend merely launched the
    /// app — showing a fresh "Last Updated" against unchanged content. Writing only on real change
    /// is what makes the server modification date a truthful content-freshness signal.
    ///
    /// The comparison decodes both sides rather than comparing bytes: `JSONEncoder` gives no
    /// key-order guarantee, so two encodes of identical content are not reliably byte-equal.
    /// The new payload is round-tripped too, so both operands have been through the same
    /// encode/decode and the check answers the question that actually matters — would a reader
    /// decode the same value?
    func uploadSchedule(gemsID: String, cloudKitRecordName: String, schedules: [PayPeriodSchedule]) async throws {
        let database = databaseProvider()
        let recordID = CKRecord.ID(recordName: Self.scheduleRecordName(for: gemsID))
        let existing = try? await database.record(for: recordID)
        let record = existing ?? CKRecord(recordType: RecordType.sharedSchedule, recordID: recordID)
        let data = try JSONEncoder().encode(schedules)

        if let existing,
           existing[Field.ownerRecordName] == nil,
           existing[Field.ownerGEMSID] as? String == GEMSIDNormalizer.normalize(gemsID),
           let existingData = existing[Field.schedulesData] as? Data,
           let existingSchedules = try? JSONDecoder().decode([PayPeriodSchedule].self, from: existingData),
           let outgoingSchedules = try? JSONDecoder().decode([PayPeriodSchedule].self, from: data),
           existingSchedules == outgoingSchedules {
            logger.info("[TDHSchedule] uploadSchedule: unchanged, skipping save to preserve modificationDate")
            return
        }

        record[Field.ownerGEMSID] = GEMSIDNormalizer.normalize(gemsID) as CKRecordValue
        record[Field.ownerRecordName] = nil
        record[Field.schedulesData] = data as CKRecordValue
        record[Field.updatedAt] = Date() as CKRecordValue
        _ = try await database.save(record)
    }

    /// Publishes the web-facing snapshot.
    ///
    /// Deliberately NOT fingerprinted, unlike `uploadSchedule`. `TripScheduleSnapshotEncoder`
    /// embeds `generatedAtUTC` in the payload, so consecutive encodes of identical content are
    /// never byte-equal; skipping identical writes would need a separate content-hash field and
    /// therefore a Production schema deployment. This record's modification date is not surfaced
    /// anywhere in the app — "Last Updated" comes from `TDHSharedSchedule` via `fetchSchedule` —
    /// so republishing it costs write churn only, not a misleading timestamp.
    func uploadScheduleSnapshot(gemsID: String, ownerDisplayName: String, crewAccessTrips: [CrewAccessTripJSON]) async throws {
        let database = databaseProvider()
        let recordID = CKRecord.ID(recordName: Self.snapshotRecordName(for: gemsID))
        let record = (try? await database.record(for: recordID))
            ?? CKRecord(recordType: RecordType.snapshot, recordID: recordID)
        let json = try TripScheduleSnapshotEncoder.json(
            ownerDisplayName: ownerDisplayName,
            crewAccessTrips: crewAccessTrips
        )
        record[SnapshotField.ownerGEMSID] = GEMSIDNormalizer.normalize(gemsID) as CKRecordValue
        record[SnapshotField.ownerDisplayName] = ownerDisplayName as CKRecordValue
        record[SnapshotField.scheduleJSON] = json as CKRecordValue
        record[SnapshotField.schemaVersion] = Int64(TripScheduleSnapshotEncoder.schemaVersion) as CKRecordValue
        record[SnapshotField.updatedAt] = Date() as CKRecordValue
        _ = try await database.save(record)
    }

    func requestFriend(myGEMSID: String, friendGEMSID: String, friendResetAt: Date? = nil) async throws -> FriendScheduleCloudKitLink {
        let my = GEMSIDNormalizer.normalize(myGEMSID)
        let friend = GEMSIDNormalizer.normalize(friendGEMSID)
        let database = databaseProvider()
        let pair = Self.orderedPair(my, friend)
        let recordID = CKRecord.ID(recordName: Self.friendLinkRecordName(first: pair.first, second: pair.second))

        for attempt in 0..<3 {
            do {
                let record = try await friendLinkRecord(recordID: recordID, database: database)
                resetStaleOwnApprovalIfNeeded(
                    in: record,
                    myGEMSID: my,
                    friendGEMSID: friend,
                    pair: pair,
                    friendResetAt: friendResetAt
                )
                if isAccepted(record) {
                    return link(from: record, myGEMSID: my, friendGEMSID: friend)
                }
                if approvalAlreadyRecorded(in: record, myGEMSID: my, pair: pair) {
                    try await applyReciprocalUserOwnedApprovalIfNeeded(
                        to: record,
                        myGEMSID: my,
                        friendGEMSID: friend,
                        pair: pair,
                        database: database
                    )
                    if isAccepted(record) {
                        do {
                            let saved = try await database.save(record)
                            return link(from: saved, myGEMSID: my, friendGEMSID: friend)
                        } catch {
                            logger.error("[TDHFriendLink] canonical reciprocal approval save failed; saving user-owned approval: \(error.localizedDescription, privacy: .public)")
                            return try await saveUserOwnedFriendApproval(
                                myGEMSID: my,
                                friendGEMSID: friend,
                                pair: pair,
                                canonicalRecord: record,
                                database: database
                            )
                        }
                    }
                    return link(from: record, myGEMSID: my, friendGEMSID: friend)
                }
                applyApproval(
                    to: record,
                    myGEMSID: my,
                    friendGEMSID: friend,
                    pair: pair
                )
                try await applyReciprocalUserOwnedApprovalIfNeeded(
                    to: record,
                    myGEMSID: my,
                    friendGEMSID: friend,
                    pair: pair,
                    database: database
                )

                do {
                    let saved = try await database.save(record)
                    return link(from: saved, myGEMSID: my, friendGEMSID: friend)
                } catch let error as CKError where Self.shouldRetryFriendLinkSave(error) {
                    throw error
                } catch {
                    logger.error("[TDHFriendLink] canonical friend link save failed; saving user-owned approval: \(error.localizedDescription, privacy: .public)")
                    return try await saveUserOwnedFriendApproval(
                        myGEMSID: my,
                        friendGEMSID: friend,
                        pair: pair,
                        canonicalRecord: record,
                        database: database
                    )
                }
            } catch let error as CKError where Self.shouldRetryFriendLinkSave(error) {
                guard attempt < 2 else { throw error }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 150_000_000)
            } catch {
                throw error
            }
        }

        throw CKError(.serverRecordChanged)
    }

    private func saveUserOwnedFriendApproval(
        myGEMSID: String,
        friendGEMSID: String,
        pair: (first: String, second: String),
        canonicalRecord: CKRecord,
        database: FriendScheduleCloudKitDatabase
    ) async throws -> FriendScheduleCloudKitLink {
        let recordID = CKRecord.ID(
            recordName: Self.userOwnedFriendLinkRecordName(owner: myGEMSID, friend: friendGEMSID)
        )
        let record = (try? await database.record(for: recordID))
            ?? CKRecord(recordType: RecordType.friendLink, recordID: recordID)
        record[Field.gemsA] = pair.first as CKRecordValue
        record[Field.gemsB] = pair.second as CKRecordValue
        record[approvalField(for: myGEMSID, pair: pair)] = true as CKRecordValue
        if !hasExplicitRequestParticipants(record) {
            record[Field.requesterGEMSID] = myGEMSID as CKRecordValue
            record[Field.recipientGEMSID] = friendGEMSID as CKRecordValue
        }
        if record[Field.requestedAt] == nil {
            record[Field.requestedAt] = (canonicalRecord[Field.requestedAt] as? Date ?? Date()) as CKRecordValue
        }
        record[Field.updatedAt] = Date() as CKRecordValue

        let friendApprovedCanonical = hasApproval(from: friendGEMSID, in: canonicalRecord, pair: pair)
        let friendApprovedUserOwned = (try? await reciprocalUserOwnedApprovalExists(
                myGEMSID: myGEMSID,
                friendGEMSID: friendGEMSID,
                pair: pair,
                database: database
        )) ?? false
        if friendApprovedCanonical || friendApprovedUserOwned {
            record[Field.approvedA] = true as CKRecordValue
            record[Field.approvedB] = true as CKRecordValue
            record[Field.status] = LinkStatus.accepted as CKRecordValue
            if record[Field.linkedAt] == nil {
                record[Field.linkedAt] = Date() as CKRecordValue
            }
        } else if record[Field.status] == nil || (record[Field.status] as? String) == LinkStatus.canceled {
            record[Field.status] = LinkStatus.pending as CKRecordValue
        }

        let saved = try await database.save(record)
        return link(from: saved, myGEMSID: myGEMSID, friendGEMSID: friendGEMSID)
    }

    func cancelFriendRequest(myGEMSID: String, friendGEMSID: String) async throws {
        let my = GEMSIDNormalizer.normalize(myGEMSID)
        let friend = GEMSIDNormalizer.normalize(friendGEMSID)
        let database = databaseProvider()
        let pair = Self.orderedPair(my, friend)
        let recordID = CKRecord.ID(recordName: Self.friendLinkRecordName(first: pair.first, second: pair.second))

        for attempt in 0..<3 {
            do {
                let record: CKRecord
                do {
                    record = try await database.record(for: recordID)
                } catch let error as CKError where error.code == .unknownItem {
                    // Persist the cancellation in the canonical record. Returning with no
                    // record lets another device restore an accepted link from stale local
                    // state.
                    record = CKRecord(recordType: RecordType.friendLink, recordID: recordID)
                    record[Field.gemsA] = pair.first as CKRecordValue
                    record[Field.gemsB] = pair.second as CKRecordValue
                    record[Field.approvedA] = false as CKRecordValue
                    record[Field.approvedB] = false as CKRecordValue
                    record[Field.status] = LinkStatus.canceled as CKRecordValue
                    record[Field.updatedAt] = Date() as CKRecordValue
                    _ = try await database.save(record)
                    try await deleteUserOwnedFriendLinkRecords(
                        myGEMSID: my,
                        friendGEMSID: friend,
                        database: database
                    )
                    return
                }

                record[Field.approvedA] = false as CKRecordValue
                record[Field.approvedB] = false as CKRecordValue
                record[Field.linkedAt] = nil
                record[Field.updatedAt] = Date() as CKRecordValue

                record[Field.status] = LinkStatus.canceled as CKRecordValue
                _ = try await database.save(record)
                try await deleteUserOwnedFriendLinkRecords(
                    myGEMSID: my,
                    friendGEMSID: friend,
                    database: database
                )
                return
            } catch let error as CKError where Self.shouldRetryFriendLinkSave(error) {
                guard attempt < 2 else { throw error }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 150_000_000)
            } catch {
                throw error
            }
        }

        throw CKError(.serverRecordChanged)
    }

    private func deleteUserOwnedFriendLinkRecords(
        myGEMSID: String,
        friendGEMSID: String,
        database: FriendScheduleCloudKitDatabase
    ) async throws {
        let recordIDs = [
            CKRecord.ID(recordName: Self.userOwnedFriendLinkRecordName(owner: myGEMSID, friend: friendGEMSID)),
            CKRecord.ID(recordName: Self.userOwnedFriendLinkRecordName(owner: friendGEMSID, friend: myGEMSID))
        ]
        for recordID in recordIDs {
            try await deleteRecordIfExists(recordID, database: database)
        }
    }

    func deleteSharedScheduleData(gemsID: String) async throws {
        let normalizedGEMSID = GEMSIDNormalizer.normalize(gemsID)
        let database = databaseProvider()
        try await deleteRecordIfExists(
            CKRecord.ID(recordName: Self.scheduleRecordName(for: normalizedGEMSID)),
            database: database
        )
        try await deleteRecordIfExists(
            CKRecord.ID(recordName: Self.snapshotRecordName(for: normalizedGEMSID)),
            database: database
        )
    }

    func deleteFriendSharingData(gemsID: String) async throws {
        let normalizedGEMSID = GEMSIDNormalizer.normalize(gemsID)
        let database = databaseProvider()

        async let firstSide = friendLinkRecords(field: Field.gemsA, gemsID: normalizedGEMSID, database: database)
        async let secondSide = friendLinkRecords(field: Field.gemsB, gemsID: normalizedGEMSID, database: database)
        let linkRecords = try await firstSide + secondSide
        var seenRecordNames: Set<String> = []

        for record in linkRecords where seenRecordNames.insert(record.recordID.recordName).inserted {
            let gemsA = GEMSIDNormalizer.normalize(record[Field.gemsA] as? String ?? "")
            let gemsB = GEMSIDNormalizer.normalize(record[Field.gemsB] as? String ?? "")
            let pair = Self.orderedPair(gemsA, gemsB)
            let myApprovalField = approvalField(for: normalizedGEMSID, pair: pair)
            let otherApprovalField = myApprovalField == Field.approvedA ? Field.approvedB : Field.approvedA
            let otherApprovalRemains = boolValue(record[otherApprovalField])

            record[myApprovalField] = false as CKRecordValue
            record[Field.linkedAt] = nil
            if otherApprovalRemains {
                let otherGEMSID = gemsA == normalizedGEMSID ? gemsB : gemsA
                record[Field.requesterGEMSID] = otherGEMSID as CKRecordValue
                record[Field.recipientGEMSID] = normalizedGEMSID as CKRecordValue
                record[Field.status] = LinkStatus.pending as CKRecordValue
            } else {
                record[Field.requesterGEMSID] = nil
                record[Field.recipientGEMSID] = nil
                record[Field.status] = LinkStatus.canceled as CKRecordValue
            }
            record[Field.updatedAt] = Date() as CKRecordValue
            _ = try await database.save(record)
        }

        try await deleteSharedScheduleData(gemsID: normalizedGEMSID)
    }

    func refreshConnections(myGEMSID: String, connections: [FriendConnection], friendResetAt: Date? = nil) async throws -> FriendConnectionRefreshResult {
        let my = GEMSIDNormalizer.normalize(myGEMSID)
        let database = databaseProvider()

        // Discovering links needs a CKQuery on gemsA/gemsB, which fails outright if those fields
        // have no Queryable index in the target CloudKit environment — a very easy thing to have
        // in Development but not Production. Letting that throw would abort the whole refresh and
        // leave every friend showing cached (stale) data. Degrade instead: known friends are
        // still refreshed below by record ID, which needs no index. Only the discovery of links
        // this device has never seen is lost.
        let discoveredConnections: [FriendConnection]
        do {
            discoveredConnections = try await cloudConnections(
                myGEMSID: my,
                friendResetAt: friendResetAt,
                database: database
            )
        } catch {
            logger.error(
                "[TDHFriendLink] friend link query failed; refreshing known friends by record ID only: \(error.localizedDescription, privacy: .public)"
            )
            discoveredConnections = []
        }

        let mergedConnections = mergeConnections(connections + discoveredConnections)
        var refreshed = Array(repeating: FriendConnection(employeeID: "", status: .pending), count: mergedConnections.count)

        // Per-friend outcomes are reported alongside the connections. Returning only the cached
        // connection on failure made a failed refresh indistinguishable from a successful one, so
        // the Friends list could not tell "synced, nothing upcoming" from "could not sync".
        var outcomes: [String: FriendScheduleSyncOutcome] = [:]

        await withTaskGroup(of: (Int, FriendConnection, FriendScheduleSyncOutcome).self) { group in
            for (index, connection) in mergedConnections.enumerated() {
                group.addTask {
                    do {
                        let updated = try await self.refreshConnection(
                            connection,
                            myGEMSID: my,
                            friendResetAt: friendResetAt,
                            database: database
                        )
                        return (index, updated, .succeeded)
                    } catch {
                        logger.error(
                            "[TDHFriendLink] refreshConnection failed; preserving cached friend: \(error.localizedDescription, privacy: .public)"
                        )
                        return (index, connection, .failed(.fetchError))
                    }
                }
            }

            for await (index, connection, outcome) in group {
                refreshed[index] = connection
                outcomes[GEMSIDNormalizer.normalize(connection.employeeID)] = outcome
            }
        }

        return FriendConnectionRefreshResult(connections: refreshed, outcomes: outcomes)
    }

    private func cloudConnections(
        myGEMSID: String,
        friendResetAt: Date?,
        database: FriendScheduleCloudKitDatabase
    ) async throws -> [FriendConnection] {
        async let firstSide = friendLinkRecords(field: Field.gemsA, gemsID: myGEMSID, database: database)
        async let secondSide = friendLinkRecords(field: Field.gemsB, gemsID: myGEMSID, database: database)
        let firstRecords = try await firstSide
        let secondRecords = try await secondSide
        let records = firstRecords + secondRecords
        var seenRecordNames: Set<String> = []
        var connections: [FriendConnection] = []

        for record in records where seenRecordNames.insert(record.recordID.recordName).inserted {
            let gemsA = GEMSIDNormalizer.normalize(record[Field.gemsA] as? String ?? "")
            let gemsB = GEMSIDNormalizer.normalize(record[Field.gemsB] as? String ?? "")
            guard gemsA == myGEMSID || gemsB == myGEMSID else { continue }
            let friend = gemsA == myGEMSID ? gemsB : gemsA
            guard !friend.isEmpty else { continue }
            let link = self.link(from: record, myGEMSID: myGEMSID, friendGEMSID: friend)
            guard shouldKeepCloudLink(link, friendResetAt: friendResetAt) else { continue }
            connections.append(
                FriendConnection(
                    employeeID: friend,
                    status: link.isAccepted ? .accepted : .pending,
                    requestDirection: link.requestDirection,
                    requestedAt: link.requestedAt ?? Date(),
                    linkedAt: link.isAccepted ? (link.linkedAt ?? Date()) : nil
                )
            )
        }

        return mergeConnections(connections)
    }

    private func friendLinkRecords(
        field: String,
        gemsID: String,
        database: FriendScheduleCloudKitDatabase
    ) async throws -> [CKRecord] {
        let query = CKQuery(
            recordType: RecordType.friendLink,
            predicate: NSPredicate(format: "%K == %@", field, gemsID)
        )
        return try await database.records(matching: query)
    }

    private func refreshConnection(
        _ connection: FriendConnection,
        myGEMSID: String,
        friendResetAt: Date?,
        database: FriendScheduleCloudKitDatabase
    ) async throws -> FriendConnection {
        let friend = GEMSIDNormalizer.normalize(connection.employeeID)
        let pair = Self.orderedPair(myGEMSID, friend)
        let recordID = CKRecord.ID(recordName: Self.friendLinkRecordName(first: pair.first, second: pair.second))
        let record: CKRecord?
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = nil
        } catch {
            throw error
        }
        logger.info("[TDHFriendLink] refreshConnection: friend=\(friend, privacy: .private) recordFound=\(record != nil, privacy: .public) connectionStatus=\(connection.status.rawValue, privacy: .public)")

        guard let record else {
            var fallback = connection
            if let restored = try await restoreAcceptedLinkIfPossible(
                connection,
                myGEMSID: myGEMSID,
                pair: pair,
                record: CKRecord(recordType: RecordType.friendLink, recordID: recordID),
                canCreateAcceptedRecord: true,
                friendResetAt: friendResetAt,
                database: database
            ) {
                return restored
            }
            if connection.status == .accepted {
                return connection
            }
            if connection.status == .pending {
                guard shouldReapplyLocalPendingApproval(connection, friendResetAt: friendResetAt) else {
                    fallback.status = .pending
                    fallback.linkedAt = nil
                    fallback.acceptedAt = nil
                    fallback.sharedSchedules = []
                    return fallback
                }
                let migratedRecord = CKRecord(recordType: RecordType.friendLink, recordID: recordID)
                applyApproval(to: migratedRecord, myGEMSID: myGEMSID, friendGEMSID: friend, pair: pair)
                do {
                    _ = try await database.save(migratedRecord)
                    logger.info("[TDHFriendLink] refreshConnection: re-applied local approval to pending CloudKit link")
                } catch {
                    logger.error("[TDHFriendLink] local approval re-apply failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            fallback.status = .pending
            fallback.linkedAt = nil
            fallback.sharedSchedules = []
            return fallback
        }

        do {
            try await backfillFriendLinkMetadataIfNeeded(
                record,
                myGEMSID: myGEMSID,
                friendGEMSID: friend,
                pair: pair,
                database: database
            )
        } catch {
            logger.error("[TDHFriendLink] metadata backfill failed: \(error.localizedDescription, privacy: .public)")
        }

        let link = self.link(from: record, myGEMSID: myGEMSID, friendGEMSID: friend)
        logger.info("[TDHFriendLink] refreshConnection: link.isAccepted=\(link.isAccepted, privacy: .public) status=\(record["status"] as? String ?? "nil", privacy: .public)")
        var updated = connection
        if link.isAccepted {
            updated.status = .accepted
            updated.linkedAt = link.linkedAt ?? updated.linkedAt ?? Date()
            updated.acceptedAt = updated.acceptedAt ?? updated.linkedAt ?? Date()
            do {
                updated.sharedSchedules = try await fetchSchedule(gemsID: friend, database: database)
            } catch {
                logger.error("[TDHFriendLink] refreshConnection: fetchSchedule failed (accepted): \(error.localizedDescription, privacy: .public)")
                updated.sharedSchedules = connection.sharedSchedules
            }
        } else {
            let isExplicitlyCanceled = (record[Field.status] as? String) == LinkStatus.canceled
            if !isExplicitlyCanceled {
                if let restored = try await restoreAcceptedLinkIfPossible(
                    connection,
                    myGEMSID: myGEMSID,
                    pair: pair,
                    record: record,
                    canCreateAcceptedRecord: false,
                    friendResetAt: friendResetAt,
                    database: database
                ) {
                    return restored
                }
                if shouldReapplyLocalPendingApproval(connection, friendResetAt: friendResetAt),
                   link.requestDirection != .incoming,
                   !hasApproval(from: myGEMSID, in: record, pair: pair) {
                    applyApproval(to: record, myGEMSID: myGEMSID, friendGEMSID: friend, pair: pair)
                    let healedLink: FriendScheduleCloudKitLink?
                    do {
                        let saved = try await database.save(record)
                        healedLink = self.link(from: saved, myGEMSID: myGEMSID, friendGEMSID: friend)
                        logger.info("[TDHFriendLink] refreshConnection: re-apply saved, healedLink.isAccepted=\(healedLink?.isAccepted ?? false, privacy: .public)")
                    } catch {
                        logger.error("[TDHFriendLink] approval re-apply failed: \(error.localizedDescription, privacy: .public)")
                        healedLink = nil
                    }
                    if healedLink?.isAccepted == true {
                        updated.status = .accepted
                        updated.requestDirection = nil
                        updated.linkedAt = healedLink?.linkedAt ?? updated.linkedAt ?? Date()
                        updated.acceptedAt = updated.acceptedAt ?? updated.linkedAt ?? Date()
                        do {
                            updated.sharedSchedules = try await fetchSchedule(gemsID: friend, database: database)
                        } catch {
                            logger.error("[TDHFriendLink] refreshConnection: fetchSchedule failed (healed): \(error.localizedDescription, privacy: .public)")
                            updated.sharedSchedules = connection.sharedSchedules
                        }
                    } else {
                        updated.status = .pending
                        updated.requestDirection = healedLink?.requestDirection ?? link.requestDirection
                        updated.requestedAt = healedLink?.requestedAt ?? link.requestedAt ?? updated.requestedAt
                        updated.linkedAt = nil
                        updated.acceptedAt = nil
                        updated.sharedSchedules = []
                    }
                } else {
                    updated.status = .pending
                    updated.requestDirection = link.requestDirection
                    updated.requestedAt = link.requestedAt ?? updated.requestedAt
                    updated.linkedAt = nil
                    updated.acceptedAt = nil
                    updated.sharedSchedules = []
                }
            } else {
                updated.status = .pending
                updated.requestDirection = .outgoing
                updated.linkedAt = nil
                updated.acceptedAt = nil
                updated.sharedSchedules = []
            }
        }
        return updated
    }

    private func shouldKeepCloudLink(_ link: FriendScheduleCloudKitLink, friendResetAt: Date?) -> Bool {
        guard let friendResetAt else { return true }
        let timestamp = link.linkedAt ?? link.requestedAt ?? Date.distantPast
        if link.isAccepted {
            return timestamp >= friendResetAt
        }
        if link.requestDirection == .incoming {
            return true
        }
        return timestamp >= friendResetAt
    }

    private func shouldReapplyLocalPendingApproval(_ connection: FriendConnection, friendResetAt: Date?) -> Bool {
        guard connection.status == .pending, connection.requestDirection != .incoming else {
            return false
        }
        guard let friendResetAt else { return true }
        return connection.requestedAt >= friendResetAt
    }

    private func resetStaleOwnApprovalIfNeeded(
        in record: CKRecord,
        myGEMSID: String,
        friendGEMSID: String,
        pair: (first: String, second: String),
        friendResetAt: Date?
    ) {
        guard let friendResetAt else { return }
        let timestamp = (record[Field.linkedAt] as? Date)
            ?? (record[Field.requestedAt] as? Date)
            ?? record.creationDate
            ?? Date.distantPast
        guard timestamp < friendResetAt else { return }
        guard hasApproval(from: myGEMSID, in: record, pair: pair) else { return }

        record[approvalField(for: myGEMSID, pair: pair)] = false as CKRecordValue
        record[Field.linkedAt] = nil
        record[Field.requestedAt] = nil
        if hasApproval(from: friendGEMSID, in: record, pair: pair) {
            record[Field.requesterGEMSID] = friendGEMSID as CKRecordValue
            record[Field.recipientGEMSID] = myGEMSID as CKRecordValue
            record[Field.status] = LinkStatus.pending as CKRecordValue
        } else {
            record[Field.requesterGEMSID] = nil
            record[Field.recipientGEMSID] = nil
            record[Field.status] = LinkStatus.canceled as CKRecordValue
        }
        record[Field.updatedAt] = Date() as CKRecordValue
    }

    private func restoreAcceptedLinkIfPossible(
        _ connection: FriendConnection,
        myGEMSID: String,
        pair: (first: String, second: String),
        record: CKRecord,
        canCreateAcceptedRecord: Bool,
        friendResetAt: Date?,
        database: FriendScheduleCloudKitDatabase
    ) async throws -> FriendConnection? {
        guard let acceptedAt = connection.acceptedAt ?? (connection.status == .accepted ? connection.linkedAt : nil) else {
            return nil
        }
        if let friendResetAt, acceptedAt < friendResetAt {
            return nil
        }
        guard canCreateAcceptedRecord || isAccepted(record) else {
            return nil
        }
        record[Field.gemsA] = pair.first as CKRecordValue
        record[Field.gemsB] = pair.second as CKRecordValue
        record[Field.approvedA] = true as CKRecordValue
        record[Field.approvedB] = true as CKRecordValue
        record[Field.status] = LinkStatus.accepted as CKRecordValue
        record[Field.linkedAt] = acceptedAt as CKRecordValue
        if record[Field.requestedAt] == nil {
            record[Field.requestedAt] = connection.requestedAt as CKRecordValue
        }
        record[Field.updatedAt] = Date() as CKRecordValue
        let saved = try await database.save(record)
        let friend = pair.first == myGEMSID ? pair.second : pair.first
        let link = self.link(from: saved, myGEMSID: myGEMSID, friendGEMSID: friend)
        guard link.isAccepted else { return nil }
        var restored = connection
        restored.status = .accepted
        restored.linkedAt = link.linkedAt ?? acceptedAt
        restored.acceptedAt = acceptedAt
        do {
            restored.sharedSchedules = try await fetchSchedule(gemsID: friend, database: database)
        } catch {
            logger.error("[TDHFriendLink] refreshConnection: fetchSchedule failed (accepted-restore): \(error.localizedDescription, privacy: .public)")
            restored.sharedSchedules = connection.sharedSchedules
        }
        logger.info("[TDHFriendLink] restored accepted friend link from local acceptedAt proof")
        return restored
    }

    private func fetchSchedule(gemsID: String, database: FriendScheduleCloudKitDatabase) async throws -> [PayPeriodSchedule] {
        let recordID = CKRecord.ID(recordName: Self.scheduleRecordName(for: gemsID))
        logger.info("[TDHSchedule] fetchSchedule: attempting recordName=\(recordID.recordName, privacy: .private)")
        do {
            let record = try await database.record(for: recordID)
            guard let data = record[Field.schedulesData] as? Data else {
                logger.info("[TDHSchedule] fetchSchedule: record found but no schedulesData field")
                return []
            }
            let schedules = try JSONDecoder().decode([PayPeriodSchedule].self, from: data)
            let authoritativeUpdatedAt = record.modificationDate ?? (record[Field.updatedAt] as? Date)
            let serverDatedSchedules = schedules.map { schedule in
                guard let authoritativeUpdatedAt else { return schedule }
                return PayPeriodSchedule(
                    id: schedule.id,
                    label: schedule.label,
                    tripCount: schedule.tripCount,
                    legCount: schedule.legCount,
                    openTimeCount: schedule.openTimeCount,
                    updatedAt: authoritativeUpdatedAt,
                    legs: schedule.legs,
                    openTimeTrips: schedule.openTimeTrips
                )
            }
            logger.info("[TDHSchedule] fetchSchedule: success, \(schedules.count, privacy: .public) schedules")
            return serverDatedSchedules
        } catch {
            logger.error("[TDHSchedule] fetchSchedule: FAILED error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func friendLinkRecord(
        recordID: CKRecord.ID,
        database: FriendScheduleCloudKitDatabase
    ) async throws -> CKRecord {
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return CKRecord(recordType: RecordType.friendLink, recordID: recordID)
        }
    }

    private func deleteRecordIfExists(
        _ recordID: CKRecord.ID,
        database: FriendScheduleCloudKitDatabase
    ) async throws {
        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return
        }
    }

    private func applyApproval(
        to record: CKRecord,
        myGEMSID: String,
        friendGEMSID: String,
        pair: (first: String, second: String)
    ) {
        record[Field.gemsA] = pair.first as CKRecordValue
        record[Field.gemsB] = pair.second as CKRecordValue
        record[approvalField(for: myGEMSID, pair: pair)] = true as CKRecordValue
        let now = Date()
        let isNewRequest = record[Field.requestedAt] == nil || (record[Field.status] as? String) == LinkStatus.canceled
        if isNewRequest {
            record[Field.requestedAt] = now as CKRecordValue
        }
        if isNewRequest || !hasExplicitRequestParticipants(record) {
            record[Field.requesterGEMSID] = myGEMSID as CKRecordValue
            record[Field.recipientGEMSID] = friendGEMSID as CKRecordValue
        }
        record[Field.updatedAt] = now as CKRecordValue

        if isAccepted(record) {
            record[Field.status] = LinkStatus.accepted as CKRecordValue
            if record[Field.linkedAt] == nil {
                record[Field.linkedAt] = now as CKRecordValue
            }
        } else if record[Field.status] == nil || (record[Field.status] as? String) == LinkStatus.canceled {
            record[Field.status] = LinkStatus.pending as CKRecordValue
        }
    }

    private func link(from record: CKRecord, myGEMSID: String, friendGEMSID: String) -> FriendScheduleCloudKitLink {
        let pair = Self.orderedPair(myGEMSID, friendGEMSID)
        let myApproved = hasApproval(from: myGEMSID, in: record, pair: pair)
        let friendApproved = hasApproval(from: friendGEMSID, in: record, pair: pair)
        let direction: FriendRequestDirection?
        if isAccepted(record) {
            direction = nil
        } else if explicitRequester(record) == myGEMSID {
            direction = .outgoing
        } else if explicitRecipient(record) == myGEMSID {
            direction = .incoming
        } else if friendApproved && !myApproved {
            direction = .incoming
        } else {
            direction = .outgoing
        }
        return FriendScheduleCloudKitLink(
            friendGEMSID: friendGEMSID,
            isAccepted: isAccepted(record),
            linkedAt: record[Field.linkedAt] as? Date,
            requestedAt: (record[Field.requestedAt] as? Date) ?? record.creationDate ?? (record[Field.updatedAt] as? Date),
            requestDirection: direction
        )
    }

    private func backfillFriendLinkMetadataIfNeeded(
        _ record: CKRecord,
        myGEMSID: String,
        friendGEMSID: String,
        pair: (first: String, second: String),
        database: FriendScheduleCloudKitDatabase
    ) async throws {
        var needsSave = false
        if isAccepted(record), (record[Field.status] as? String) != LinkStatus.accepted {
            record[Field.status] = LinkStatus.accepted as CKRecordValue
            needsSave = true
        }
        if isAccepted(record), record[Field.linkedAt] == nil {
            record[Field.linkedAt] = Date() as CKRecordValue
            needsSave = true
        }
        if !isAccepted(record),
           (record[Field.status] as? String) != LinkStatus.canceled,
           !hasExplicitRequestParticipants(record) {
            if hasApproval(from: friendGEMSID, in: record, pair: pair),
               !hasApproval(from: myGEMSID, in: record, pair: pair) {
                record[Field.requesterGEMSID] = friendGEMSID as CKRecordValue
                record[Field.recipientGEMSID] = myGEMSID as CKRecordValue
                needsSave = true
            } else if hasApproval(from: myGEMSID, in: record, pair: pair) {
                record[Field.requesterGEMSID] = myGEMSID as CKRecordValue
                record[Field.recipientGEMSID] = friendGEMSID as CKRecordValue
                needsSave = true
            }
        }
        if needsSave {
            record[Field.updatedAt] = Date() as CKRecordValue
            _ = try await database.save(record)
        }
    }

    private func isAccepted(_ record: CKRecord) -> Bool {
        if (record[Field.status] as? String) == LinkStatus.canceled {
            return false
        }
        if (record[Field.status] as? String) == LinkStatus.accepted {
            return true
        }
        if record[Field.linkedAt] != nil {
            return true
        }
        return boolValue(record[Field.approvedA]) && boolValue(record[Field.approvedB])
    }

    private func approvalAlreadyRecorded(
        in record: CKRecord,
        myGEMSID: String,
        pair: (first: String, second: String)
    ) -> Bool {
        guard (record[Field.status] as? String) != LinkStatus.canceled else {
            return false
        }
        return boolValue(record[approvalField(for: myGEMSID, pair: pair)])
    }

    private func hasApproval(
        from gemsID: String,
        in record: CKRecord,
        pair: (first: String, second: String)
    ) -> Bool {
        guard (record[Field.status] as? String) != LinkStatus.canceled else {
            return false
        }
        return boolValue(record[approvalField(for: gemsID, pair: pair)])
    }

    private func explicitRequester(_ record: CKRecord) -> String {
        GEMSIDNormalizer.normalize(record[Field.requesterGEMSID] as? String ?? "")
    }

    private func explicitRecipient(_ record: CKRecord) -> String {
        GEMSIDNormalizer.normalize(record[Field.recipientGEMSID] as? String ?? "")
    }

    private func hasExplicitRequestParticipants(_ record: CKRecord) -> Bool {
        !explicitRequester(record).isEmpty && !explicitRecipient(record).isEmpty
    }

    private func reciprocalUserOwnedApprovalExists(
        myGEMSID: String,
        friendGEMSID: String,
        pair: (first: String, second: String),
        database: FriendScheduleCloudKitDatabase
    ) async throws -> Bool {
        let recordID = CKRecord.ID(
            recordName: Self.userOwnedFriendLinkRecordName(owner: friendGEMSID, friend: myGEMSID)
        )
        do {
            let record = try await database.record(for: recordID)
            if hasApproval(from: friendGEMSID, in: record, pair: pair) {
                return true
            }
        } catch let error as CKError where error.code == .unknownItem {
            return try await reciprocalApprovalExistsInQueryableRecords(
                friendGEMSID: friendGEMSID,
                pair: pair,
                database: database
            )
        }
        return try await reciprocalApprovalExistsInQueryableRecords(
            friendGEMSID: friendGEMSID,
            pair: pair,
            database: database
        )
    }

    private func reciprocalApprovalExistsInQueryableRecords(
        friendGEMSID: String,
        pair: (first: String, second: String),
        database: FriendScheduleCloudKitDatabase
    ) async throws -> Bool {
        async let firstSide = friendLinkRecords(field: Field.gemsA, gemsID: pair.first, database: database)
        async let secondSide = friendLinkRecords(field: Field.gemsB, gemsID: pair.second, database: database)
        let records = try await firstSide + secondSide
        return records.contains { record in
            record.recordID.recordName.hasPrefix("tdh_friend_user_")
                && GEMSIDNormalizer.normalize(record[Field.gemsA] as? String ?? "") == pair.first
                && GEMSIDNormalizer.normalize(record[Field.gemsB] as? String ?? "") == pair.second
                && hasApproval(from: friendGEMSID, in: record, pair: pair)
        }
    }

    private func applyReciprocalUserOwnedApprovalIfNeeded(
        to record: CKRecord,
        myGEMSID: String,
        friendGEMSID: String,
        pair: (first: String, second: String),
        database: FriendScheduleCloudKitDatabase
    ) async throws {
        guard try await reciprocalUserOwnedApprovalExists(
            myGEMSID: myGEMSID,
            friendGEMSID: friendGEMSID,
            pair: pair,
            database: database
        ) else { return }

        record[Field.approvedA] = true as CKRecordValue
        record[Field.approvedB] = true as CKRecordValue
        record[Field.status] = LinkStatus.accepted as CKRecordValue
        if record[Field.linkedAt] == nil {
            record[Field.linkedAt] = Date() as CKRecordValue
        }
        if record[Field.requestedAt] == nil {
            record[Field.requestedAt] = Date() as CKRecordValue
        }
        record[Field.updatedAt] = Date() as CKRecordValue
    }

    private func mergeConnections(_ connections: [FriendConnection]) -> [FriendConnection] {
        var merged: [FriendConnection] = []
        for connection in connections {
            let employeeID = GEMSIDNormalizer.normalize(connection.employeeID)
            guard !employeeID.isEmpty else { continue }
            let normalized = FriendConnection(
                id: connection.id,
                employeeID: employeeID,
                nickname: connection.nickname,
                avatarImageData: connection.avatarImageData,
                status: connection.status,
                requestDirection: connection.requestDirection,
                requestedAt: connection.requestedAt,
                linkedAt: connection.linkedAt,
                acceptedAt: connection.acceptedAt,
                sharedSchedules: connection.sharedSchedules,
                sharedTimelineCards: connection.sharedTimelineCards
            )
            if let index = merged.firstIndex(where: { $0.employeeID == employeeID }) {
                merged[index] = mergedConnection(merged[index], normalized)
            } else {
                merged.append(normalized)
            }
        }
        return merged
    }

    private func mergedConnection(_ lhs: FriendConnection, _ rhs: FriendConnection) -> FriendConnection {
        let accepted = lhs.status == .accepted || rhs.status == .accepted
        let acceptedAt = lhs.acceptedAt ?? rhs.acceptedAt
        return FriendConnection(
            id: lhs.id,
            employeeID: lhs.employeeID,
            nickname: lhs.nickname ?? rhs.nickname,
            avatarImageData: lhs.avatarImageData ?? rhs.avatarImageData,
            status: (accepted || acceptedAt != nil) ? .accepted : .pending,
            requestDirection: (accepted || acceptedAt != nil) ? nil : (lhs.requestDirection == .incoming || rhs.requestDirection == .incoming ? .incoming : .outgoing),
            requestedAt: min(lhs.requestedAt, rhs.requestedAt),
            linkedAt: lhs.linkedAt ?? rhs.linkedAt,
            acceptedAt: acceptedAt,
            sharedSchedules: lhs.sharedSchedules.isEmpty ? rhs.sharedSchedules : lhs.sharedSchedules,
            sharedTimelineCards: lhs.sharedTimelineCards.isEmpty ? rhs.sharedTimelineCards : lhs.sharedTimelineCards
        )
    }

    private func approvalField(
        for gemsID: String,
        pair: (first: String, second: String)
    ) -> String {
        gemsID == pair.first ? Field.approvedA : Field.approvedB
    }

    private func boolValue(_ value: CKRecordValue?) -> Bool {
        (value as? NSNumber)?.boolValue ?? (value as? Bool) ?? false
    }

    private static func shouldRetryFriendLinkSave(_ error: CKError) -> Bool {
        switch error.code {
        case .serverRecordChanged,
             .zoneBusy,
             .serviceUnavailable,
             .requestRateLimited,
             .networkFailure,
             .networkUnavailable:
            return true
        default:
            return false
        }
    }

    private static func orderedPair(_ lhs: String, _ rhs: String) -> (first: String, second: String) {
        lhs < rhs ? (lhs, rhs) : (rhs, lhs)
    }

    private static func scheduleRecordName(for gemsID: String) -> String {
        "tdh_schedule_\(normalizedRecordComponent(gemsID))"
    }

    private static func snapshotRecordName(for gemsID: String) -> String {
        "tdh_snapshot_\(normalizedRecordComponent(gemsID))"
    }

    private static func friendLinkRecordName(first: String, second: String) -> String {
        "tdh_friend_\(normalizedRecordComponent(first))_\(normalizedRecordComponent(second))"
    }

    private static func userOwnedFriendLinkRecordName(owner: String, friend: String) -> String {
        "tdh_friend_user_\(normalizedRecordComponent(owner))_\(normalizedRecordComponent(friend))"
    }

    private static func normalizedRecordComponent(_ raw: String) -> String {
        GEMSIDNormalizer.normalize(raw)
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
