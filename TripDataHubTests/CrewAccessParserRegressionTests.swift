import XCTest
@testable import TripDataHub

final class CrewAccessParserRegressionTests: XCTestCase {
    private let cases: [(pdf: String, golden: String)] = [
        ("2026-03-04_A70878.pdf", "golden_A70651.json"),
        ("2026-01-15_A70752.pdf", "golden_A70752.json"),
        ("2026-01-29_A70502.pdf", "golden_A70502.json")
    ]

    func test_samplePDFs_matchGoldenJSONIgnoringGeneratedAt() throws {
        let service = CrewAccessPDFImportService()

        for testCase in cases {
            let draft = try parseDraft(pdfName: testCase.pdf, service: service)
            XCTAssertTrue(draft.errors.isEmpty, "\(testCase.pdf) errors: \(draft.errors.map(\.message).joined(separator: "; "))")
            let payload = try XCTUnwrap(draft.jsonPayload, "\(testCase.pdf) should produce JSON")

            let actual = try normalizedJSONObject(from: payload)
            let expectedData = try Data(contentsOf: sampleTripURL(testCase.golden))
            let expected = try normalizedJSONObject(fromJSONData: expectedData)
            let actualDictionary = try XCTUnwrap(actual as? NSDictionary)
            let expectedDictionary = try XCTUnwrap(expected as? NSDictionary)
            XCTAssertEqual(actualDictionary, expectedDictionary, "\(testCase.pdf) should match \(testCase.golden)")
        }
    }

