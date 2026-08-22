#if DEBUG
import Foundation

enum FlightCountdownDebugScenario: String, CaseIterable, Identifiable {
    case preReport
    case homeWidgetPreReport
    case preDeparture
    case departureTimePassed0
    case departureTimePassed1
    case departureTimePassed60

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preReport:
            "Report in"
        case .homeWidgetPreReport:
            "Home Widget: Report in"
        case .preDeparture:
            "Dep in"
        case .departureTimePassed0:
            "Departure time passed 0 min"
        case .departureTimePassed1:
            "Departure time passed 1 min"
        case .departureTimePassed60:
            "Departure time passed 60 min"
        }
    }

    /// Sets only the fixture's planned departure relative to the injected `nowUTC`.
    /// The production builder still derives report time, state, presentation, and Activity payload.
    var departureOffsetFromNow: TimeInterval {
        switch self {
        case .preReport:
            5 * 60 * 60
        case .homeWidgetPreReport:
            9 * 60 * 60
        case .preDeparture:
            30 * 60
        case .departureTimePassed0:
            0
        case .departureTimePassed1:
            -60
        case .departureTimePassed60:
            -(60 * 60)
        }
    }
}

extension AppViewModel {
    static let debugFlightCountdownFixtureID = "DEBUG-ANC-ICN-ANC"
    static let debugFlightCountdownFirstLegID = UUID(uuidString: "D3B60001-0000-4000-8000-000000000001")!
    static let debugFlightCountdownSecondLegID = UUID(uuidString: "D3B60002-0000-4000-8000-000000000002")!

    static func debugFlightCountdownCanonicalSchedules() -> [PayPeriodSchedule] {
        debugFlightCountdownSchedules(
            firstDepartureUTC: debugFixtureDate("2026-08-16T23:40:00Z"),
            firstArrivalUTC: debugFixtureDate("2026-08-17T08:00:00Z"),
            secondDepartureUTC: debugFixtureDate("2026-08-18T09:00:00Z"),
            secondArrivalUTC: debugFixtureDate("2026-08-18T18:00:00Z")
        )
    }

    static func debugFlightCountdownInteractiveSchedules(
        nowUTC: Date,
        scenario: FlightCountdownDebugScenario = .preReport
    ) -> [PayPeriodSchedule] {
        let firstDepartureUTC = nowUTC.addingTimeInterval(scenario.departureOffsetFromNow)
        let firstArrivalUTC = firstDepartureUTC.addingTimeInterval((8 * 60 + 20) * 60)
        let secondDepartureUTC = nowUTC.addingTimeInterval((2 * 24 + 9) * 60 * 60)
        let secondArrivalUTC = secondDepartureUTC.addingTimeInterval(9 * 60 * 60)
        return debugFlightCountdownSchedules(
            firstDepartureUTC: firstDepartureUTC,
            firstArrivalUTC: firstArrivalUTC,
            secondDepartureUTC: secondDepartureUTC,
            secondArrivalUTC: secondArrivalUTC
        )
    }

    static func debugFlightCountdownSchedules(
        firstDepartureUTC: Date,
        firstArrivalUTC: Date,
        secondDepartureUTC: Date,
        secondArrivalUTC: Date
    ) -> [PayPeriodSchedule] {
        let payPeriod = "DEBUG-PP"
        let pairing = debugFlightCountdownFixtureID
        let firstDeparture = debugFixtureUTCString(firstDepartureUTC)
        let firstArrival = debugFixtureUTCString(firstArrivalUTC)
        let secondDeparture = debugFixtureUTCString(secondDepartureUTC)
        let secondArrival = debugFixtureUTCString(secondArrivalUTC)
        let legs = [
            TripLeg(
                id: debugFlightCountdownFirstLegID,
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 1,
                flight: "D901",
                depAirport: "ANC",
                depLocal: debugFixtureLocalString(firstDepartureUTC),
                arrAirport: "ICN",
                arrLocal: debugFixtureLocalString(firstArrivalUTC),
                depUTC: firstDeparture,
                arrUTC: firstArrival,
                status: "-",
                block: "8:20",
                stdUTC: firstDeparture,
                staUTC: firstArrival
            ),
            TripLeg(
                id: debugFlightCountdownSecondLegID,
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 2,
                flight: "D902",
                depAirport: "ICN",
                depLocal: debugFixtureLocalString(secondDepartureUTC),
                arrAirport: "ANC",
                arrLocal: debugFixtureLocalString(secondArrivalUTC),
                depUTC: secondDeparture,
                arrUTC: secondArrival,
                status: "-",
                block: "9:00",
                stdUTC: secondDeparture,
                staUTC: secondArrival
            )
        ]
        return [
            PayPeriodSchedule(
                id: debugFlightCountdownFixtureID,
                label: debugFlightCountdownFixtureID,
                tripCount: 1,
                legCount: legs.count,
                openTimeCount: 0,
                updatedAt: firstDepartureUTC,
                legs: legs,
                openTimeTrips: []
            )
        ]
    }

    private static func debugFixtureDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static func debugFixtureUTCString(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: value)
    }

    private static func debugFixtureLocalString(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: value)
    }

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
        // Keep this fixture ahead of the wall clock: the Next Report strip only renders before a
        // future report time. A fixed historical schedule silently turned this UI test into a
        // permanent failure once June 2026 passed.
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let start = utcCalendar.date(byAdding: .day, value: 2, to: Date()) ?? Date().addingTimeInterval(2 * 86_400)
        let outboundArrival = start.addingTimeInterval(6 * 3_600)
        let returnDeparture = start.addingTimeInterval(24 * 3_600)
        let returnArrival = start.addingTimeInterval(32 * 3_600)

        let utcFormatter = ISO8601DateFormatter()
        utcFormatter.formatOptions = [.withInternetDateTime]
        utcFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        let localFormatter = DateFormatter()
        localFormatter.calendar = utcCalendar
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        localFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        let firstLegs = [
            TripLeg(
                payPeriod: "CA26-01-A70001",
                pairing: "A70001",
                leg: 1,
                flight: "063",
                depAirport: "ANC",
                depLocal: localFormatter.string(from: start),
                arrAirport: "SDF",
                arrLocal: localFormatter.string(from: outboundArrival),
                depUTC: utcFormatter.string(from: start),
                arrUTC: utcFormatter.string(from: outboundArrival),
                status: "-",
                block: "6:15"
            ),
            TripLeg(
                payPeriod: "CA26-01-A70001",
                pairing: "A70001",
                leg: 2,
                flight: "108",
                depAirport: "SDF",
                depLocal: localFormatter.string(from: returnDeparture),
                arrAirport: "ANC",
                arrLocal: localFormatter.string(from: returnArrival),
                depUTC: utcFormatter.string(from: returnDeparture),
                arrUTC: utcFormatter.string(from: returnArrival),
                status: "-",
                block: "8:00"
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
