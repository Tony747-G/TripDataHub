import Foundation

protocol TripBoardSyncServiceProtocol {
    func sync(cookies: [HTTPCookie]) async throws -> [PayPeriodSchedule]
}

enum SyncServiceError: Error, LocalizedError {
    case notAuthenticated
    case requestFailed(statusCode: Int)
    case invalidResponse
    case invalidConfiguration
    case decodingFailed
    case noPayPeriods
    case timeout
    case network(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Login required before sync."
        case let .requestFailed(statusCode):
            return "TripBoard request failed (\(statusCode))."
        case .invalidResponse:
            return "Invalid response from TripBoard."
        case .invalidConfiguration:
            return "TripBoard URL configuration is invalid."
        case .decodingFailed:
            return "Failed to decode TripBoard data."
        case .noPayPeriods:
            return "No pay periods found."
        case .timeout:
            return "TripBoard request timed out."
        case let .network(code, message):
            return "Network error (\(code)): \(message)"
        }
    }
}

final class TripBoardSyncService: TripBoardSyncServiceProtocol {
    private let homeURL: URL?
    private let loadURL: URL?
    private let tzResolver: IATATimeZoneResolving

    init(tzResolver: IATATimeZoneResolving = IATATimeZoneResolver.shared) {
        self.homeURL = URL(string: "https://tripboard.bidproplus.com/")
        self.loadURL = URL(string: "https://tripboard.bidproplus.com/api/1.0/TripBoard/Load")
        self.tzResolver = tzResolver
    }