    func test_samplePDFs_satisfyCoreParserInvariants() throws {
        let service = CrewAccessPDFImportService()
        let utcFormatter = ISO8601DateFormatter()
        utcFormatter.formatOptions = [.withInternetDateTime]

        for testCase in cases {
            let draft = try parseDraft(pdfName: testCase.pdf, service: service)
            XCTAssertTrue(draft.errors.isEmpty, "\(testCase.pdf) errors: \(draft.errors.map(\.message).joined(separator: "; "))")
            let payload = try XCTUnwrap(draft.jsonPayload, "\(testCase.pdf) should produce JSON")

            XCTAssertEqual(payload.schemaVersion, 2)
            XCTAssertNotNil(payload.pdfCreatedUtc, "\(testCase.pdf) should retain PDF Created UTC")
            XCTAssertFalse(payload.tripId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(payload.items.isEmpty, "\(testCase.pdf) should contain legs")

            for item in payload.items {
                XCTAssertEqual(item.depAirport.count, 3, "\(testCase.pdf) dep IATA")
                XCTAssertEqual(item.arrAirport.count, 3, "\(testCase.pdf) arr IATA")
                XCTAssertNotNil(utcFormatter.date(from: item.startUtc), "\(testCase.pdf) startUtc parse")
                XCTAssertNotNil(utcFormatter.date(from: item.endUtc), "\(testCase.pdf) endUtc parse")
                XCTAssertNotEqual(item.stdUtc == nil, item.atdUtc == nil, "\(testCase.pdf) departure must be classified once")
                XCTAssertNotEqual(item.staUtc == nil, item.ataUtc == nil, "\(testCase.pdf) arrival must be classified once")
                XCTAssertFalse(item.flight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertEqual(item.tripImportedAtUtc, payload.generatedAt)
                if item.atdUtc != nil && item.ataUtc != nil {
                    XCTAssertEqual(item.actualsImportedAtUtc, payload.generatedAt)
                } else {
                    XCTAssertNil(item.actualsImportedAtUtc)
                }
            }
        }
    }

    // MARK: - Scheduled / Actual classification, through the real parser

    /// Every classification branch in one parse of one real PDF (INV-012).
    ///
    /// `sample_trip/crewaccess_classification_matrix.pdf` is Created 15Jun2026 10:00Z and is laid
    /// out so its three legs straddle that instant. These expectations are hardcoded, not derived
    /// from the Created time, so a reimplementation of the rule in the test cannot agree with a
    /// broken implementation in the parser — which is precisely how the previous helper-generated
    /// payload tests could pass against an inverted comparison.
    ///
    /// Regenerate with `python3 scripts/generate_crewaccess_classification_fixtures.py`.
    func test_classificationMatrixPDF_classifiesEachEndpointAgainstCreatedUTC() throws {
        let service = CrewAccessPDFImportService()
        let draft = try parseDraft(pdfName: "crewaccess_classification_matrix.pdf", service: service)
        XCTAssertTrue(draft.errors.isEmpty, draft.errors.map(\.message).joined(separator: "; "))

        let payload = try XCTUnwrap(draft.jsonPayload)
        XCTAssertEqual(payload.tripId, "C00001")
        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.pdfCreatedUtc, "2026-06-15T10:00:00Z")
        XCTAssertEqual(payload.items.count, 3)

        // Case 3 — Created is after both endpoints: the whole leg is history.
        let flown = try XCTUnwrap(payload.items.first { $0.sequence == 1 })
        XCTAssertNil(flown.stdUtc, "Created > DEP must not record a Scheduled departure")
        XCTAssertNil(flown.staUtc, "Created > ARR must not record a Scheduled arrival")
        XCTAssertNil(flown.originalStdUtc, "no Scheduled observation means no Original Scheduled")
        XCTAssertEqual(flown.atdUtc, "2026-06-14T13:00:00Z")
        XCTAssertEqual(flown.ataUtc, "2026-06-14T19:00:00Z")
        XCTAssertEqual(flown.actualDepartureObservedAtUtc, "2026-06-15T10:00:00Z")
        XCTAssertEqual(flown.actualArrivalObservedAtUtc, "2026-06-15T10:00:00Z")
        XCTAssertNil(flown.scheduledDepartureObservedAtUtc)

        // Case 2 — DEP <= Created < ARR: departed, still airborne. Also pins the exact departure
        // boundary, because this leg's DEP instant *equals* the Created instant. `Created >= DEP`
        // classifies as Actual; this is the intended rule and must not drift to a tolerance.
        let airborne = try XCTUnwrap(payload.items.first { $0.sequence == 2 })
        XCTAssertEqual(airborne.atdUtc, "2026-06-15T10:00:00Z", "Created == DEP is an Actual departure")
        XCTAssertNil(airborne.stdUtc)
        XCTAssertNil(airborne.originalStdUtc)
        XCTAssertEqual(airborne.staUtc, "2026-06-15T22:00:00Z", "Created < ARR is still Scheduled")
        XCTAssertEqual(airborne.originalStaUtc, "2026-06-15T22:00:00Z")
        XCTAssertEqual(airborne.scheduledArrivalObservedAtUtc, "2026-06-15T10:00:00Z")
        XCTAssertNil(airborne.ataUtc)
        XCTAssertNil(airborne.actualArrivalObservedAtUtc)

        // Case 1 — Created is before both endpoints: purely scheduled.
        let future = try XCTUnwrap(payload.items.first { $0.sequence == 3 })
        XCTAssertEqual(future.stdUtc, "2026-06-16T00:30:00Z")
        XCTAssertEqual(future.originalStdUtc, "2026-06-16T00:30:00Z")
        XCTAssertEqual(future.staUtc, "2026-06-16T09:30:00Z")
        XCTAssertEqual(future.originalStaUtc, "2026-06-16T09:30:00Z")
        XCTAssertNil(future.atdUtc)
        XCTAssertNil(future.ataUtc)
        XCTAssertEqual(future.scheduledDepartureObservedAtUtc, "2026-06-15T10:00:00Z")
        XCTAssertNil(future.actualDepartureObservedAtUtc)
    }

    /// The arrival side of the exact boundary: `Created == ARR` is an Actual arrival.
    /// Deliberately documents the `>=` rule rather than introducing a tolerance around it.
    func test_arrivalBoundaryPDF_treatsCreatedEqualToArrivalAsActual() throws {
        let service = CrewAccessPDFImportService()
        let draft = try parseDraft(pdfName: "crewaccess_arrival_boundary.pdf", service: service)
        XCTAssertTrue(draft.errors.isEmpty, draft.errors.map(\.message).joined(separator: "; "))

        let payload = try XCTUnwrap(draft.jsonPayload)
        XCTAssertEqual(payload.tripId, "C00002")
        XCTAssertEqual(payload.pdfCreatedUtc, "2026-06-14T19:00:00Z")

        let boundary = try XCTUnwrap(payload.items.first { $0.sequence == 1 })
        XCTAssertEqual(boundary.ataUtc, "2026-06-14T19:00:00Z", "Created == ARR is an Actual arrival")
        XCTAssertNil(boundary.staUtc)
        XCTAssertNil(boundary.originalStaUtc)
        XCTAssertEqual(boundary.actualArrivalObservedAtUtc, "2026-06-14T19:00:00Z")

        let later = try XCTUnwrap(payload.items.first { $0.sequence == 2 })
        XCTAssertEqual(later.stdUtc, "2026-06-15T10:00:00Z")
        XCTAssertEqual(later.staUtc, "2026-06-15T22:00:00Z")
        XCTAssertNil(later.atdUtc)
        XCTAssertNil(later.ataUtc)
    }

    /// `extractPDFCreatedUTC` is the single input every classification decision depends on, so it
    /// gets direct coverage instead of only being exercised through a full parse.
    func test_extractPDFCreatedUTC_parsesFooterVariantsAndRejectsAbsence() throws {
        let expected = ISO8601DateFormatter().date(from: "2026-08-09T02:15:00Z")

        XCTAssertEqual(
            CrewAccessPDFImportService.extractPDFCreatedUTC(
                from: ["Created 09Aug2026 02:15 (UTC) by 00007793942"]
            ),
            expected,
            "canonical CrewAccess footer"
        )
        XCTAssertEqual(
            CrewAccessPDFImportService.extractPDFCreatedUTC(
                from: ["   Created   09AUG2026   02:15   (UTC)   by TripDataHub   "]
            ),
            expected,
            "uppercase month and padded whitespace"
        )
        XCTAssertEqual(
            CrewAccessPDFImportService.extractPDFCreatedUTC(
                from: ["Trip Id: A70393R", "irrelevant", "Created 09aug2026 02:15 (UTC)"]
            ),
            expected,
            "lowercase month, footer not on the first line"
        )
        XCTAssertNil(
            CrewAccessPDFImportService.extractPDFCreatedUTC(from: ["Trip Id: A70393R", "no footer"]),
            "a missing Created line must stay unknown rather than be fabricated"
        )
        XCTAssertNil(
            CrewAccessPDFImportService.extractPDFCreatedUTC(from: ["Created 09Aug2026 02:15 (LCL)"]),
            "only an explicit (UTC) footer is a valid observation time"
        )
    }

    func test_appReviewSamplePDF_importsWithoutCrewIdentity() throws {
        let service = CrewAccessPDFImportService()
        let sampleURL = repositoryRootURL()
            .appendingPathComponent("web")
            .appendingPathComponent("sample")
            .appendingPathComponent("TripDataHub_App_Review_Sample_A00001.pdf")
        let data = try Data(contentsOf: sampleURL)
        let draft = service.analyzeTrip(pdfData: data, sourceFileName: sampleURL.lastPathComponent)
        XCTAssertTrue(draft.errors.isEmpty, "App Review sample errors: \(draft.errors.map(\.message).joined(separator: "; "))")

        let payload = try XCTUnwrap(draft.jsonPayload)
        XCTAssertEqual(payload.tripId, "A00001")
        XCTAssertEqual(payload.crew.count, 0)
        XCTAssertEqual(payload.items.count, 3)
        XCTAssertEqual(payload.items.map(\.flight), ["5X001", "5X002", "5X003"])
        XCTAssertEqual(payload.items.map(\.depAirport), ["ANC", "CVG", "HND"])
        XCTAssertEqual(payload.items.map(\.arrAirport), ["CVG", "HND", "ANC"])
        XCTAssertEqual(payload.items.map(\.deadhead), [false, false, true])
        XCTAssertTrue(payload.hotelDetails.contains { $0.contains("Holiday Inn") })
        XCTAssertTrue(payload.hotelDetails.contains { $0.contains("Tokyu Haneda") })
    }

    func test_trip12194_preservesGroundTransportTimesAndSydneyHotelName() throws {
        let service = CrewAccessPDFImportService()
        let draft = try parseDraft(pdfName: "2026-08-16_12194.pdf", service: service)

        XCTAssertTrue(draft.errors.isEmpty, draft.errors.map(\.message).joined(separator: "; "))
        let payload = try XCTUnwrap(draft.jsonPayload)
        let schedule = try XCTUnwrap(draft.parsedSchedule)
        let groundItem = try XCTUnwrap(payload.items.first {
            $0.flight == "GND" && $0.depAirport == "CGN" && $0.arrAirport == "FRA"
        })
        XCTAssertEqual(groundItem.startUtc, "2026-08-24T11:40:00Z")
        XCTAssertEqual(groundItem.endUtc, "2026-08-24T13:40:00Z")
        XCTAssertEqual(groundItem.startLocalDisplay, "2026-08-24 13:40")
        XCTAssertEqual(groundItem.endLocalDisplay, "2026-08-24 15:40")

        let groundLeg = try XCTUnwrap(schedule.legs.first {
            $0.flight == "GND" && $0.depAirport == "CGN" && $0.arrAirport == "FRA"
        })
        XCTAssertEqual(groundLeg.status, "GND")
        XCTAssertEqual(TimelineLegIconSupport.fallbackSystemName(for: groundLeg.status), "car.fill")
        let groundKey = CrewAccessTripSummaryStore.legUTCKey(
            tripID: "12194",
            sequence: 9,
            flight: "GND",
            depAirport: "CGN",
            arrAirport: "FRA"
        )
        let deadheadKey = CrewAccessTripSummaryStore.legUTCKey(
            tripID: "12194",
            sequence: 9,
            flight: "LH1040",
            depAirport: "FRA",
            arrAirport: "CDG"
        )
        XCTAssertNotEqual(groundKey, deadheadKey)

        let sydneyLeg = try XCTUnwrap(schedule.legs.first { $0.arrAirport == "SYD" })
        XCTAssertEqual(sydneyLeg.layoverHotelName, "Crowne Plaza Sydney Darling Harbour")

        let nextLegData = TimelineLegData(schedules: [schedule])
        let connection = LegConnectionTextBuilder.connectionInfo(
            after: groundLeg,
            nextLegByID: nextLegData.nextLegByID
        )
        XCTAssertEqual(connection?.minutes, 60)
        XCTAssertEqual(connection?.airport, "FRA")
    }

    private func parseDraft(pdfName: String, service: CrewAccessPDFImportService) throws -> CrewAccessImportDraft {
        let pdfURL = sampleTripURL(pdfName)
        let data = try Data(contentsOf: pdfURL)
        return service.analyzeTrip(pdfData: data, sourceFileName: pdfURL.lastPathComponent)
    }

    private func normalizedJSONObject(from payload: CrewAccessTripJSON) throws -> Any {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try normalizedJSONObject(fromJSONData: encoder.encode(payload))
    }

    private func normalizedJSONObject(fromJSONData data: Data) throws -> Any {
        let object = try JSONSerialization.jsonObject(with: data)
        return removeNonDeterministicKeys(from: object)
    }

    /// Only genuinely non-deterministic values are excluded from the golden comparison.
    ///
    /// This set was previously much larger and swallowed `stdUtc` / `staUtc` / `atdUtc` /
    /// `ataUtc` / `pdfCreatedUtc` / `schemaVersion` and the whole leg-history block. That left the
    /// strongest parser guard in the repository blind to exactly the Scheduled-versus-Actual
    /// classification it should be pinning: inverting the Created comparison, or breaking the
    /// Created regex so every PDF fell back to "Scheduled", would not have failed a single test.
    ///
    /// - `generatedAt`, `tripImportedAtUtc`, and `actualsImportedAtUtc` use the single `Date()`
    ///   captured for this parse/import operation. Their equality is asserted above.
    /// - `stableLegId` is a fresh `UUID()` for every parse of a PDF that has no prior history.
    ///
    /// Everything else is a pure function of the PDF bytes and belongs in the golden.
    private func removeNonDeterministicKeys(from object: Any) -> Any {
        if let dict = object as? [String: Any] {
            var out: [String: Any] = [:]
            let nonDeterministicKeys: Set<String> = [
                "generatedAt",
                "stableLegId",
                "tripImportedAtUtc",
                "actualsImportedAtUtc"
            ]
            for (key, value) in dict where !nonDeterministicKeys.contains(key) {
                out[key] = removeNonDeterministicKeys(from: value)
            }
            return out
        }
        if let array = object as? [Any] {
            return array.map(removeNonDeterministicKeys)
        }
        return object
    }

    private func sampleTripURL(_ name: String) -> URL {
        repositoryRootURL()
            .appendingPathComponent("sample_trip")
            .appendingPathComponent(name)
    }

    private func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
