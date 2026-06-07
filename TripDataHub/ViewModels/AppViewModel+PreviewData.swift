#if DEBUG
import Foundation

extension AppViewModel {
    static var previewSchedules: [PayPeriodSchedule] {
        let legs2602 = [
            TripLeg(
                payPeriod: "PP26-02",
                pairing: "51311",
                leg: 1,
                flight: "110",
                depAirport: "ANC",
                depLocal: "2026-01-25 06:15",
                arrAirport: "NRT",
                arrLocal: "2026-01-26 07:55",
                status: "DH",
                block: "7:40"
            )
        ]
        let open2602 = [
            OpenTimeTrip(
                payPeriod: "PP26-02",
                pairing: "A70330R",
                startLocal: "2026-02-17 22:23",
                endLocal: "2026-02-24 22:23",
                route: "ANC SDF DWC SZX",
                credit: "44:48",
                requestType: "PC",
                status: "-"
            )
        ]
        let legs2603 = [
            TripLeg(
                payPeriod: "PP26-03",
                pairing: "A70878",
                leg: 3,
                flight: "184",
                depAirport: "NRT",
                depLocal: "2026-03-08 20:20",
                arrAirport: "HNL",
                arrLocal: "2026-03-08 08:10",
                status: "CML",
                block: "6:50"
            )
        ]
        let open2603 = [
            OpenTimeTrip(
                payPeriod: "PP26-03",
                pairing: "A70788",
                startLocal: "2026-02-23 22:01",
                endLocal: "2026-03-03 22:23",
                route: "ANC SDF DWC CGN HKG",
                credit: "51:18",
                requestType: "PO",
                status: "-"
            )
        ]

        return [
            PayPeriodSchedule(
                id: "PP26-02",
                label: "PP26-02",
                tripCount: 2,
                legCount: 4,
                openTimeCount: 7,
                updatedAt: Date(),
                legs: legs2602,
                openTimeTrips: open2602
            ),
            PayPeriodSchedule(
                id: "PP26-03",
                label: "PP26-03",
                tripCount: 2,
                legCount: 9,
                openTimeCount: 60,
                updatedAt: Date(),
                legs: legs2603,
                openTimeTrips: open2603
            )
        ]
    }

    func applyDebugLaunchOverridesIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments

        if arguments.contains("UITEST_TIMELINE_SEED") {
            isOpenTimeDemoMode = false
            let seededCrewSchedules = Self.uiTestTimelineSchedules
            crewAccessSchedules = seededCrewSchedules
            bidproSchedules = []
            schedules = seededCrewSchedules
            lastSyncAt = Date(timeIntervalSince1970: 1_767_494_400) // 2026-01-06T00:00:00Z
            lastImportSummaryMessage = nil
            errorMessage = nil
        }

        if arguments.contains("UITEST_LOGGED_OUT_VERIFIED") {
            isOpenTimeDemoMode = false
            let recordName = currentCloudKitRecordName ?? "UITEST-LOCAL-IDENTITY"
            currentCloudKitRecordName = recordName
            verifiedIdentity = VerifiedIdentityProfile(
                cloudKitRecordName: recordName,
                name: "UI Test Pilot",
                gemsID: "UT1001",
                domicile: "ANC",
                equipment: "747",
                seat: "FO",
                dateOfHire: "01/01/2020",
                isAdminEligible: false,
                adminPolicyFingerprint: nil,
                verifiedAt: Date(timeIntervalSince1970: 1_767_494_400)
            )
            authStatus = .loggedOut
            clearSessionCookiesForUITest()  // Ensure syncTapped() shows login sheet immediately
            errorMessage = nil
            isShowingLoginSheet = false
            didLastFetchFail = false
        }

        if arguments.contains("UITEST_OPENTIME_DEMO") {
            isOpenTimeDemoMode = true
        }
    }

    private static var uiTestTimelineSchedules: [PayPeriodSchedule] {
        let firstLegs = [
            TripLeg(
                payPeriod: "CA26-01-A70001",
                pairing: "A70001",
                leg: 1,
                flight: "063",
                depAirport: "ANC",
                depLocal: "2026-06-09 09:15",
                arrAirport: "SDF",
                arrLocal: "2026-06-09 18:30",
                depUTC: "2026-06-09T18:15:00Z",
                arrUTC: "2026-06-10T00:30:00Z",
                status: "-",
                block: "6:15"
            ),
            TripLeg(
                payPeriod: "CA26-01-A70001",
                pairing: "A70001",
                leg: 2,
                flight: "108",
                depAirport: "SDF",
                depLocal: "2026-06-10 08:20",
                arrAirport: "NRT",
                arrLocal: "2026-06-11 12:05",
                depUTC: "2026-06-10T13:20:00Z",
                arrUTC: "2026-06-11T03:05:00Z",
                status: "-",
                block: "13:45"
            ),
            TripLeg(
                payPeriod: "CA26-01-A70001",
                pairing: "A70001",
                leg: 3,
                flight: "109",
                depAirport: "NRT",
                depLocal: "2026-06-12 16:40",
                arrAirport: "ANC",
                arrLocal: "2026-06-12 08:25",
                depUTC: "2026-06-12T07:40:00Z",
                arrUTC: "2026-06-12T17:25:00Z",
                status: "-",
                block: "8:45"
            )
        ]

        return [
            PayPeriodSchedule(
                id: "CA26-01-A70001",
                label: "CA26-01-A70001",
                tripCount: 1,
                legCount: firstLegs.count,
                openTimeCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_767_494_400),
                legs: firstLegs,
                openTimeTrips: []
            )
        ]
    }
}
#endif
