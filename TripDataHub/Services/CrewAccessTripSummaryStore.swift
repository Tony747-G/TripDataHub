import Foundation

// MARK: - Output types

/// Trip-level summary derived from a CrewAccess import JSON file.
/// Read-only — INV-006: JSON files are never written or deleted by this store.
struct CrewAccessTripSummary {
    let tripId: String
    /// "{YYYY-MM-DD}_{tripId}" uppercase — iPad fileKey lookup format.
    let fileKey: String
    let creditTime: String?
    let tripDays: String?
    let tafb: String?
    /// Station → hotel name (IATA code, normalized uppercase).
    let hotelByStation: [String: String]
}

/// UTC leg times stored alongside each trip, keyed by "tripId|sequence".
struct CrewAccessLegUTCTimes {
    let startUtc: String
    let endUtc: String
}

// MARK: - Store

/// Read-only reader for CrewAccess import JSON summary data.
/// Provides both tripId-keyed (iOS) and fileKey-keyed (iPad) access from a single file pass.
enum CrewAccessTripSummaryStore {

    struct LoadResult {
        /// iOS lookup: tripId → summary (latest file wins when same tripId appears in multiple files).
        let byTripID: [String: CrewAccessTripSummary]
        /// iPad lookup: "{YYYY-MM-DD}_{tripId}" uppercase → summary.
        let byFileKey: [String: CrewAccessTripSummary]
        /// UTC times keyed by "tripId|sequence" for dayKey resolution.
        let legUTCTimesByKey: [String: CrewAccessLegUTCTimes]
    }

    nonisolated static func load() -> LoadResult {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return LoadResult(byTripID: [:], byFileKey: [:], legUTCTimesByKey: [:])
        }
        let dir = documents.appendingPathComponent("CrewAccessImports", isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else {
            return LoadResult(byTripID: [:], byFileKey: [:], legUTCTimesByKey: [:])
        }

        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return LoadResult(byTripID: [:], byFileKey: [:], legUTCTimesByKey: [:])
        }

        // Collect latest file per (tripId, fileKey) to handle re-imports.
        var latestByTripID: [String: (date: Date, url: URL, fileKey: String)] = [:]
        var latestByFileKey: [String: (date: Date, url: URL)] = [:]

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  url.pathExtension.lowercased() == "json"
            else { continue }

            let modifiedAt = values.contentModificationDate ?? .distantPast
            let fileKey = url.deletingPathExtension().lastPathComponent.uppercased()
            guard !fileKey.isEmpty else { continue }

            // Decode just enough to get the tripId for the iOS key.
            guard let data = try? Data(contentsOf: url),
                  let header = try? JSONDecoder().decode(TripIDHeader.self, from: data)
            else { continue }

            let tripId = header.tripId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tripId.isEmpty else { continue }

