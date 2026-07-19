import XCTest
@testable import TripDataHub

final class TripJSONExportServiceTests: XCTestCase {
    private let fixedExportDate = Date(timeIntervalSince1970: 1_752_884_200)
    private let testGenerator = ExportGenerator(name: "TripDataHub", version: "1.2.3", build: "71")

    func test_selectsStoredPayloadForSchedule() {
        let selected = TripJSONExportService.payload(
            for: schedule(),
            candidates: [payload(tripID: "99999"), payload()]
        )

        XCTAssertEqual(selected, payload())
    }

    func test_publicRootAndSchemaVersionMatchDraftV01() throws {
        let data = try exportData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), Set([
            "schemaVersion", "exportedAt", "generator", "owner", "trip", "events"
        ]))
        XCTAssertEqual(object["schemaVersion"] as? String, "1.0")
        XCTAssertNotNil(object["generator"] as? [String: Any])
        XCTAssertNotNil(object["owner"] as? [String: Any])
        XCTAssertNotNil(object["trip"] as? [String: Any])
        XCTAssertNotNil(object["events"] as? [[String: Any]])
    }

    func test_ownerUsesCanonicalProfileAndNormalizesPublicFields() throws {
        let export = try publicExport(
            ownerSource: ownerSource(
                profileName: "  Satoshi   Funeno ",
                profileGEMS: "7793942",
                profilePosition: "F/O"
            ),
            payload: payload(crew: [
                CrewAccessCrewJSON(position: "F/O", seniority: "100", crewID: "00007793942", name: "Source Owner"),
                CrewAccessCrewJSON(position: "CA", seniority: "1", crewID: "1234567", name: "Other Pilot")
            ])
        )

        XCTAssertEqual(
            export.owner,
            ExportOwner(name: "SATOSHI FUNENO", gems: "7793942", base: "ANC", fleet: "747", position: "FO")
        )
    }

    func test_ownerCombinesExplicitGivenAndFamilyNames() throws {
        let export = try publicExport(ownerSource: ownerSource(
            profileName: "Satoshi",
            profileGivenName: " Satoshi ",
            profileFamilyName: " Funeno "
        ))

        XCTAssertEqual(export.owner.name, "SATOSHI FUNENO")
    }

    func test_canonicalFullDisplayNamePrecedesFirstNameOnlyProfileField() throws {
        let export = try publicExport(ownerSource: ownerSource(
            profileName: "Satoshi Funeno",
            profileGivenName: "Satoshi",
            profileFamilyName: ""
        ))

        XCTAssertEqual(export.owner.name, "SATOSHI FUNENO")
    }

    func test_matchingCrewFullNameReplacesProfileFirstNameOnly() throws {
        let export = try publicExport(
            ownerSource: ownerSource(
                profileName: "Satoshi",
                verifiedName: "Satoshi"
            ),
            payload: payload(crew: [
                CrewAccessCrewJSON(
                    position: "F/O",
                    seniority: "100",
                    crewID: "00007793942",
                    name: "Satoshi Funeno"
                )
            ])
        )

        XCTAssertEqual(export.owner.name, "SATOSHI FUNENO")
    }

    func test_matchingCrewFullNameReplacesVerifiedGEMSPlaceholder() throws {
        let export = try publicExport(
            ownerSource: ownerSource(
                profileName: "SATOSHI",
                verifiedName: "GEMS 7793942"
            ),
            payload: payload(crew: [CrewAccessCrewJSON(
                position: "FO", seniority: "", crewID: "00007793942", name: "Funeno Satoshi"
            )])
        )

        XCTAssertEqual(export.owner.name, "SATOSHI FUNENO")
    }

    func test_completeDisplayNameIsNotDuplicatedBySplitFields() throws {
        let export = try publicExport(ownerSource: ownerSource(
            profileName: "Satoshi Funeno",
            profileGivenName: "Satoshi",
            profileFamilyName: "Funeno"
        ))

        XCTAssertEqual(export.owner.name, "SATOSHI FUNENO")
    }

    func test_ownerNameCollapsesRepeatedWhitespace() throws {
        let export = try publicExport(ownerSource: ownerSource(
            profileName: "  Satoshi    Funeno  "
        ))

        XCTAssertEqual(export.owner.name, "SATOSHI FUNENO")
    }

    func test_encodedOwnerContainsCompleteExpectedPublicIdentity() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exportData()) as? [String: Any])
        let owner = try XCTUnwrap(object["owner"] as? [String: Any])

        XCTAssertEqual(owner["name"] as? String, "SATOSHI FUNENO")
        XCTAssertEqual(owner["gems"] as? String, "7793942")
        XCTAssertEqual(owner["base"] as? String, "ANC")
        XCTAssertEqual(owner["fleet"] as? String, "747")
        XCTAssertEqual(owner["position"] as? String, "FO")
        XCTAssertEqual(Set(owner.keys), Set(["name", "gems", "base", "fleet", "position"]))
    }

    func test_gemsNormalizationSupportsCurrentAndFutureLengths() throws {
        let cases = [
            "12345": "0012345",
            "123456": "0123456",
            "1234567": "1234567",
            "0123456": "0123456",
            "12345678": "12345678",
            "00123456": "00123456",
            "123456789": "123456789",
            " 1234567 ": "1234567"
        ]

        for (source, expected) in cases {
            XCTAssertEqual(try TripJSONExportService.normalizedGEMS(source), expected, source)
        }
    }

    func test_invalidOwnerGEMSProducesExplicitError() {
        XCTAssertThrowsError(try TripJSONExportService.normalizedGEMS("  - /  ")) { error in
            XCTAssertEqual(error as? TripJSONExportError, .invalidOwnerGEMS)
        }
        XCTAssertThrowsError(try publicExport(
            ownerSource: ownerSource(profileGEMS: "", verifiedGEMS: ""),
            payload: payload(crew: [])
        )) { error in
            XCTAssertEqual(error as? TripJSONExportError, .invalidOwnerGEMS)
        }
    }

    func test_gemsEncodesAsStringAndCanonicalProfileWinsOverPaddedCrewValue() throws {
        let data = try exportData(
            ownerSource: ownerSource(profileGEMS: "0123456"),
            payload: payload(crew: [
                CrewAccessCrewJSON(position: "F/O", seniority: "100", crewID: "00000123456", name: "Source Owner")
            ])
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let owner = try XCTUnwrap(object["owner"] as? [String: Any])

        XCTAssertEqual(owner["gems"] as? String, "0123456")
        XCTAssertTrue(owner["gems"] is String)
    }

    func test_flightsAndDeadheadsMapToOrderedPublicEvents() throws {
        let export = try publicExport()

        XCTAssertEqual(export.events.map(\.type), [.flight, .deadhead])
        XCTAssertEqual(export.events.map(\.sequence), [1, 2])
        XCTAssertEqual(export.events[0].flightNumber, "5X123")
        XCTAssertEqual(export.events[1].flightNumber, "5X124")
    }

    func test_operationalTimesUseUTCInstantCanonicalLocalIANAZoneAndEffectiveOffset() throws {
        let event = try XCTUnwrap(publicExport().events.first)

        XCTAssertEqual(event.start.instant, "2026-07-18T16:00:00Z")
        XCTAssertEqual(event.start.local, "2026-07-18T08:00:00")
        XCTAssertEqual(event.start.timeZone, "America/Anchorage")
        XCTAssertEqual(event.start.utcOffset, "-08:00")
        XCTAssertEqual(event.end.local, "2026-07-18T17:00:00")
        XCTAssertEqual(event.end.timeZone, "America/Kentucky/Louisville")
        XCTAssertEqual(event.end.utcOffset, "-04:00")
    }

    func test_eventsSortByInstantThenSequenceThenID() throws {
        let unsorted = payload(items: [
            item(sequence: 9, deadhead: true, flight: "5X999", start: "2026-07-18T22:00:00Z", end: "2026-07-19T01:00:00Z"),
            item(sequence: 2, deadhead: true, flight: "5X002", start: "2026-07-18T16:00:00Z", end: "2026-07-18T18:00:00Z"),
            item(sequence: 1, deadhead: false, flight: "5X001", start: "2026-07-18T16:00:00Z", end: "2026-07-18T17:00:00Z")
        ])
        let events = try publicExport(payload: unsorted).events

        XCTAssertEqual(events.map(\.sequence), [1, 2, 9])
        XCTAssertEqual(events, events.sorted {
            ($0.start.instant, $0.sequence, $0.id) < ($1.start.instant, $1.sequence, $1.id)
        })
    }

    func test_repeatedExportsKeepTripAndEventIDsStable() throws {
        let first = try publicExport(exportedAt: fixedExportDate)
        let second = try publicExport(exportedAt: fixedExportDate.addingTimeInterval(60))

        XCTAssertEqual(first.trip.id, second.trip.id)
        XCTAssertEqual(first.events.map(\.id), second.events.map(\.id))
        XCTAssertNotEqual(first.exportedAt, second.exportedAt)
    }

    func test_missingOptionalSourceValuesStillExport() throws {
        let minimal = payload(
            creditTime: nil,
            tripDays: nil,
            tafb: nil,
            hotelDetails: [],
            items: [item(aircraft: "", block: "", originTz: nil, destinationTz: nil)]
        )

        XCTAssertNoThrow(try publicExport(payload: minimal))
    }

    func test_exportExcludesOtherCrewAndInternalSourceFieldsRecursively() throws {
        let data = try exportData(payload: payload(crew: [
            CrewAccessCrewJSON(position: "F/O", seniority: "100", crewID: "00007793942", name: "SATOSHI FUNENO"),
            CrewAccessCrewJSON(position: "CA", seniority: "1", crewID: "1234567", name: "OTHER CREW MEMBER")
        ]))
        let object = try JSONSerialization.jsonObject(with: data)
        let keyPaths = recursiveKeyPaths(in: object)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        for prohibited in ["crew", "crewID", "seniority", "mappingVersion", "sourceVersion", "dutyTotals", "hotelDetails"] {
            XCTAssertFalse(keyPaths.contains { $0.split(separator: ".").last == Substring(prohibited) }, prohibited)
        }
        let namePaths = keyPaths.filter { $0.split(separator: ".").last == "name" }
        XCTAssertEqual(Set(namePaths), Set(["generator.name", "owner.name"]))
        XCTAssertFalse(text.contains("OTHER CREW MEMBER"))
        XCTAssertFalse(text.contains("1234567"))
    }

    func test_publicModelRoundTrips() throws {
        let original = try publicExport()
        let data = try TripJSONExportService.encodedData(for: original)
        let decoded = try JSONDecoder().decode(TripDataHubExport.self, from: data)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(decoded, original)
        XCTAssertTrue(text.contains("\n"))
        XCTAssertTrue(text.contains(#""schemaVersion" : "1.0""#))
    }

    func test_filenameIsDeterministicAndFilesystemSafe() throws {
        let unsafe = payload(tripID: " 12/194 : A ")
        let export = try publicExport(payload: unsafe)

        XCTAssertEqual(TripJSONExportService.filename(for: export), "TDH_12-194-A_2026-07-18.json")
    }

    func test_temporaryExportCreatesJSONFileURLAndCleansUpDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TripJSONExportServiceTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try TripJSONExportService.makeTemporaryFile(
            for: schedule(),
            payload: payload(),
            ownerSource: ownerSource(),
            generator: testGenerator,
            exportedAt: fixedExportDate,
            temporaryRoot: root
        )

        XCTAssertEqual(output.url.pathExtension, "json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.url.path))
        XCTAssertEqual(output.url.lastPathComponent, "TDH_12194_2026-07-18.json")
        XCTAssertNoThrow(try JSONDecoder().decode(TripDataHubExport.self, from: Data(contentsOf: output.url)))

        TripJSONExportService.removeTemporaryFiles(for: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.temporaryDirectory.path))
    }

    func test_structuredLayoverMapsToHotelEvent() throws {
        let export = try publicExport(schedule: schedule(includeHotel: true))
        let hotel = try XCTUnwrap(export.events.first { $0.type == .hotel })

        XCTAssertEqual(hotel.station, "SDF")
        XCTAssertEqual(hotel.hotelName, "Example Hotel")
        XCTAssertEqual(hotel.start.instant, "2026-07-18T21:00:00Z")
        XCTAssertEqual(hotel.end.instant, "2026-07-19T14:00:00Z")
    }

    func test_realGoldenTripBuildsPublicViewerExport() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = repositoryRoot
            .appendingPathComponent("sample_trip", isDirectory: true)
            .appendingPathComponent("golden_A70752.json")
        let storedPayload = try JSONDecoder().decode(CrewAccessTripJSON.self, from: Data(contentsOf: fixtureURL))
        let fixtureSchedule = schedule(for: storedPayload)

        let export = try publicExport(schedule: fixtureSchedule, payload: storedPayload)
        let exportedData = try TripJSONExportService.encodedData(for: export)
        let decoded = try JSONDecoder().decode(TripDataHubExport.self, from: exportedData)

        XCTAssertEqual(decoded.trip.tripNumber, "A70752")
        XCTAssertEqual(decoded.events.count, storedPayload.items.count)
        XCTAssertEqual(TripJSONExportService.filename(for: decoded), "TDH_A70752_2026-01-15.json")
    }

    private func publicExport(
        schedule: PayPeriodSchedule? = nil,
        ownerSource: TripJSONExportOwnerSource? = nil,
        payload: CrewAccessTripJSON? = nil,
        exportedAt: Date? = nil
    ) throws -> TripDataHubExport {
        let payload = payload ?? self.payload()
        return try TripJSONExportService.publicExport(
            for: schedule ?? self.schedule(),
            payload: payload,
            ownerSource: ownerSource ?? self.ownerSource(),
            generator: testGenerator,
            exportedAt: exportedAt ?? fixedExportDate
        )
    }

    private func exportData(
        ownerSource: TripJSONExportOwnerSource? = nil,
        payload: CrewAccessTripJSON? = nil
    ) throws -> Data {
        try TripJSONExportService.encodedData(for: publicExport(ownerSource: ownerSource, payload: payload))
    }

    private func ownerSource(
        profileName: String = "SATOSHI FUNENO",
        profileGivenName: String = "",
        profileFamilyName: String = "",
        profileGEMS: String = "7793942",
        profileBase: String = "ANC",
        profileFleet: String = "747",
        profilePosition: String = "FO",
        verifiedGEMS: String = "7793942",
        verifiedName: String = "Verified Owner"
    ) -> TripJSONExportOwnerSource {
        TripJSONExportOwnerSource(
            profileName: profileName,
            profileGivenName: profileGivenName,
            profileFamilyName: profileFamilyName,
            profileGEMS: profileGEMS,
            profileBase: profileBase,
            profileFleet: profileFleet,
            profilePosition: profilePosition,
            verifiedName: verifiedName,
            verifiedGEMS: verifiedGEMS,
            verifiedBase: "ANC",
            verifiedFleet: "747",
            verifiedPosition: "F/O"
        )
    }

    private func schedule(includeHotel: Bool = false) -> PayPeriodSchedule {
        let first = TripLeg(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            payPeriod: "CA26-07-12194", pairing: "12194", leg: 1, flight: "5X123",
            depAirport: "ANC", depLocal: "2026-07-18 08:00",
            arrAirport: "SDF", arrLocal: "2026-07-18 17:00",
            depUTC: "2026-07-18T16:00:00Z", arrUTC: "2026-07-18T21:00:00Z",
            status: "-", block: "05:00",
            layoverStation: includeHotel ? "SDF" : nil,
            layoverHotelName: includeHotel ? "Example Hotel" : nil,
            layoverDuration: includeHotel ? "17:00" : nil
        )
        let second = TripLeg(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            payPeriod: "CA26-07-12194", pairing: "12194", leg: 2, flight: "5X124",
            depAirport: "SDF", depLocal: "2026-07-19 10:00",
            arrAirport: "ANC", arrLocal: "2026-07-19 14:00",
            depUTC: "2026-07-19T14:00:00Z", arrUTC: "2026-07-19T22:00:00Z",
            status: "DH", block: "06:00"
        )
        return PayPeriodSchedule(
            id: "CA26-07-12194", label: "CA26-07-12194", tripCount: 1, legCount: 2,
            openTimeCount: 0, updatedAt: Date(timeIntervalSince1970: 0),
            legs: [first, second], openTimeTrips: []
        )
    }

    private func schedule(for payload: CrewAccessTripJSON) -> PayPeriodSchedule {
        PayPeriodSchedule(
            id: "fixture-\(payload.tripId)", label: payload.tripId, tripCount: 1,
            legCount: payload.items.count, openTimeCount: 0,
            updatedAt: Date(timeIntervalSince1970: 0),
            legs: payload.items.map { item in
                TripLeg(
                    payPeriod: "fixture", pairing: payload.tripId, leg: item.sequence,
                    flight: item.flight, depAirport: item.depAirport,
                    depLocal: item.startLocalDisplay, arrAirport: item.arrAirport,
                    arrLocal: item.endLocalDisplay, depUTC: item.startUtc,
                    arrUTC: item.endUtc, status: item.deadhead ? "DH" : "-", block: item.block
                )
            },
            openTimeTrips: []
        )
    }

    private func payload(
        tripID: String = "12194",
        creditTime: String? = "12:30",
        tripDays: String? = "2",
        tafb: String? = "30:00",
        crew: [CrewAccessCrewJSON] = [
            CrewAccessCrewJSON(position: "F/O", seniority: "100", crewID: "00007793942", name: "SATOSHI FUNENO")
        ],
        hotelDetails: [String] = ["SDF: Example Hotel"],
        items: [CrewAccessTripItemJSON]? = nil
    ) -> CrewAccessTripJSON {
        CrewAccessTripJSON(
            schemaVersion: 1,
            source: "crewaccess-pdf",
            sourceVersion: "https://example.invalid/trip",
            mappingVersion: "iata-tz-1",
            generatedAt: "2026-07-18T00:00:00Z",
            tripId: tripID,
            tripInformationDate: "2026-07-18",
            creditTime: creditTime,
            tripDays: tripDays,
            tafb: tafb,
            dutyTotals: ["Duty 1: 10:00"],
            hotelDetails: hotelDetails,
            crew: crew,
            items: items ?? [
                item(),
                item(
                    sequence: 2,
                    deadhead: true,
                    flight: "5X124",
                    start: "2026-07-19T14:00:00Z",
                    end: "2026-07-19T22:00:00Z",
                    depAirport: "SDF",
                    arrAirport: "ANC",
                    originTz: "America/Kentucky/Louisville",
                    destinationTz: "America/Anchorage"
                )
            ]
        )
    }

    private func item(
        sequence: Int = 1,
        deadhead: Bool = false,
        flight: String = "5X123",
        start: String = "2026-07-18T16:00:00Z",
        end: String = "2026-07-18T21:00:00Z",
        depAirport: String = "ANC",
        arrAirport: String = "SDF",
        aircraft: String = "747",
        block: String = "05:00",
        originTz: String? = "America/Anchorage",
        destinationTz: String? = "America/Kentucky/Louisville"
    ) -> CrewAccessTripItemJSON {
        CrewAccessTripItemJSON(
            sequence: sequence,
            depAirport: depAirport,
            arrAirport: arrAirport,
            deadhead: deadhead,
            flight: flight,
            startUtc: start,
            endUtc: end,
            startLocalDisplay: "ignored presentation string",
            endLocalDisplay: "ignored presentation string",
            originTz: originTz,
            destinationTz: destinationTz,
            timeDerivation: "source-utc",
            aircraft: aircraft,
            block: block,
            stdUtc: start,
            staUtc: end,
            atdUtc: nil,
            ataUtc: nil,
            tailNumber: nil
        )
    }

    private func recursiveKeyPaths(in value: Any, prefix: String = "") -> [String] {
        if let object = value as? [String: Any] {
            return object.flatMap { key, child -> [String] in
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                return [path] + recursiveKeyPaths(in: child, prefix: path)
            }
        }
        if let array = value as? [Any] {
            return array.flatMap { recursiveKeyPaths(in: $0, prefix: prefix) }
        }
        return []
    }
}