    func sync(cookies: [HTTPCookie]) async throws -> [PayPeriodSchedule] {
        guard let homeURL, let loadURL else {
            throw SyncServiceError.invalidConfiguration
        }
        let bidProCookies = cookies.filter { $0.domain.lowercased().contains("bidproplus.com") }
        guard !bidProCookies.isEmpty else {
            throw SyncServiceError.notAuthenticated
        }

        let session = makeSession()
        let cookieHeader = makeCookieHeader(from: bidProCookies)

        // Warm-up request often refreshes session state after WebView login.
        var warmup = URLRequest(url: homeURL)
        warmup.httpMethod = "GET"
        warmup.timeoutInterval = 20
        warmup.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        warmup.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        warmup.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        _ = try? await session.data(for: warmup)

        var request = URLRequest(url: loadURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://tripboard.bidproplus.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await requestWithRetry(session: session, request: request, retries: 1)

        guard let http = response as? HTTPURLResponse else {
            throw SyncServiceError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SyncServiceError.notAuthenticated
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw SyncServiceError.requestFailed(statusCode: http.statusCode)
        }

        let payload: TripBoardLoadResponse
        do {
            payload = try JSONDecoder().decode(TripBoardLoadResponse.self, from: data)
        } catch {
            throw SyncServiceError.decodingFailed
        }

        let payPeriods = payload.payPeriods
            .sorted { $0.startsOn < $1.startsOn }
            .map { mapPayPeriod($0) }

        guard !payPeriods.isEmpty else {
            throw SyncServiceError.noPayPeriods
        }

        return payPeriods
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    private func makeCookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private func requestWithRetry(
        session: URLSession,
        request: URLRequest,
        retries: Int
    ) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0 ... retries {
            do {
                return try await session.data(for: request)
            } catch {
                lastError = error
                if attempt < retries {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
            }
        }

        let nsError = (lastError ?? URLError(.unknown)) as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            throw SyncServiceError.timeout
        }
        throw SyncServiceError.network(code: nsError.code, message: nsError.localizedDescription)
    }

    private func mapPayPeriod(_ payPeriod: TripBoardPayPeriod) -> PayPeriodSchedule {
        let label = payPeriodLabel(from: payPeriod.payPeriodId)
        let scheduleTrips = payPeriod.scheduledTrips
        let legs = scheduleTrips.flatMap { mapTripLegs(trip: $0, payPeriodLabel: label) }
        let openTimeTrips = payPeriod.trips.map { mapOpenTimeTrip(trip: $0, payPeriodLabel: label) }
            .sorted { $0.startLocal < $1.startLocal }

        return PayPeriodSchedule(
            id: label,
            label: label,
            tripCount: scheduleTrips.count,
            legCount: legs.count,
            openTimeCount: openTimeTrips.count,
            updatedAt: Date(),
            legs: legs,
            openTimeTrips: openTimeTrips
        )
    }

    private func mapTripLegs(trip: TripBoardTrip, payPeriodLabel: String) -> [TripLeg] {
        let allLegs = (trip.tripDetails?.tripDuties ?? []).flatMap(\.tripLegs)
        guard !allLegs.isEmpty else { return [] }

        let tripStartUTC = parseISODate(trip.startsOn)
        let tripEndUTC = parseISODate(trip.endsOn)

        return allLegs.enumerated().map { index, leg in
            let depBaseUTC = parseISODate(leg.startsOn) ?? tripStartUTC ?? Date()
            let nextDepUTC = index + 1 < allLegs.count
                ? (parseISODate(allLegs[index + 1].startsOn) ?? depBaseUTC)
                : (tripEndUTC ?? depBaseUTC)

            let depToken = parseClockToken(leg.startTime ?? "")
            let arrToken = parseClockToken(leg.endTime ?? "")
            let rawStatus = (leg.status ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedStatus = rawStatus.isEmpty ? "-" : rawStatus

            // TripBoard leg.startsOn is treated as UTC baseline.
            let depUTC = depBaseUTC

            let blockMinutes = parseBlockMinutes(leg.block)
            // Do not treat 0:00 as a reliable arrival source.
            // It is frequently used in DH/CML records and can hide valid inferred arrival.
            let arrUTCFromBlock = blockMinutes.flatMap { minutes -> Date? in
                guard minutes > 0 else { return nil }
                return depUTC.addingTimeInterval(TimeInterval(minutes * 60))
            }
            let arrUTCInferred = inferUTCFromToken(
                baseUTC: depUTC,
                token: arrToken,
                minUTC: depUTC.addingTimeInterval(-3600),
                maxUTC: nextDepUTC.addingTimeInterval(72 * 3600)
            )
            let arrUTC = arrUTCFromBlock ?? arrUTCInferred

            let depLocal = localDateFromUTC(depUTC, airportCode: leg.origin) ?? depToken.flatMap { token -> Date? in
                let utcMinusLocal = normalizeOffset(zHour: token.zHour, localHour: token.localHour)
                return depUTC.addingTimeInterval(TimeInterval(-utcMinusLocal * 3600))
            }

            let arrLocal = arrUTC.flatMap { utc in
                localDateFromUTC(utc, airportCode: leg.destination)
            } ?? arrToken.flatMap { token -> Date? in
                guard let arrUTC else { return nil }
                let utcMinusLocal = normalizeOffset(zHour: token.zHour, localHour: token.localHour)
                return arrUTC.addingTimeInterval(TimeInterval(-utcMinusLocal * 3600))
            }

            let block = calculateBlock(depUTC: depUTC, arrUTC: arrUTC) ?? (leg.block ?? "")

            return TripLeg(
                payPeriod: payPeriodLabel,
                pairing: trip.pairingNumber,
                leg: index + 1,
                flight: leg.flightNumber ?? "",
                depAirport: leg.origin ?? "",
                depLocal: depLocal.map { formatDate($0, timeZone: localTimeZone(for: leg.origin)) } ?? "",
                arrAirport: leg.destination ?? "",
                arrLocal: arrLocal.map { formatDate($0, timeZone: localTimeZone(for: leg.destination)) } ?? "",
                depUTC: formatUTC(depUTC),
                arrUTC: arrUTC.map { formatUTC($0) },
                status: normalizedStatus,
                block: block
            )
        }
    }

    private func mapOpenTimeTrip(trip: TripBoardTrip, payPeriodLabel: String) -> OpenTimeTrip {
        let status = (trip.statusText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let legs = mapTripLegs(trip: trip, payPeriodLabel: payPeriodLabel)
        let bounds = openTimeTripBounds(from: legs)
        return OpenTimeTrip(
            payPeriod: payPeriodLabel,
            pairing: trip.pairingNumber,
            startLocal: bounds?.startLocal ?? formatTripDate(trip.startsOn),
            endLocal: bounds?.endLocal ?? formatTripDate(trip.endsOn),
            route: sanitizeRoute(trip.plainSubTitle ?? trip.subTitle ?? ""),
            credit: trip.credit ?? "",
            requestType: trip.requestType ?? "",
            status: status.isEmpty ? "-" : status,
            legs: legs
        )
    }

    private func openTimeTripBounds(from legs: [TripLeg]) -> (startLocal: String, endLocal: String)? {
        let sorted = legs
            .filter { !$0.depLocal.isEmpty && !$0.arrLocal.isEmpty }
            .sorted { lhs, rhs in
                if lhs.depLocal == rhs.depLocal {
                    return lhs.leg < rhs.leg
                }
                return lhs.depLocal < rhs.depLocal
            }

        guard let first = sorted.first, let last = sorted.last else { return nil }
        return (startLocal: first.depLocal, endLocal: last.arrLocal)
    }

    private func payPeriodLabel(from payPeriodId: Int) -> String {
        let raw = String(payPeriodId)
        guard raw.count >= 4 else {
            return "PP00-\(raw)"
        }
        let first = raw.prefix(2)
        let last = raw.suffix(2)
        return "PP\(first)-\(last)"
    }

    private func parseISODate(_ text: String) -> Date? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) {
            return date
        }

        // .NET JSON date style: /Date(1708012800000)/
        if let dotNetRange = raw.range(of: #"^/Date\(([-]?\d+)\)/$"#, options: .regularExpression) {
            let value = String(raw[dotNetRange]).replacingOccurrences(of: "/Date(", with: "").replacingOccurrences(of: ")/", with: "")
            if let milliseconds = Double(value) {
                return Date(timeIntervalSince1970: milliseconds / 1000.0)
            }
        }

        // Unix timestamp seconds/milliseconds as plain number.
        if raw.allSatisfy({ $0.isNumber }) {
            if let number = Double(raw) {
                if raw.count >= 13 {
                    return Date(timeIntervalSince1970: number / 1000.0)
                }
                return Date(timeIntervalSince1970: number)
            }
        }

        // Common non-ISO forms observed in roster data (no timezone suffix).
        let fallbackFormatter = DateFormatter()
        fallbackFormatter.calendar = Calendar(identifier: .gregorian)
        fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
        fallbackFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm"
        ]
        for format in formats {
            fallbackFormatter.dateFormat = format
            if let date = fallbackFormatter.date(from: raw) {
                return date
            }
        }

        return nil
    }

