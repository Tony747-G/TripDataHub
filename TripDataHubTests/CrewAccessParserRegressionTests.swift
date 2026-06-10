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

            XCTAssertEqual(payload.schemaVersion, 1)
            XCTAssertFalse(payload.tripId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(payload.items.isEmpty, "\(testCase.pdf) should contain legs")

            for item in payload.items {
                XCTAssertEqual(item.depAirport.count, 3, "\(testCase.pdf) dep IATA")
                XCTAssertEqual(item.arrAirport.count, 3, "\(testCase.pdf) arr IATA")
                XCTAssertNotNil(utcFormatter.date(from: item.startUtc), "\(testCase.pdf) startUtc parse")
                XCTAssertNotNil(utcFormatter.date(from: item.endUtc), "\(testCase.pdf) endUtc parse")
                XCTAssertNotNil(item.stdUtc.flatMap { utcFormatter.date(from: $0) }, "\(testCase.pdf) stdUtc parse")
                XCTAssertNotNil(item.staUtc.flatMap { utcFormatter.date(from: $0) }, "\(testCase.pdf) staUtc parse")
                XCTAssertFalse(item.flight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
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
        XCTAssertEqual(payload.items.map(\.flight), ["XX001", "XX002", "XX003"])
        XCTAssertEqual(payload.items.map(\.depAirport), ["ANC", "CVG", "HND"])
        XCTAssertEqual(payload.items.map(\.arrAirport), ["CVG", "HND", "ANC"])
        XCTAssertEqual(payload.items.map(\.deadhead), [false, false, true])
        XCTAssertTrue(payload.hotelDetails.contains { $0.contains("Holiday Inn") })
        XCTAssertTrue(payload.hotelDetails.contains { $0.contains("Tokyu Haneda") })
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
        return removeGeneratedAt(from: object)
    }

    private func removeGeneratedAt(from object: Any) -> Any {
        if let dict = object as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in dict where key != "generatedAt" {
                out[key] = removeGeneratedAt(from: value)
            }
            return out
        }
        if let array = object as? [Any] {
            return array.map(removeGeneratedAt)
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
