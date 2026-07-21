import XCTest
@testable import TripDataHub

final class BidPeriodScheduleExportServiceTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()
    private let generator = ExportGenerator(name: "TripDataHub", version: "1.0-test", build: "1")
    private let exportDate = ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!

    func test_filenameAndEmbeddedIdentifierAgree() throws {
        let export = BidPeriodScheduleExportService.makeExport(input: try input())

        XCTAssertEqual(export.schemaVersion, "1.0")
        XCTAssertEqual(export.bidPeriod.identifier, "BP26-04")
        XCTAssertEqual(BidPeriodScheduleExportService.filename(for: export), "BP26-04.json")
        let object = try jsonObject(export)
        let bidPeriod = try XCTUnwrap(object["bidPeriod"] as? [String: Any])
        XCTAssertEqual(bidPeriod["identifier"] as? String, "BP26-04")
        XCTAssertEqual((bidPeriod["payPeriods"] as? [[String: Any]])?.count, 2)
        XCTAssertNotNil(object["calendarEvents"])
        XCTAssertNil(object["manualEvents"])
    }

    func test_usesAuthoritativeThreeAMBoundaryAndVariableDuration() throws {
        let period = try XCTUnwrap(bidPeriod(identifier: "BP26-07", domicile: "ANC"))
        let export = BidPeriodScheduleExportService.makeExport(input: try input(
            bidPeriod: period,
            schedules: []
        ))

        XCTAssertEqual(export.bidPeriod.boundaryLocalTime, "03:00")
        XCTAssertEqual(export.bidPeriod.start, "2026-11-01T12:00:00Z")
        XCTAssertEqual(export.bidPeriod.end, "2026-11-29T12:00:00Z")
        XCTAssertEqual(period.days.count, 28)
    }

    func test_exportsOrderedAuthoritativePayPeriodsForOrdinaryBidPeriod() throws {
        let export = BidPeriodScheduleExportService.makeExport(input: try input())

        XCTAssertEqual(export.bidPeriod.payPeriods.compactMap(\.identifier), ["PP26-06", "PP26-07"])
        XCTAssertEqual(export.bidPeriod.payPeriods.map(\.ordinal), [1, 2])
        XCTAssertEqual(export.bidPeriod.payPeriods.map(\.start), [
            "2026-05-17T11:00:00Z",
            "2026-06-14T11:00:00Z"
        ])
        XCTAssertEqual(export.bidPeriod.payPeriods.map(\.end), [
            "2026-06-14T11:00:00Z",
            "2026-07-12T11:00:00Z"
        ])
    }

    func test_exportsSingleAuthoritativePayPeriodForKnownShortBidPeriod() throws {
        let period = try XCTUnwrap(bidPeriod(identifier: "BP26-07", domicile: "ANC"))
        let export = BidPeriodScheduleExportService.makeExport(input: try input(bidPeriod: period))

        XCTAssertEqual(export.bidPeriod.payPeriods.count, 1)
        XCTAssertEqual(export.bidPeriod.payPeriods.first?.identifier, "PP26-12")
        XCTAssertEqual(export.bidPeriod.payPeriods.first?.ordinal, 1)
        XCTAssertEqual(export.bidPeriod.payPeriods.first?.start, export.bidPeriod.start)
        XCTAssertEqual(export.bidPeriod.payPeriods.first?.end, export.bidPeriod.end)
    }

    func test_payPeriodBoundariesAreContainedWithinParentBidPeriod() throws {
        for identifier in ["BP26-04", "BP26-07"] {
            let period = try XCTUnwrap(bidPeriod(identifier: identifier, domicile: "ANC"))
            let export = BidPeriodScheduleExportService.makeExport(input: try input(bidPeriod: period))

            XCTAssertFalse(export.bidPeriod.payPeriods.isEmpty)
            XCTAssertTrue(export.bidPeriod.payPeriods.allSatisfy {
                $0.start >= export.bidPeriod.start
                    && $0.end <= export.bidPeriod.end
                    && $0.start < $0.end
            })
        }
    }

    func test_includesAssignedAndPreviousPeriodOverlapButExcludesExactBoundaryEnd() throws {
        let period = try selectedPeriod()
        let overlapping = schedule(
            id: "previous",
            pairing: "T1001",
            departure: "2026-05-17T08:00:00Z",
            arrival: "2026-05-17T12:30:00Z"
        )
        let assigned = schedule(
            id: "selected",
            pairing: "T2002",
            departure: "2026-05-18T14:00:00Z",
            arrival: "2026-05-18T18:00:00Z"
        )
        let exactBoundaryEnd = schedule(
            id: "boundary",
            pairing: "T3003",
            departure: "2026-05-17T07:00:00Z",
            arrival: "2026-05-17T11:00:00Z"
        )

        let export = BidPeriodScheduleExportService.makeExport(input: try input(
            bidPeriod: period,
            schedules: [assigned, exactBoundaryEnd, overlapping]
        ))

        XCTAssertEqual(export.trips.map(\.tripNumber), ["T1001", "T2002"])
        XCTAssertEqual(export.trips[0].assignedBidPeriodIdentifier, "BP26-03")
        XCTAssertEqual(export.trips[0].relationshipToSelectedBidPeriod, .overlappingFromPrevious)
        XCTAssertEqual(export.trips[1].assignedBidPeriodIdentifier, "BP26-04")
        XCTAssertEqual(export.trips[1].relationshipToSelectedBidPeriod, .assigned)
    }

    func test_missingRichPayloadProducesUsableFallbackAndStructuredDiagnostics() throws {
        let export = BidPeriodScheduleExportService.makeExport(input: try input(schedules: [
            schedule(
                id: "fallback",
                pairing: "T4004",
                departure: "2026-06-01T12:00:00Z",
                arrival: "2026-06-01T16:00:00Z"
            )
        ]))

        let trip = try XCTUnwrap(export.trips.first)
        XCTAssertEqual(trip.source, .displayedScheduleFallback)
        XCTAssertEqual(trip.events.count, 1)
        XCTAssertFalse(trip.diagnostics.richPayloadAvailable)
        XCTAssertTrue(trip.diagnostics.unavailableFieldGroups.contains("crewAccessPayload"))
        XCTAssertTrue(trip.diagnostics.unavailableFieldGroups.contains("summary.dutyTime"))
        XCTAssertTrue(trip.diagnostics.unavailableFieldGroups.contains("summary.blockTime"))
        XCTAssertTrue(trip.diagnostics.unavailableFieldGroups.contains("summary.creditTime"))
        XCTAssertTrue(trip.diagnostics.unavailableFieldGroups.contains("summary.tafb"))
        XCTAssertTrue(trip.diagnostics.unavailableFieldGroups.contains("summary.tripDays"))
        XCTAssertNil(trip.summary)
        XCTAssertTrue(trip.diagnostics.issues.contains { $0.code == "richCrewAccessPayloadUnavailable" })
        XCTAssertTrue(export.diagnostics.partial)
    }

    func test_mapsAvailableRichTripSummaryToStructuredValues() throws {
        let richSchedule = schedule(
            id: "rich-summary",
            pairing: "T7007",
            departure: "2026-06-01T12:00:00Z",
            arrival: "2026-06-01T16:00:00Z"
        )
        let richPayload = payload(
            tripID: "T7007",
            start: "2026-06-01T12:00:00Z",
            end: "2026-06-01T16:00:00Z",
            dutyTotals: [
                "Duty totals Time: 10:30 Block: 08:15 Rest: 12:00",
                "Duty totals Time: 05:45 Block: 04:30 Rest:"
            ],
            creditTime: "14:20",
            tripDays: "3",
            tafb: "48:10"
        )
        let export = BidPeriodScheduleExportService.makeExport(input: try input(
            schedules: [richSchedule],
            crewAccessPayloads: [richPayload]
        ))

        let trip = try XCTUnwrap(export.trips.first)
        XCTAssertEqual(trip.source, .crewAccessRich)
        let summary = try XCTUnwrap(trip.summary)
        XCTAssertEqual(summary.dutyTime, ExportDurationSummary(minutes: 975, display: "16:15"))
        XCTAssertEqual(summary.blockTime, ExportDurationSummary(minutes: 765, display: "12:45"))
        XCTAssertEqual(summary.creditTime, ExportDurationSummary(minutes: 860, display: "14:20"))
        XCTAssertEqual(summary.tafb, ExportDurationSummary(minutes: 2_890, display: "48:10"))
        XCTAssertEqual(summary.tripDays, ExportTripDaysSummary(days: 3, display: "3"))
        XCTAssertFalse(trip.diagnostics.unavailableFieldGroups.contains { $0.hasPrefix("summary.") })

        let object = try jsonObject(export)
        let trips = try XCTUnwrap(object["trips"] as? [[String: Any]])
        let encodedSummary = try XCTUnwrap(trips.first?["summary"] as? [String: Any])
        XCTAssertEqual((encodedSummary["dutyTime"] as? [String: Any])?["minutes"] as? Int, 975)
        XCTAssertEqual((encodedSummary["tripDays"] as? [String: Any])?["days"] as? Int, 3)
    }

    func test_fallbackPreservesStoredLayoverAndHotelName() throws {
        let first = leg(
            id: "layover-first",
            pairing: "T4114",
            legNumber: 1,
            departure: "2026-06-01T12:00:00Z",
            arrival: "2026-06-01T16:00:00Z",
            origin: "ANC",
            destination: "SEA",
            layoverStation: "SEA",
            layoverHotelName: "Example Airport Hotel",
            layoverDuration: "14:00"
        )
        let second = leg(
            id: "layover-second",
            pairing: "T4114",
            legNumber: 2,
            departure: "2026-06-02T06:00:00Z",
            arrival: "2026-06-02T10:00:00Z",
            origin: "SEA",
            destination: "ANC"
        )
        let export = BidPeriodScheduleExportService.makeExport(input: try input(schedules: [
            schedule(id: "layover", legs: [second, first])
        ]))

        let trip = try XCTUnwrap(export.trips.first)
        XCTAssertEqual(trip.events.map(\.type), [.flight, .layover, .flight])
        XCTAssertEqual(trip.events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(trip.events[1].station, "SEA")
        XCTAssertEqual(trip.events[1].hotel?.name, "Example Airport Hotel")
    }

    func test_exportsAllCalendarCategoriesWithCategoryAndSource() throws {
        let operational = try ManualOperationalEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            code: .rcid,
            crewBase: .anc,
            startUTC: date("2026-06-02T17:00:00Z"),
            endUTC: date("2026-06-02T21:00:00Z"),
            notes: "Fictional operational note"
        )
        let personal = try ManualPersonalEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            code: .medical,
            startUTC: date("2026-06-03T18:00:00Z"),
            endUTC: date("2026-06-03T19:00:00Z"),
            notes: "Fictional personal note"
        )

        let export = BidPeriodScheduleExportService.makeExport(input: try input(
            operationalEvents: [operational],
            personalEvents: [personal],
            faaMedicalExpiryDate: "2026-06-20"
        ))

        XCTAssertEqual(Set(export.calendarEvents.map(\.category)), Set([
            .operational, .bid, .financial, .personal
        ]))
        XCTAssertTrue(export.calendarEvents.contains { $0.category == .operational && $0.source == .userCreated })
        XCTAssertTrue(export.calendarEvents.contains { $0.category == .personal && $0.source == .userCreated })
        XCTAssertTrue(export.calendarEvents.contains { $0.category == .bid && $0.source == .calendarRule })
        XCTAssertTrue(export.calendarEvents.contains { $0.category == .financial && $0.source == .calendarRule })
        XCTAssertTrue(export.calendarEvents.contains { $0.kind == "faaMedicalExpiry" && $0.source == .profileDate })
    }

    func test_sharedCalendarRulesPreserveQualificationAndPayDaySemantics() {
        XCTAssertTrue(BidPeriodCalendarEventService.bidEvents(
            on: "2026-06-18",
            qualification: .captain
        ).contains { $0.kind == .scheduleBidClose && $0.title == "Schedule Bid Close BP26-05" })
        XCTAssertTrue(BidPeriodCalendarEventService.bidEvents(
            on: "2026-06-22",
            qualification: .firstOfficer
        ).contains { $0.kind == .scheduleBidClose && $0.title == "Schedule Bid Close BP26-05" })
        XCTAssertEqual(
            BidPeriodCalendarEventService.financialEvents(on: "2026-06-15").map(\.kind),
            [.payDay]
        )
        XCTAssertEqual(
            BidPeriodCalendarEventService.financialEvents(on: "2026-06-29").map(\.kind),
            [.enhancedPayDay]
        )
    }

    func test_missingOptionalOwnerFieldsDoNotAbortAndProduceDiagnostics() throws {
        let export = BidPeriodScheduleExportService.makeExport(input: try input(owner: emptyOwner()))

        XCTAssertNil(export.owner.name)
        XCTAssertNil(export.owner.gems)
        XCTAssertNil(export.owner.fleet)
        XCTAssertNil(export.owner.position)
        XCTAssertNil(export.owner.line)
        XCTAssertEqual(
            Set(export.diagnostics.issues.filter { $0.scope == "owner" }.compactMap(\.fieldGroup)),
            Set(["name", "gems", "fleet", "position", "seniorityNumber", "dateOfHire"])
        )
    }

    func test_orderingIsDeterministicForTripsLegsAndCalendarEvents() throws {
        let early = schedule(
            id: "early",
            pairing: "T5005",
            departure: "2026-06-04T10:00:00Z",
            arrival: "2026-06-04T14:00:00Z"
        )
        let late = schedule(
            id: "late",
            pairing: "T6006",
            departure: "2026-06-05T10:00:00Z",
            arrival: "2026-06-05T14:00:00Z"
        )
        let operationalEarly = try ManualOperationalEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            code: .rcid,
            crewBase: .anc,
            startUTC: date("2026-06-02T17:00:00Z"),
            endUTC: date("2026-06-02T21:00:00Z")
        )
        let operationalLate = try ManualOperationalEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            code: .lco,
            crewBase: .anc,
            startUTC: date("2026-06-03T17:00:00Z"),
            endUTC: date("2026-06-03T21:00:00Z")
        )
        let first = BidPeriodScheduleExportService.makeExport(input: try input(
            schedules: [late, early],
            operationalEvents: [operationalLate, operationalEarly]
        ))
        let second = BidPeriodScheduleExportService.makeExport(input: try input(
            schedules: [early, late],
            operationalEvents: [operationalEarly, operationalLate]
        ))

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            try BidPeriodScheduleExportService.encodedData(for: first),
            try BidPeriodScheduleExportService.encodedData(for: second)
        )
        XCTAssertEqual(first.trips.map(\.tripNumber), ["T5005", "T6006"])
        XCTAssertEqual(first.trips.flatMap(\.events).map(\.sequence), [1, 1])
        XCTAssertEqual(
            first.calendarEvents.filter { $0.source == .userCreated }.map(\.kind),
            ["RCID", "LCO"]
        )
    }

    func test_exportInputHasNoFriendsDataPath() throws {
        let data = try BidPeriodScheduleExportService.encodedData(
            for: BidPeriodScheduleExportService.makeExport(input: try input())
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.localizedCaseInsensitiveContains("friend"))
        XCTAssertFalse(json.contains("Other Employee"))
    }

    func test_temporaryFileUsesIdentifierFilename() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TDHBPExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let output = try BidPeriodScheduleExportService.makeTemporaryFile(
            input: try input(),
            temporaryRoot: temporaryRoot
        )

        XCTAssertEqual(output.url.lastPathComponent, "BP26-04.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.url.path))
    }

    private func input(
        bidPeriod: CalendarBidPeriod? = nil,
        owner: BidPeriodExportOwnerInput? = nil,
        schedules: [PayPeriodSchedule] = [],
        operationalEvents: [ManualOperationalEvent] = [],
        personalEvents: [ManualPersonalEvent] = [],
        faaMedicalExpiryDate: String? = nil,
        crewAccessPayloads: [CrewAccessTripJSON] = []
    ) throws -> BidPeriodScheduleExportInput {
        BidPeriodScheduleExportInput(
            bidPeriod: try bidPeriod ?? selectedPeriod(),
            domicile: "ANC",
            owner: owner ?? fictionalOwner(),
            schedules: schedules,
            crewAccessPayloads: crewAccessPayloads,
            manualOperationalEvents: operationalEvents,
            manualPersonalEvents: personalEvents,
            pilotQualification: .captain,
            faaMedicalExpiryDate: faaMedicalExpiryDate,
            passportExpiryDate: nil,
            chinaVisaExpiryDate: nil,
            generator: generator,
            exportedAt: exportDate
        )
    }

    private func selectedPeriod() throws -> CalendarBidPeriod {
        try XCTUnwrap(bidPeriod(identifier: "BP26-04", domicile: "ANC"))
    }

    private func fictionalOwner() -> BidPeriodExportOwnerInput {
        BidPeriodExportOwnerInput(
            profileName: "Avery Example",
            profileGEMS: "0000001",
            profileFleet: "747",
            profilePosition: "FO",
            verifiedName: "",
            verifiedGEMS: "",
            verifiedEquipment: "747",
            verifiedSeat: "FO",
            verifiedDateOfHire: "2020-01-01",
            seniorityNumber: "99999"
        )
    }

    private func emptyOwner() -> BidPeriodExportOwnerInput {
        BidPeriodExportOwnerInput(
            profileName: "",
            profileGEMS: "",
            profileFleet: "",
            profilePosition: "",
            verifiedName: "",
            verifiedGEMS: "",
            verifiedEquipment: "",
            verifiedSeat: "",
            verifiedDateOfHire: "",
            seniorityNumber: ""
        )
    }

    private func schedule(
        id: String,
        pairing: String,
        departure: String,
        arrival: String
    ) -> PayPeriodSchedule {
        let leg = leg(
            id: id,
            pairing: pairing,
            legNumber: 1,
            departure: departure,
            arrival: arrival,
            origin: "ANC",
            destination: "SEA"
        )
        return schedule(id: id, legs: [leg])
    }

    private func schedule(id: String, legs: [TripLeg]) -> PayPeriodSchedule {
        return PayPeriodSchedule(
            id: id,
            label: "PP26-06",
            tripCount: 1,
            legCount: legs.count,
            openTimeCount: 0,
            updatedAt: exportDate,
            legs: legs,
            openTimeTrips: []
        )
    }

    private func leg(
        id: String,
        pairing: String,
        legNumber: Int,
        departure: String,
        arrival: String,
        origin: String,
        destination: String,
        layoverStation: String? = nil,
        layoverHotelName: String? = nil,
        layoverDuration: String? = nil
    ) -> TripLeg {
        TripLeg(
            id: deterministicUUID(id),
            payPeriod: "PP26-06",
            pairing: pairing,
            leg: legNumber,
            flight: "\(100 + legNumber)",
            depAirport: origin,
            depLocal: departure,
            arrAirport: destination,
            arrLocal: arrival,
            depUTC: departure,
            arrUTC: arrival,
            status: "",
            block: "04:00",
            layoverStation: layoverStation,
            layoverHotelName: layoverHotelName,
            layoverDuration: layoverDuration
        )
    }

    private func payload(
        tripID: String,
        start: String,
        end: String,
        dutyTotals: [String],
        creditTime: String?,
        tripDays: String?,
        tafb: String?
    ) -> CrewAccessTripJSON {
        CrewAccessTripJSON(
            schemaVersion: 1,
            source: "fictional-test",
            sourceVersion: "1",
            mappingVersion: "test",
            generatedAt: "2026-07-01T12:00:00Z",
            tripId: tripID,
            tripInformationDate: String(start.prefix(10)),
            creditTime: creditTime,
            tripDays: tripDays,
            tafb: tafb,
            dutyTotals: dutyTotals,
            hotelDetails: [],
            crew: [],
            items: [
                CrewAccessTripItemJSON(
                    sequence: 1,
                    depAirport: "ANC",
                    arrAirport: "SEA",
                    deadhead: false,
                    flight: "5X101",
                    startUtc: start,
                    endUtc: end,
                    startLocalDisplay: start,
                    endLocalDisplay: end,
                    originTz: "America/Anchorage",
                    destinationTz: "America/Los_Angeles",
                    timeDerivation: "from_utc",
                    aircraft: "747",
                    block: "04:00",
                    stdUtc: start,
                    staUtc: end,
                    atdUtc: nil,
                    ataUtc: nil,
                    tailNumber: nil
                )
            ]
        )
    }

    private func deterministicUUID(_ value: String) -> UUID {
        let suffix = String(value.utf8.reduce(0) { ($0 * 31 + Int($1)) % 999_999 })
        return UUID(uuidString: "00000000-0000-0000-0000-\(String(repeating: "0", count: 12 - suffix.count))\(suffix)")!
    }

    private func date(_ value: String) -> Date {
        Self.iso.date(from: value)!
    }

    private func jsonObject(_ export: BidPeriodScheduleExport) throws -> [String: Any] {
        let data = try BidPeriodScheduleExportService.encodedData(for: export)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
