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

    func test_publicRootAndSchemaVersionMatchLayoverExtension() throws {
        let data = try exportData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), Set([
            "schemaVersion", "exportedAt", "generator", "owner", "trip", "events"
        ]))
        XCTAssertEqual(object["schemaVersion"] as? String, "1.2")
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
        XCTAssertThrowsError(try TripJSONExportService.normalizedGEMS("GEMS1234567")) { error in
            XCTAssertEqual(error as? TripJSONExportError, .invalidOwnerGEMS)
        }
        XCTAssertThrowsError(try publicExport(
            ownerSource: ownerSource(profileGEMS: "", verifiedGEMS: ""),
            payload: payload(crew: [])
        )) { error in
            XCTAssertEqual(error as? TripJSONExportError, .invalidOwnerGEMS)
        }
        XCTAssertThrowsError(try publicExport(
            ownerSource: ownerSource(profileGEMS: "", verifiedGEMS: ""),
            payload: payload(crew: [
                CrewAccessCrewJSON(
                    position: "CA",
                    seniority: "1",
                    crewID: "1234567",
                    name: "OTHER CREW MEMBER"
                )
            ])
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

        XCTAssertEqual(export.events.map(\.type), [.flight, .layover, .deadhead])
        XCTAssertEqual(export.events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(export.events[0].flightNumber, "5X123")
        XCTAssertEqual(export.events[2].flightNumber, "5X124")
        XCTAssertEqual(export.events[1].previousSegmentID, export.events[0].id)
        XCTAssertEqual(export.events[1].nextSegmentID, export.events[2].id)
        XCTAssertEqual(export.events[2].type, .deadhead)
    }

    func test_26732StyleFlightLayoverDeadheadUsesSegmentReferencesAndAllTargetsExist() throws {
        let tripPayload = payload(
            tripID: "26732",
            hotelDetails: ["SZX: JW Marriott Shenzhen"],
            items: [
                item(
                    sequence: 1,
                    flight: "5X267",
                    start: "2026-07-31T12:00:00Z",
                    end: "2026-07-31T20:00:00Z",
                    depAirport: "ANC",
                    arrAirport: "SZX",
                    destinationTz: "Asia/Shanghai"
                ),
                item(
                    sequence: 3,
                    deadhead: true,
                    flight: "5X268",
                    start: "2026-08-02T02:00:00Z",
                    end: "2026-08-02T12:00:00Z",
                    depAirport: "SZX",
                    arrAirport: "ANC",
                    originTz: "Asia/Shanghai",
                    destinationTz: "America/Anchorage"
                )
            ]
        )
        let export = try publicExport(
            schedule: schedule(for: tripPayload),
            payload: tripPayload
        )
        let layover = try XCTUnwrap(export.events.first { $0.type == .layover })
        let eventIDs = Set(export.events.map(\.id))

        XCTAssertEqual(export.events.map(\.type), [.flight, .layover, .deadhead])
        XCTAssertEqual(layover.previousSegmentID, export.events[0].id)
        XCTAssertEqual(layover.nextSegmentID, export.events[2].id)
        XCTAssertTrue(eventIDs.contains(try XCTUnwrap(layover.previousSegmentID)))
        XCTAssertTrue(eventIDs.contains(try XCTUnwrap(layover.nextSegmentID)))
        XCTAssertEqual(layover.hotel?.name, "JW Marriott Shenzhen")

        let data = try TripJSONExportService.encodedData(for: export)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("previousFlightID"))
        XCTAssertFalse(text.contains("nextFlightID"))
        XCTAssertTrue(text.contains("previousSegmentID"))
        XCTAssertTrue(text.contains("nextSegmentID"))
    }

    func test_deadheadLayoverFlightUsesSegmentReferences() throws {
        let tripPayload = payload(
            tripID: "DH-ROUNDTRIP",
            hotelDetails: ["SDF: Example Hotel"],
            items: [
                item(
                    sequence: 1,
                    deadhead: true,
                    flight: "5X201",
                    start: "2026-07-20T10:00:00Z",
                    end: "2026-07-20T15:00:00Z",
                    depAirport: "ANC",
                    arrAirport: "SDF"
                ),
                item(
                    sequence: 3,
                    flight: "5X202",
                    start: "2026-07-22T10:00:00Z",
                    end: "2026-07-22T18:00:00Z",
                    depAirport: "SDF",
                    arrAirport: "ANC",
                    originTz: "America/Kentucky/Louisville",
                    destinationTz: "America/Anchorage"
                )
            ]
        )
        let export = try publicExport(
            schedule: schedule(for: tripPayload),
            payload: tripPayload
        )
        let layover = try XCTUnwrap(export.events.first { $0.type == .layover })

        XCTAssertEqual(export.events.map(\.type), [.deadhead, .layover, .flight])
        XCTAssertEqual(layover.previousSegmentID, export.events[0].id)
        XCTAssertEqual(layover.nextSegmentID, export.events[2].id)
    }

    func test_a70518StyleExportPreservesRestCalculation() throws {
        let tripPayload = payload(
            tripID: "A70518",
            hotelDetails: ["NRT: Hilton Narita"],
            items: [
                item(
                    sequence: 1,
                    flight: "5X105",
                    start: "2026-07-20T10:00:00Z",
                    end: "2026-07-20T20:00:00Z",
                    depAirport: "ANC",
                    arrAirport: "NRT",
                    destinationTz: "Asia/Tokyo"
                ),
                item(
                    sequence: 3,
                    flight: "5X106",
                    start: "2026-07-22T10:00:00Z",
                    end: "2026-07-22T18:00:00Z",
                    depAirport: "NRT",
                    arrAirport: "ANC",
                    originTz: "Asia/Tokyo",
                    destinationTz: "America/Anchorage"
                )
            ]
        )
        let export = try publicExport(
            schedule: schedule(for: tripPayload),
            payload: tripPayload
        )
        let layover = try XCTUnwrap(export.events.first { $0.type == .layover })

        XCTAssertEqual(layover.hotel?.name, "Hilton Narita")
        XCTAssertEqual(layover.scheduledRest?.durationMinutes, 2_160)
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

    func test_operationalTimesUseEffectiveOffsetAcrossDSTFallback() throws {
        let beforeFallback = try TripJSONExportService.exportTimestamp(
            "2026-11-01T09:30:00Z",
            timeZoneID: "America/Anchorage"
        )
        let afterFallback = try TripJSONExportService.exportTimestamp(
            "2026-11-01T10:30:00Z",
            timeZoneID: "America/Anchorage"
        )

        XCTAssertEqual(beforeFallback.local, "2026-11-01T01:30:00")
        XCTAssertEqual(beforeFallback.utcOffset, "-08:00")
        XCTAssertEqual(afterFallback.local, "2026-11-01T01:30:00")
        XCTAssertEqual(afterFallback.utcOffset, "-09:00")
    }

    func test_groundTransportRowsAreDeferredInsteadOfMislabeledAsFlights() throws {
        let withGroundTransport = payload(items: [
            item(
                sequence: 1,
                flight: "5X101",
                start: "2026-07-18T16:00:00Z",
                end: "2026-07-18T21:00:00Z"
            ),
            item(
                sequence: 2,
                flight: "GND",
                start: "2026-07-18T22:00:00Z",
                end: "2026-07-18T23:00:00Z",
                depAirport: "SDF",
                arrAirport: "MEM"
            ),
            item(
                sequence: 3,
                flight: "5X102",
                start: "2026-07-19T12:00:00Z",
                end: "2026-07-19T16:00:00Z",
                depAirport: "MEM",
                arrAirport: "ANC"
            )
        ])

        let export = try publicExport(
            schedule: schedule(for: withGroundTransport),
            payload: withGroundTransport
        )

        XCTAssertEqual(export.events.map(\.type), [.flight, .layover, .flight])
        XCTAssertEqual(export.events.map(\.sequence), [1, 2, 3])
        XCTAssertFalse(export.events.contains { $0.flightNumber == "GND" })
        XCTAssertFalse(export.events.contains { $0.type == .groundTransport })
        let layover = try XCTUnwrap(export.events.first { $0.type == .layover })
        XCTAssertEqual(layover.station, "SDF")
        XCTAssertEqual(layover.hotel?.name, "Example Hotel")
        XCTAssertNotNil(layover.scheduledRest)
        XCTAssertEqual(layover.previousSegmentID, export.events[0].id)
        XCTAssertEqual(layover.nextSegmentID, export.events[2].id)
    }

    func test_eventsSortByInstantThenSequenceThenID() throws {
        let unsorted = payload(items: [
            item(sequence: 9, deadhead: true, flight: "5X999", start: "2026-07-18T22:00:00Z", end: "2026-07-19T01:00:00Z"),
            item(sequence: 2, deadhead: true, flight: "5X002", start: "2026-07-18T16:00:00Z", end: "2026-07-18T18:00:00Z"),
            item(sequence: 1, deadhead: false, flight: "5X001", start: "2026-07-18T16:00:00Z", end: "2026-07-18T17:00:00Z")
        ])
        let events = try publicExport(payload: unsorted).events

        XCTAssertEqual(events.map(\.sequence), [1, 2, 3])
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
        XCTAssertEqual(Set(namePaths), Set(["generator.name", "owner.name", "events.hotel.name"]))
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
        XCTAssertTrue(text.contains(#""schemaVersion" : "1.2""#))
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

    func test_structuredLayoverMapsToLayoverHotelMetadata() throws {
        let export = try publicExport(schedule: schedule(includeHotel: true))
        let layover = try XCTUnwrap(export.events.first { $0.type == .layover })

        XCTAssertEqual(layover.station, "SDF")
        XCTAssertEqual(layover.hotel?.name, "Example Hotel")
        XCTAssertEqual(layover.start.instant, "2026-07-18T21:00:00Z")
        XCTAssertEqual(layover.end.instant, "2026-07-19T14:00:00Z")
        XCTAssertEqual(layover.blockGap?.durationMinutes, 1_020)
        XCTAssertEqual(layover.blockGap?.derived, true)
        XCTAssertEqual(layover.scheduledRest?.durationMinutes, 900)
        XCTAssertNil(layover.hotelStay)
    }

    func test_a70610StyleTripEmitsSDFAndNRTLayoversInContinuousOrder() throws {
        let tripPayload = payload(
            tripID: "A70610",
            hotelDetails: [
                "SDF: Crowne Plaza Louisville Airpor 502-367-2251",
                "NRT: Hilton Narita"
            ],
            items: [
                item(
                    sequence: 1,
                    flight: "5X061",
                    start: "2026-07-21T21:53:00Z",
                    end: "2026-07-22T04:53:00Z",
                    depAirport: "ANC",
                    arrAirport: "SDF"
                ),
                item(
                    sequence: 3,
                    flight: "5X108",
                    start: "2026-07-23T09:05:00Z",
                    end: "2026-07-23T22:30:00Z",
                    depAirport: "SDF",
                    arrAirport: "NRT",
                    originTz: "America/Kentucky/Louisville",
                    destinationTz: "Asia/Tokyo"
                ),
                item(
                    sequence: 5,
                    flight: "5X109",
                    start: "2026-07-25T12:55:00Z",
                    end: "2026-07-25T19:55:00Z",
                    depAirport: "NRT",
                    arrAirport: "ANC",
                    originTz: "Asia/Tokyo",
                    destinationTz: "America/Anchorage"
                )
            ]
        )
        let export = try publicExport(
            schedule: schedule(for: tripPayload),
            payload: tripPayload
        )

        XCTAssertEqual(export.events.map(\.type), [.flight, .layover, .flight, .layover, .flight])
        XCTAssertEqual(export.events.map(\.sequence), [1, 2, 3, 4, 5])
        let layovers = export.events.filter { $0.type == .layover }
        XCTAssertEqual(layovers.map(\.station), ["SDF", "NRT"])
        XCTAssertEqual(layovers.map { $0.blockGap?.durationMinutes }, [1_692, 2_305])
        XCTAssertEqual(layovers[0].previousSegmentID, export.events[0].id)
        XCTAssertEqual(layovers[0].nextSegmentID, export.events[2].id)
        XCTAssertEqual(layovers[1].previousSegmentID, export.events[2].id)
        XCTAssertEqual(layovers[1].nextSegmentID, export.events[4].id)
        XCTAssertEqual(layovers[0].hotel, ExportHotel(
            name: "Crowne Plaza Louisville Airport Expo Center",
            address: nil,
            phone: "502-367-2251",
            sourceName: "Crowne Plaza Louisville Airpor",
            nameNormalization: ExportHotelNameNormalization(
                derived: true,
                method: "knownHotelDirectory",
                matchedBy: "stationAndPhone"
            )
        ))
        XCTAssertEqual(layovers[1].hotel, ExportHotel(name: "Hilton Narita", address: nil, phone: nil))
        let sdfRest = try XCTUnwrap(layovers[0].scheduledRest)
        XCTAssertEqual(sdfRest.durationMinutes, 1_572)
        XCTAssertEqual(sdfRest.dutyEnd.instant, "2026-07-22T05:23:00Z")
        XCTAssertEqual(sdfRest.dutyEnd.local, "2026-07-22T01:23:00")
        XCTAssertEqual(sdfRest.dutyEnd.timeZone, "America/Kentucky/Louisville")
        XCTAssertEqual(sdfRest.dutyEnd.utcOffset, "-04:00")
        XCTAssertEqual(sdfRest.nextDutyStart.instant, "2026-07-23T07:35:00Z")
        XCTAssertEqual(sdfRest.nextDutyStart.local, "2026-07-23T03:35:00")
        XCTAssertEqual(sdfRest.nextDutyStart.timeZone, "America/Kentucky/Louisville")
        XCTAssertEqual(sdfRest.nextDutyStart.utcOffset, "-04:00")
        XCTAssertTrue(sdfRest.derived)
        XCTAssertEqual(sdfRest.calculationRule.dutyEndMinutesAfterBlockIn, 30)
        XCTAssertEqual(sdfRest.calculationRule.dutyStartMinutesBeforeBlockOut, 90)

        let nrtRest = try XCTUnwrap(layovers[1].scheduledRest)
        XCTAssertEqual(nrtRest.durationMinutes, 2_185)
        XCTAssertEqual(nrtRest.dutyEnd.instant, "2026-07-23T23:00:00Z")
        XCTAssertEqual(nrtRest.dutyEnd.local, "2026-07-24T08:00:00")
        XCTAssertEqual(nrtRest.dutyEnd.timeZone, "Asia/Tokyo")
        XCTAssertEqual(nrtRest.dutyEnd.utcOffset, "+09:00")
        XCTAssertEqual(nrtRest.nextDutyStart.instant, "2026-07-25T11:25:00Z")
        XCTAssertEqual(nrtRest.nextDutyStart.local, "2026-07-25T20:25:00")
        XCTAssertEqual(nrtRest.nextDutyStart.timeZone, "Asia/Tokyo")
        XCTAssertEqual(nrtRest.nextDutyStart.utcOffset, "+09:00")

        let encoded = try TripJSONExportService.encodedData(for: export)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedEvents = try XCTUnwrap(root["events"] as? [[String: Any]])
        let encodedSDF = try XCTUnwrap(encodedEvents.first { $0["station"] as? String == "SDF" })
        let encodedRest = try XCTUnwrap(encodedSDF["scheduledRest"] as? [String: Any])
        let encodedRule = try XCTUnwrap(encodedRest["calculationRule"] as? [String: Any])
        let encodedHotel = try XCTUnwrap(encodedSDF["hotel"] as? [String: Any])
        let encodedNormalization = try XCTUnwrap(encodedHotel["nameNormalization"] as? [String: Any])
        XCTAssertEqual(encodedRest["durationMinutes"] as? Int, 1_572)
        XCTAssertEqual(encodedRest["derived"] as? Bool, true)
        XCTAssertEqual(encodedRule["dutyEndMinutesAfterBlockIn"] as? Int, 30)
        XCTAssertEqual(encodedRule["dutyStartMinutesBeforeBlockOut"] as? Int, 90)
        XCTAssertEqual(encodedHotel["name"] as? String, "Crowne Plaza Louisville Airport Expo Center")
        XCTAssertEqual(encodedHotel["sourceName"] as? String, "Crowne Plaza Louisville Airpor")
        XCTAssertEqual(encodedNormalization["derived"] as? Bool, true)
        XCTAssertEqual(encodedNormalization["method"] as? String, "knownHotelDirectory")
        XCTAssertEqual(encodedNormalization["matchedBy"] as? String, "stationAndPhone")
    }

    func test_knownHotelDirectoryNormalizesPhoneNotationWithoutGuessing() {
        for phone in ["502-367-2251", "(502) 367-2251", "+1 502 367 2251"] {
            let result = HotelNameNormalizer.publicName(
                station: "SDF",
                rawName: "Crowne Plaza Louisville Airpor",
                phone: phone
            )
            XCTAssertEqual(result.name, "Crowne Plaza Louisville Airport Expo Center", phone)
            XCTAssertEqual(result.sourceName, "Crowne Plaza Louisville Airpor", phone)
            XCTAssertEqual(result.matchedBy, "stationAndPhone", phone)
        }
        XCTAssertEqual(
            HotelNameNormalizer.normalizedPhone("011-81-476-331-121"),
            "+81476331121"
        )
        let rawNameMatch = HotelNameNormalizer.publicName(
            station: "SDF",
            rawName: "Crowne Plaza Louisville Airpor",
            phone: nil
        )
        XCTAssertEqual(rawNameMatch.name, "Crowne Plaza Louisville Airport Expo Center")
        XCTAssertEqual(rawNameMatch.matchedBy, "stationAndRawName")
    }

    func test_knownHotelDirectoryReportsTheSuccessfulBranchAndRejectsAmbiguity() {
        let uniquePhone = HotelNameNormalizer.publicName(
            station: "NRT",
            rawName: "Unrelated Source Name",
            phone: "502-367-2251"
        )
        XCTAssertEqual(uniquePhone.name, "Crowne Plaza Louisville Airport Expo Center")
        XCTAssertEqual(uniquePhone.matchedBy, "phone")

        let uniqueRawName = HotelNameNormalizer.publicName(
            station: "NRT",
            rawName: "Crowne Plaza Louisville Airpor",
            phone: nil
        )
        XCTAssertEqual(uniqueRawName.name, "Crowne Plaza Louisville Airport Expo Center")
        XCTAssertEqual(uniqueRawName.matchedBy, "rawName")

        let duplicateDirectory = [
            HotelNameNormalizer.KnownHotel(
                station: "SDF",
                normalizedPhone: "+15023672251",
                rawName: "Shared Raw Hotel",
                canonicalName: "SDF Canonical Hotel"
            ),
            HotelNameNormalizer.KnownHotel(
                station: "NRT",
                normalizedPhone: "+15023672251",
                rawName: "Shared Raw Hotel",
                canonicalName: "NRT Canonical Hotel"
            )
        ]
        let ambiguousPhone = HotelNameNormalizer.publicName(
            station: "ICN",
            rawName: "Unknown Source",
            phone: "502-367-2251",
            directory: duplicateDirectory
        )
        XCTAssertEqual(ambiguousPhone.name, "Unknown Source")
        XCTAssertNil(ambiguousPhone.matchedBy)

        let stationDisambiguatesPhone = HotelNameNormalizer.publicName(
            station: "SDF",
            rawName: "Unknown Source",
            phone: "502-367-2251",
            directory: duplicateDirectory
        )
        XCTAssertEqual(stationDisambiguatesPhone.name, "SDF Canonical Hotel")
        XCTAssertEqual(stationDisambiguatesPhone.matchedBy, "stationAndPhone")

        let ambiguousRawName = HotelNameNormalizer.publicName(
            station: "ICN",
            rawName: "Shared Raw Hotel",
            phone: nil,
            directory: duplicateDirectory
        )
        XCTAssertEqual(ambiguousRawName.name, "Shared Raw Hotel")
        XCTAssertNil(ambiguousRawName.matchedBy)

        let stationDisambiguatesRawName = HotelNameNormalizer.publicName(
            station: "NRT",
            rawName: "Shared Raw Hotel",
            phone: nil,
            directory: duplicateDirectory
        )
        XCTAssertEqual(stationDisambiguatesRawName.name, "NRT Canonical Hotel")
        XCTAssertEqual(stationDisambiguatesRawName.matchedBy, "stationAndRawName")
    }

    func test_unknownTruncatedHotelIsPreservedAndMissingPhoneDoesNotFail() throws {
        let unknownName = "Unknown Airport Hot"
        let result = HotelNameNormalizer.publicName(
            station: "SDF",
            rawName: unknownName,
            phone: nil
        )
        XCTAssertEqual(result.name, unknownName)
        XCTAssertNil(result.sourceName)
        XCTAssertNil(result.matchedBy)

        let tripPayload = payload(hotelDetails: ["SDF: \(unknownName)"])
        let export = try publicExport(payload: tripPayload)
        let hotel = try XCTUnwrap(export.events.first { $0.type == .layover }?.hotel)
        XCTAssertEqual(hotel.name, unknownName)
        XCTAssertNil(hotel.phone)
        XCTAssertNil(hotel.sourceName)
        XCTAssertNil(hotel.nameNormalization)
    }

    func test_unregisteredKnownDisplaysRemainUnchanged() {
        for (station, name) in [
            ("NRT", "Hilton Narita"),
            ("ICN", "Sheraton Incheon"),
            ("SZX", "JW Marriott Shenzhen")
        ] {
            let result = HotelNameNormalizer.publicName(
                station: station,
                rawName: name,
                phone: nil
            )
            XCTAssertEqual(result.name, name)
            XCTAssertNil(result.sourceName)
            XCTAssertNil(result.matchedBy)
        }
    }

    func test_missingHotelFieldsAreOmittedWithoutFailingExport() throws {
        let tripPayload = payload(hotelDetails: ["SDF: Example Hotel"])
        let data = try TripJSONExportService.encodedData(for: publicExport(payload: tripPayload))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        let layover = try XCTUnwrap(events.first { $0["type"] as? String == "layover" })
        let hotel = try XCTUnwrap(layover["hotel"] as? [String: Any])

        XCTAssertEqual(hotel["name"] as? String, "Example Hotel")
        XCTAssertNil(hotel["address"])
        XCTAssertNil(hotel["phone"])
        XCTAssertNotNil(layover["scheduledRest"])
        XCTAssertNil(layover["hotelStay"])
    }

    func test_sameDutyFlightsDoNotCreateLayoverOrScheduledRest() throws {
        let sameDutyPayload = payload(
            hotelDetails: [],
            items: [
                item(
                    sequence: 1,
                    flight: "5X101",
                    start: "2026-07-18T16:00:00Z",
                    end: "2026-07-18T21:00:00Z",
                    depAirport: "ANC",
                    arrAirport: "SDF"
                ),
                item(
                    sequence: 1,
                    flight: "5X102",
                    start: "2026-07-18T23:00:00Z",
                    end: "2026-07-19T05:00:00Z",
                    depAirport: "SDF",
                    arrAirport: "ANC",
                    originTz: "America/Kentucky/Louisville",
                    destinationTz: "America/Anchorage"
                )
            ]
        )
        let export = try publicExport(
            schedule: schedule(for: sameDutyPayload),
            payload: sameDutyPayload
        )

        XCTAssertEqual(export.events.map(\.type), [.flight, .flight])
        XCTAssertEqual(export.events.map(\.sequence), [1, 2])
        XCTAssertTrue(export.events.allSatisfy { $0.scheduledRest == nil })
    }

    func test_singleLegTripDoesNotCreateLayover() throws {
        let singleLegPayload = payload(items: [item()])
        let export = try publicExport(
            schedule: schedule(for: singleLegPayload),
            payload: singleLegPayload
        )

        XCTAssertEqual(export.events.map(\.type), [.flight])
        XCTAssertEqual(export.events.map(\.sequence), [1])
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
        XCTAssertEqual(decoded.events.map(\.type), [.flight, .layover, .flight])
        XCTAssertEqual(decoded.events.map(\.sequence), [1, 2, 3])
        let layover = try XCTUnwrap(decoded.events.first { $0.type == .layover })
        XCTAssertEqual(layover.station, "ICN")
        XCTAssertEqual(layover.hotel?.name, "Sheraton Incheon")
        XCTAssertEqual(layover.hotel?.phone, "011-82-32-835-1000")
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