    private func formatDate(_ date: Date, timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func formatUTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func formatTripDate(_ raw: String) -> String {
        if let date = parseISODate(raw) {
            return formatDate(date, timeZone: .current)
        }
        return String(raw.replacingOccurrences(of: "T", with: " ").prefix(16))
    }

    private func formatLocalDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func parseBlockMinutes(_ block: String?) -> Int? {
        guard let block else { return nil }
        let cleaned = block.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.split(separator: ":")
        guard parts.count == 2, let hh = Int(parts[0]), let mm = Int(parts[1]) else { return nil }
        guard hh >= 0, mm >= 0, mm < 60 else { return nil }
        return hh * 60 + mm
    }

    private func localTimeZone(for airportCode: String?) -> TimeZone {
        guard let airportCode else { return .current }
        let code = airportCode.uppercased()
        if let zoneID = tzResolver.resolve(code), let zone = TimeZone(identifier: zoneID) {
            return zone
        }
        return .current
    }

    private func localDateFromUTC(_ utc: Date, airportCode: String?) -> Date? {
        let zone = localTimeZone(for: airportCode)
        let localString = formatDate(utc, timeZone: zone)
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = zone
        parser.dateFormat = "yyyy-MM-dd HH:mm"
        return parser.date(from: localString)
    }

    private func sanitizeRoute(_ route: String) -> String {
        route
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ClockToken {
        let localHour: Int
        let zHour: Int
        let minute: Int
    }

    private func parseClockToken(_ value: String) -> ClockToken? {
        // Examples: (WE08)17:27, (18)23:32
        let pattern = #"^\((?:[A-Z]{2}(\d{2})|(\d{2}))\)(\d{2}):(\d{2})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return nil }

        func intAt(_ idx: Int) -> Int? {
            let ns = match.range(at: idx)
            guard ns.location != NSNotFound, let r = Range(ns, in: value) else { return nil }
            return Int(value[r])
        }

        guard
            let localHour = intAt(1) ?? intAt(2),
            let zHour = intAt(3),
            let minute = intAt(4)
        else {
            return nil
        }

        return ClockToken(localHour: localHour, zHour: zHour, minute: minute)
    }

    private func normalizeOffset(zHour: Int, localHour: Int) -> Int {
        var offset = zHour - localHour
        while offset > 14 { offset -= 24 }
        while offset < -12 { offset += 24 }
        return offset
    }

    private func inferUTCFromToken(baseUTC: Date, token: ClockToken?, minUTC: Date?, maxUTC: Date?) -> Date? {
        guard let token else { return nil }

        // Build candidate UTC datetimes around the reference duty day and pick
        // the first valid candidate not earlier than baseUTC.
        var candidates: [Date] = []
        let calendar = Calendar(identifier: .gregorian)
        for dayOffset in -1 ... 4 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: baseUTC) else { continue }
            var comps = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: day)
            comps.hour = token.zHour
            comps.minute = token.minute
            comps.second = 0
            comps.nanosecond = 0
            guard let candidate = calendar.date(from: comps) else { continue }

            if let minUTC, candidate < minUTC { continue }
            if let maxUTC, candidate > maxUTC { continue }
            candidates.append(candidate)
        }