            if latestByTripID[tripId].map({ modifiedAt > $0.date }) ?? true {
                latestByTripID[tripId] = (modifiedAt, url, fileKey)
            }
            if latestByFileKey[fileKey].map({ modifiedAt > $0.date }) ?? true {
                latestByFileKey[fileKey] = (modifiedAt, url)
            }
        }

        // Build result dictionaries.
        var byTripID: [String: CrewAccessTripSummary] = [:]
        var byFileKey: [String: CrewAccessTripSummary] = [:]
        var legUTCTimesByKey: [String: CrewAccessLegUTCTimes] = [:]

        // Parse files referenced by tripId index (iOS path + UTC times).
        for (tripId, (_, url, fileKey)) in latestByTripID {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(TripSummaryJSON.self, from: data)
            else { continue }

            let summary = buildSummary(tripId: tripId, fileKey: fileKey, decoded: decoded)
            byTripID[tripId] = summary

            for item in decoded.items {
                let key = legUTCKey(
                    tripID: tripId,
                    sequence: item.sequence,
                    flight: item.flight,
                    depAirport: item.depAirport,
                    arrAirport: item.arrAirport
                )
                legUTCTimesByKey[key] = CrewAccessLegUTCTimes(startUtc: item.startUtc, endUtc: item.endUtc)
            }
        }

        // Parse files referenced by fileKey index (iPad path).
        for (fileKey, (_, url)) in latestByFileKey {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(TripSummaryJSON.self, from: data)
            else { continue }

            let tripId = decoded.tripId.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = buildSummary(tripId: tripId, fileKey: fileKey, decoded: decoded)
            byFileKey[fileKey] = summary
        }

        return LoadResult(byTripID: byTripID, byFileKey: byFileKey, legUTCTimesByKey: legUTCTimesByKey)
    }

    // MARK: - Private helpers

    private static func buildSummary(
        tripId: String,
        fileKey: String,
        decoded: TripSummaryJSON
    ) -> CrewAccessTripSummary {
        var hotelByStation: [String: String] = [:]

        for detail in decoded.hotelDetails {
            let (station, name) = parseHotelDetail(detail)
            let key = normalizedStation(station)
            if !key.isEmpty && !name.isEmpty {
                hotelByStation[key] = HotelNameNormalizer.displayName(
                    station: key,
                    parsedName: name
                )
            }
        }

        // Legacy "Hotel details …" fallback: assign hotels to layover stations by position.
        let legacyDetails = decoded.hotelDetails.filter { $0.hasPrefix("Hotel details ") }
        if !legacyDetails.isEmpty {
            var idx = 0
            let sortedItems = decoded.items.sorted { $0.sequence < $1.sequence }
            for i in sortedItems.indices.dropLast() {
                guard idx < legacyDetails.count else { break }
                let item = sortedItems[i]
                let next = sortedItems[i + 1]
                guard let endDate = LegConnectionTextBuilder.parseUTC(item.endUtc),
                      let nextStart = LegConnectionTextBuilder.parseUTC(next.startUtc),
                      nextStart.timeIntervalSince(endDate) >= 180 * 60
                else { continue }
                let stationKey = normalizedStation(item.arrAirport)
                guard !stationKey.isEmpty, hotelByStation[stationKey] == nil else {
                    idx += 1; continue
                }
                let (_, name) = parseHotelDetail(legacyDetails[idx])
                if !name.isEmpty {
                    hotelByStation[stationKey] = HotelNameNormalizer.displayName(
                        station: stationKey,
                        parsedName: name
                    )
                }
                idx += 1
            }
        }

        return CrewAccessTripSummary(
            tripId: tripId,
            fileKey: fileKey,
            creditTime: decoded.creditTime?.trimmingCharacters(in: .whitespacesAndNewlines),
            tripDays: decoded.tripDays?.trimmingCharacters(in: .whitespacesAndNewlines),
            tafb: decoded.tafb?.trimmingCharacters(in: .whitespacesAndNewlines),
            hotelByStation: hotelByStation
        )
    }

    /// Normalized station key used in `CrewAccessTripSummary.hotelByStation`.
    /// Both iOS and iPad lookup sites must use this to match the stored keys.
    static func stationKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func normalizedStation(_ raw: String) -> String {
        stationKey(raw)
    }

    static func legUTCKey(
        tripID: String,
        sequence: Int,
        flight: String,
        depAirport: String,
        arrAirport: String
    ) -> String {
        [
            tripID, String(sequence), flight, depAirport, arrAirport
        ]
        .map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        .joined(separator: "|")
    }

    /// Parses "SGN: Caravelle Hotel +84-28-3823-4999 (15:30)" → ("SGN", "Caravelle Hotel").
    private static func parseHotelDetail(_ detail: String) -> (station: String, hotelName: String) {
        if detail.hasPrefix("Hotel details ") {
            return parseLegacyHotelDetail(detail)
        }
        guard let colonRange = detail.range(of: ": ") else {
            return (detail.trimmingCharacters(in: .whitespaces), "")
        }
        let station = String(detail[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        var rest = String(detail[colonRange.upperBound...])
        if let parenRange = rest.range(of: " (", options: .backwards) {
            rest = String(rest[..<parenRange.lowerBound])
        }
        let words = rest.split(separator: " ").map(String.init)
        var hotelWords: [String] = []
        for word in words {
            let dashCount = word.filter { $0 == "-" }.count
            if word.hasPrefix("+") || dashCount >= 2 { break }
            hotelWords.append(word)
        }
        return (station, hotelWords.joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }

    private static func parseLegacyHotelDetail(_ detail: String) -> (station: String, hotelName: String) {
        guard let hotelRange = detail.range(of: "Hotel: ") else { return ("", "") }
        let afterHotel = String(detail[hotelRange.upperBound...])
        let hotelOnly: String
        if let transportRange = afterHotel.range(of: " Hotel Transport:") {
            hotelOnly = String(afterHotel[..<transportRange.lowerBound])
        } else {
            hotelOnly = afterHotel
        }
        let cleaned = hotelOnly
            .replacingOccurrences(of: " UPS Only", with: "")
            .replacingOccurrences(of: "UPS Only ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = cleaned.split(separator: " ").map(String.init)
        var hotelWords: [String] = []
        for word in words {
            let digitCount = word.filter(\.isNumber).count
            let dashCount = word.filter { $0 == "-" }.count
            if word.hasPrefix("+") || digitCount >= 3 || dashCount >= 2 { break }
            hotelWords.append(word)
        }
        return ("", hotelWords.joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }

    // MARK: - JSON models (private)

    private struct TripIDHeader: Decodable {
        let tripId: String
    }

    private struct TripSummaryJSON: Decodable {
        let tripId: String
        let creditTime: String?
        let tripDays: String?
        let tafb: String?
        let hotelDetails: [String]
        let items: [TripSummaryItemJSON]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tripId       = try c.decode(String.self, forKey: .tripId)
            creditTime   = try c.decodeIfPresent(String.self, forKey: .creditTime)
            tripDays     = try c.decodeIfPresent(String.self, forKey: .tripDays)
            tafb         = try c.decodeIfPresent(String.self, forKey: .tafb)
            hotelDetails = (try? c.decodeIfPresent([String].self, forKey: .hotelDetails)) ?? []
            items        = (try? c.decodeIfPresent([TripSummaryItemJSON].self, forKey: .items)) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case tripId, creditTime, tripDays, tafb, hotelDetails, items
        }
    }

    private struct TripSummaryItemJSON: Decodable {
        let sequence: Int
        let flight: String
        let depAirport: String
        let arrAirport: String
        let startUtc: String
        let endUtc: String
    }
}
