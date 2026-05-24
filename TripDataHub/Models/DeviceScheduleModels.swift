import Foundation

enum DeviceScheduleSyncSource: String, Codable, Sendable {
    case iphone
    case ipad
    case unknown
}

struct DeviceScheduleSnapshot: Sendable {
    let ownerGEMSID: String
    let ownerRecordName: String
    let schedules: [PayPeriodSchedule]
    let schemaVersion: Int
    let updatedAt: Date
    let deviceID: String
    let source: DeviceScheduleSyncSource
}

struct ManualEventCloudKitSnapshot: Sendable {
    let ownerGEMSID: String
    let ownerRecordName: String
    let manualEvents: ManualEventStoreSnapshot
    let schemaVersion: Int
    let updatedAt: Date
    let deviceID: String
    let source: DeviceScheduleSyncSource
}