        guard !candidates.isEmpty else { return nil }

        let after = candidates.filter { $0 >= baseUTC }.sorted()
        if let first = after.first { return first }

        return candidates.min { abs($0.timeIntervalSince(baseUTC)) < abs($1.timeIntervalSince(baseUTC)) }
    }

    private func calculateBlock(depUTC: Date, arrUTC: Date?) -> String? {
        guard let arrUTC else { return nil }
        var delta = arrUTC.timeIntervalSince(depUTC)
        while delta < 0 {
            delta += 24 * 3600
        }
        let minutes = Int(round(delta / 60))
        guard minutes <= 24 * 60 else { return nil }
        let hh = minutes / 60
        let mm = minutes % 60
        return "\(hh):\(String(format: "%02d", mm))"
    }
}

private struct TripBoardLoadResponse: Decodable {
    let payPeriods: [TripBoardPayPeriod]
}

private struct TripBoardPayPeriod: Decodable {
    let payPeriodId: Int
    let startsOn: String
    let scheduledTrips: [TripBoardTrip]
    let trips: [TripBoardTrip]
}

private struct TripBoardTrip: Decodable {
    let pairingNumber: String
    let startsOn: String
    let endsOn: String
    let plainSubTitle: String?
    let subTitle: String?
    let credit: String?
    let requestType: String?
    let statusText: String?
    let tripDetails: TripBoardTripDetails?
}

private struct TripBoardTripDetails: Decodable {
    let tripDuties: [TripBoardTripDuty]
}

private struct TripBoardTripDuty: Decodable {
    let tripLegs: [TripBoardLeg]
}

private struct TripBoardLeg: Decodable {
    let startsOn: String
    let flightNumber: String?
    let origin: String?
    let startTime: String?
    let destination: String?
    let endTime: String?
    let status: String?
    let block: String?
}
