import Foundation

struct BidPeriodScheduleExport: Codable, Equatable, Sendable {
    let schemaVersion: String
    let exportType: String
    let exportedAt: String
    let generator: ExportGenerator
    let owner: BidPeriodExportOwner
    let bidPeriod: ExportBidPeriod
    let trips: [BidPeriodExportTrip]
    let calendarEvents: [BidPeriodExportCalendarEvent]
    let diagnostics: ExportDiagnostics
}

struct ExportBidPeriod: Codable, Equatable, Sendable {
    let identifier: String
    let start: String
    let end: String
    let domicile: String
    let timeZone: String
    let boundaryLocalTime: String
    let payPeriods: [ExportPayPeriod]
}

struct ExportPayPeriod: Codable, Equatable, Sendable {
    let identifier: String?
    let ordinal: Int
    let start: String
    let end: String
}

struct BidPeriodExportOwner: Codable, Equatable, Sendable {
    let name: String?
    let gems: String?
    let domicile: String
    let timeZone: String
    let fleet: String?
    let position: String?
    let line: ExportOwnerLine?
}

struct ExportOwnerLine: Codable, Equatable, Sendable {
    let equipment: String?
    let seat: String?
    let seniorityNumber: String?
    let dateOfHire: String?
}

struct BidPeriodExportOwnerInput: Equatable, Sendable {
    let profileName: String
    let profileGEMS: String
    let profileFleet: String
    let profilePosition: String
    let verifiedName: String
    let verifiedGEMS: String
    let verifiedEquipment: String
    let verifiedSeat: String
    let verifiedDateOfHire: String
    let seniorityNumber: String
}

enum ExportTripBPRelationship: String, Codable, Equatable, Sendable {
    case assigned
    case overlappingFromPrevious
    case assignmentUnavailable
}

enum ExportTripSource: String, Codable, Equatable, Sendable {
    case crewAccessRich
    case displayedScheduleFallback
}

struct BidPeriodExportTrip: Codable, Equatable, Sendable {
    let id: String
    let tripNumber: String
    let title: String
    let start: ExportTimestamp
    let end: ExportTimestamp
    let assignedBidPeriodIdentifier: String?
    let relationshipToSelectedBidPeriod: ExportTripBPRelationship
    let source: ExportTripSource
    let summary: ExportTripSummary?
    let events: [ExportEvent]
    let diagnostics: ExportTripDiagnostics
}

struct ExportDurationSummary: Codable, Equatable, Sendable {
    let minutes: Int
    let display: String
}

struct ExportTripDaysSummary: Codable, Equatable, Sendable {
    let days: Int
    let display: String
}

struct ExportTripSummary: Codable, Equatable, Sendable {
    let dutyTime: ExportDurationSummary?
    let blockTime: ExportDurationSummary?
    let creditTime: ExportDurationSummary?
    let tafb: ExportDurationSummary?
    let tripDays: ExportTripDaysSummary?
}

enum ExportCalendarEventCategory: String, Codable, Equatable, Sendable {
    case operational
    case bid
    case financial
    case personal
}

enum ExportCalendarEventSource: String, Codable, Equatable, Sendable {
    case userCreated
    case calendarRule
    case profileDate
}

enum ExportCalendarEventTimeSemantics: String, Codable, Equatable, Sendable {
    case timed
    case allDay
}

struct ExportCalendarEventTiming: Codable, Equatable, Sendable {
    let semantics: ExportCalendarEventTimeSemantics
    let start: ExportTimestamp?
    let end: ExportTimestamp?
    let localStartDate: String?
    let localEndDateExclusive: String?
    let timeZone: String
    let timeZoneSource: String
}

struct BidPeriodExportCalendarEvent: Codable, Equatable, Sendable {
    let id: String
    let category: ExportCalendarEventCategory
    let kind: String
    let title: String
    let timing: ExportCalendarEventTiming
    let notes: String?
    let source: ExportCalendarEventSource
}

enum ExportDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case warning
    case error
}

struct ExportDiagnosticIssue: Codable, Equatable, Sendable {
    let severity: ExportDiagnosticSeverity
    let code: String
    let scope: String
    let subjectID: String?
    let fieldGroup: String?
    let message: String
}

struct ExportDiagnostics: Codable, Equatable, Sendable {
    let partial: Bool
    let issues: [ExportDiagnosticIssue]
}

struct ExportTripDiagnostics: Codable, Equatable, Sendable {
    let richPayloadAvailable: Bool
    let unavailableFieldGroups: [String]
    let issues: [ExportDiagnosticIssue]
}

struct BidPeriodScheduleExportInput {
    let bidPeriod: CalendarBidPeriod
    let domicile: String
    let owner: BidPeriodExportOwnerInput
    let schedules: [PayPeriodSchedule]
    let crewAccessPayloads: [CrewAccessTripJSON]
    let manualOperationalEvents: [ManualOperationalEvent]
    let manualPersonalEvents: [ManualPersonalEvent]
    let pilotQualification: PilotQualification
    let faaMedicalExpiryDate: String?
    let passportExpiryDate: String?
    let chinaVisaExpiryDate: String?
    let generator: ExportGenerator
    let exportedAt: Date
}

enum BidPeriodScheduleExportError: LocalizedError, Equatable {
    case selectedTripUnavailable
    case selectedTripDepartureUnavailable
    case assignedBidPeriodUnavailable
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .selectedTripUnavailable:
            return "The selected trip could not be resolved."
        case .selectedTripDepartureUnavailable:
            return "This trip has no valid UTC departure time, so its Bid Period cannot be determined."
        case .assignedBidPeriodUnavailable:
            return "TripDataHub could not resolve a Bid Period for this trip’s departure."
        case .invalidUTF8:
            return "The generated Bid Period JSON could not be represented as UTF-8."
        }
    }
}

enum BidPeriodScheduleExportService {
    static let schemaVersion = "1.0"
    static let exportType = "bidPeriodSchedule"
    static let boundaryLocalTime = "03:00"

    static func makeExport(input: BidPeriodScheduleExportInput) -> BidPeriodScheduleExport {
        let domicile = DomicileSupport.normalize(input.domicile)
        let timeZone = DomicileSupport.timeZone(for: domicile)
        let exportedPayPeriods = payPeriods(in: input.bidPeriod, domicile: domicile)
            .sorted { $0.ordinal < $1.ordinal }
            .map {
                ExportPayPeriod(
                    identifier: $0.identifier,
                    ordinal: $0.ordinal,
                    start: TripJSONExportService.utcString($0.startDateUTC),
                    end: TripJSONExportService.utcString($0.endDateUTC)
                )
            }
        let bidPeriod = ExportBidPeriod(
            identifier: input.bidPeriod.id,
            start: TripJSONExportService.utcString(input.bidPeriod.startDateUTC),
            end: TripJSONExportService.utcString(input.bidPeriod.endDateUTC),
            domicile: domicile,
            timeZone: timeZone.identifier,
            boundaryLocalTime: boundaryLocalTime,
            payPeriods: exportedPayPeriods
        )

        var rootIssues: [ExportDiagnosticIssue] = []
        let owner = exportOwner(
            from: input.owner,
            domicile: domicile,
            timeZone: timeZone,
            issues: &rootIssues
        )

        let calendarTrips = visibleTrips(
            in: input.bidPeriod,
            trips: normalizeCalendarTrips(from: input.schedules)
        )
        let trips = calendarTrips.map { trip in
            exportTrip(
                trip,
                selectedBidPeriod: input.bidPeriod,
                domicile: domicile,
                payloads: input.crewAccessPayloads,
                rootIssues: &rootIssues
            )
        }.sorted(by: tripSort)

        let calendarEvents = exportCalendarEvents(
            input: input,
            timeZone: timeZone
        )

        let sortedIssues = rootIssues.sorted(by: diagnosticSort)
        return BidPeriodScheduleExport(
            schemaVersion: schemaVersion,
            exportType: exportType,
            exportedAt: TripJSONExportService.utcString(input.exportedAt),
            generator: input.generator,
            owner: owner,
            bidPeriod: bidPeriod,
            trips: trips,
            calendarEvents: calendarEvents,
            diagnostics: ExportDiagnostics(partial: !sortedIssues.isEmpty, issues: sortedIssues)
        )
    }

    static func encodedData(for export: BidPeriodScheduleExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(export)
        guard String(data: data, encoding: .utf8) != nil else {
            throw BidPeriodScheduleExportError.invalidUTF8
        }
        return data
    }

    static func filename(for export: BidPeriodScheduleExport) -> String {
        "\(export.bidPeriod.identifier).json"
    }

    static func makeTemporaryFile(
        input: BidPeriodScheduleExportInput,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> TripJSONExportOutput {
        let export = makeExport(input: input)
        let data = try encodedData(for: export)
        let directory = temporaryRoot
            .appendingPathComponent("TDHBPExport_\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent(filename(for: export), isDirectory: false)
            try data.write(to: fileURL, options: .atomic)
            return TripJSONExportOutput(url: fileURL, temporaryDirectory: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private static func exportOwner(
        from input: BidPeriodExportOwnerInput,
        domicile: String,
        timeZone: TimeZone,
        issues: inout [ExportDiagnosticIssue]
    ) -> BidPeriodExportOwner {
        let name = firstMeaningful(input.profileName, input.verifiedName)
        let rawGEMS = firstMeaningful(input.profileGEMS, input.verifiedGEMS)
        let gems = rawGEMS.flatMap { try? TripJSONExportService.normalizedGEMS($0) }
        let fleet = firstMeaningful(input.profileFleet, input.verifiedEquipment)
        let position = TripJSONExportService.normalizedPosition(
            firstMeaningful(input.profilePosition, input.verifiedSeat)
        )
        let equipment = firstMeaningful(input.verifiedEquipment, input.profileFleet)
        let seat = TripJSONExportService.normalizedPosition(
            firstMeaningful(input.verifiedSeat, input.profilePosition)
        )
        let seniorityNumber = firstMeaningful(input.seniorityNumber)
        let dateOfHire = firstMeaningful(input.verifiedDateOfHire)

        appendOwnerIssueIfMissing(name, field: "name", issues: &issues)
        appendOwnerIssueIfMissing(gems, field: "gems", issues: &issues)
        appendOwnerIssueIfMissing(fleet, field: "fleet", issues: &issues)
        appendOwnerIssueIfMissing(position, field: "position", issues: &issues)
        appendOwnerIssueIfMissing(seniorityNumber, field: "seniorityNumber", issues: &issues)
        appendOwnerIssueIfMissing(dateOfHire, field: "dateOfHire", issues: &issues)

        let line: ExportOwnerLine? = [equipment, seat, seniorityNumber, dateOfHire]
            .contains(where: { $0 != nil })
            ? ExportOwnerLine(
                equipment: equipment,
                seat: seat,
                seniorityNumber: seniorityNumber,
                dateOfHire: dateOfHire
            )
            : nil

        return BidPeriodExportOwner(
            name: name?.uppercased(),
            gems: gems,
            domicile: domicile,
            timeZone: timeZone.identifier,
            fleet: fleet?.uppercased(),
            position: position,
            line: line
        )
    }

    private static func appendOwnerIssueIfMissing(
        _ value: String?,
        field: String,
        issues: inout [ExportDiagnosticIssue]
    ) {
        guard value == nil else { return }
        issues.append(ExportDiagnosticIssue(
            severity: .warning,
            code: "ownerFieldUnavailable",
            scope: "owner",
            subjectID: nil,
            fieldGroup: field,
            message: "The owner’s \(field) value was unavailable."
        ))
    }

    private static func exportTrip(
        _ trip: CalendarTrip,
        selectedBidPeriod: CalendarBidPeriod,
        domicile: String,
        payloads: [CrewAccessTripJSON],
        rootIssues: inout [ExportDiagnosticIssue]
    ) -> BidPeriodExportTrip {
        let sortedLegs = trip.legs.sorted(by: legSort)
        let firstDeparture = sortedLegs.compactMap { TripJSONExportService.parseInstant($0.depUTC ?? "") }.min()
        let assignedBidPeriod = firstDeparture.flatMap { bidPeriod(for: $0, domicile: domicile) }
        let tripID = stableTripID(pairing: trip.pairing, startUTC: trip.startUTC)
        let schedule = PayPeriodSchedule(
            id: trip.id,
            label: trip.payPeriod,
            tripCount: 1,
            legCount: sortedLegs.count,
            openTimeCount: 0,
            updatedAt: .distantPast,
            legs: sortedLegs,
            openTimeTrips: []
        )

        var tripIssues: [ExportDiagnosticIssue] = []
        let payload = TripJSONExportService.payload(for: schedule, candidates: payloads)
        let events: [ExportEvent]
        let source: ExportTripSource
        let summary: ExportTripSummary?
        var unavailableFieldGroups: [String] = []

        if let payload {
            do {
                let richEvents = try TripJSONExportService.publicEvents(
                    payload: payload,
                    schedule: schedule,
                    tripID: tripID
                )
                let summaryResult = exportTripSummary(from: payload)
                if richEvents.isEmpty,
                   !payload.items.isEmpty,
                   payload.items.allSatisfy({
                       $0.flight.caseInsensitiveCompare("GND") == .orderedSame
                   }) {
                    events = []
                    source = .crewAccessRich
                    summary = summaryResult.summary
                    unavailableFieldGroups.append(contentsOf: summaryResult.unavailableFieldGroups)
                    unavailableFieldGroups.append("groundTransport")
                    tripIssues.append(issue(
                        code: "publicEventTypesDeferred",
                        subjectID: tripID,
                        fieldGroup: "groundTransport",
                        message: "The stored trip contains only Ground Transport rows, which are deferred from the public schema."
                    ))
                } else {
                    guard !richEvents.isEmpty else {
                        throw TripJSONExportError.tripDataUnavailable
                    }
                    events = richEvents
                    source = .crewAccessRich
                    summary = summaryResult.summary
                    unavailableFieldGroups.append(contentsOf: summaryResult.unavailableFieldGroups)
                }
            } catch {
                source = .displayedScheduleFallback
                summary = nil
                events = fallbackEvents(for: sortedLegs, tripID: tripID, issues: &tripIssues)
                unavailableFieldGroups = richPayloadUnavailableGroups
                tripIssues.append(issue(
                    code: "richCrewAccessPayloadInvalid",
                    subjectID: tripID,
                    fieldGroup: "crewAccessPayload",
                    message: "Stored CrewAccess data could not be mapped; displayed schedule data was exported instead."
                ))
            }
        } else {
            source = .displayedScheduleFallback
            summary = nil
            events = fallbackEvents(for: sortedLegs, tripID: tripID, issues: &tripIssues)
            unavailableFieldGroups = richPayloadUnavailableGroups
            tripIssues.append(issue(
                code: "richCrewAccessPayloadUnavailable",
                subjectID: tripID,
                fieldGroup: "crewAccessPayload",
                message: "Stored CrewAccess data was unavailable; displayed schedule data was exported instead."
            ))
        }

        let startTimeZone = sortedLegs.first.flatMap { resolvedTimeZoneID(for: $0.depAirport) }
        let endTimeZone = sortedLegs.last.flatMap { resolvedTimeZoneID(for: $0.arrAirport) }
        let start = (try? TripJSONExportService.exportTimestamp(
            TripJSONExportService.utcString(trip.startUTC),
            timeZoneID: startTimeZone
        )) ?? utcTimestamp(trip.startUTC)
        let end = (try? TripJSONExportService.exportTimestamp(
            TripJSONExportService.utcString(trip.endUTC),
            timeZoneID: endTimeZone
        )) ?? utcTimestamp(trip.endUTC)

        let relationship: ExportTripBPRelationship
        if assignedBidPeriod?.id == selectedBidPeriod.id {
            relationship = .assigned
        } else if assignedBidPeriod != nil {
            relationship = .overlappingFromPrevious
        } else {
            relationship = .assignmentUnavailable
            tripIssues.append(issue(
                code: "assignedBidPeriodUnavailable",
                subjectID: tripID,
                fieldGroup: "assignedBidPeriodIdentifier",
                message: "The trip’s assigned Bid Period could not be resolved from its first valid UTC departure."
            ))
        }

        let sortedTripIssues = tripIssues.sorted(by: diagnosticSort)
        rootIssues.append(contentsOf: sortedTripIssues)
        return BidPeriodExportTrip(
            id: tripID,
            tripNumber: trip.pairing,
            title: trip.pairing,
            start: start,
            end: end,
            assignedBidPeriodIdentifier: assignedBidPeriod?.id,
            relationshipToSelectedBidPeriod: relationship,
            source: source,
            summary: summary,
            events: events.sorted(by: eventSort),
            diagnostics: ExportTripDiagnostics(
                richPayloadAvailable: source == .crewAccessRich,
                unavailableFieldGroups: unavailableFieldGroups.sorted(),
                issues: sortedTripIssues
            )
        )
    }

    private static let richPayloadUnavailableGroups = [
        "aircraft",
        "crewAccessPayload",
        "groundTransport",
        "hotelPhone",
        "richLayoverMetadata",
        "summary.blockTime",
        "summary.creditTime",
        "summary.dutyTime",
        "summary.tafb",
        "summary.tripDays",
        "tailNumber",
        "timeZoneMetadata"
    ]

    private static let summaryFieldGroups = [
        "summary.dutyTime",
        "summary.blockTime",
        "summary.creditTime",
        "summary.tafb",
        "summary.tripDays"
    ]

    private static func exportTripSummary(
        from payload: CrewAccessTripJSON
    ) -> (summary: ExportTripSummary?, unavailableFieldGroups: [String]) {
        let dutyTime = aggregateDutyTotal(named: "Time", in: payload.dutyTotals)
        let blockTime = aggregateDutyTotal(named: "Block", in: payload.dutyTotals)
        let creditTime = durationSummary(from: payload.creditTime)
        let tafb = durationSummary(from: payload.tafb)
        let tripDays = tripDaysSummary(from: payload.tripDays)

        let valuesPresent = [
            dutyTime != nil,
            blockTime != nil,
            creditTime != nil,
            tafb != nil,
            tripDays != nil
        ]
        let unavailable = zip(summaryFieldGroups, valuesPresent)
            .compactMap { field, present in present ? nil : field }
        guard valuesPresent.contains(true) else {
            return (nil, unavailable)
        }

        return (
            ExportTripSummary(
                dutyTime: dutyTime,
                blockTime: blockTime,
                creditTime: creditTime,
                tafb: tafb,
                tripDays: tripDays
            ),
            unavailable
        )
    }

    private static func aggregateDutyTotal(
        named field: String,
        in dutyTotals: [String]
    ) -> ExportDurationSummary? {
        guard !dutyTotals.isEmpty else { return nil }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: field)):\\s*([0-9]{1,3}:[0-5][0-9])\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        var totalMinutes = 0
        for line in dutyTotals {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let valueRange = Range(match.range(at: 1), in: line),
                  let minutes = durationMinutes(from: String(line[valueRange]))
            else {
                return nil
            }
            totalMinutes += minutes
        }
        return ExportDurationSummary(
            minutes: totalMinutes,
            display: durationDisplay(totalMinutes)
        )
    }

    private static func durationSummary(from raw: String?) -> ExportDurationSummary? {
        guard let minutes = durationMinutes(from: raw) else { return nil }
        return ExportDurationSummary(minutes: minutes, display: durationDisplay(minutes))
    }

    private static func durationMinutes(from raw: String?) -> Int? {
        guard let raw else { return nil }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 2,
              let hours = Int(parts[0]), hours >= 0,
              let minutes = Int(parts[1]), (0..<60).contains(minutes)
        else {
            return nil
        }
        return hours * 60 + minutes
    }

    private static func durationDisplay(_ minutes: Int) -> String {
        "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }

    private static func tripDaysSummary(from raw: String?) -> ExportTripDaysSummary? {
        guard let raw,
              let days = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              days > 0 else {
            return nil
        }
        return ExportTripDaysSummary(days: days, display: String(days))
    }

    private static func fallbackEvents(
        for legs: [TripLeg],
        tripID: String,
        issues: inout [ExportDiagnosticIssue]
    ) -> [ExportEvent] {
        var events: [ExportEvent] = []
        var nextSequence = 1

        for index in legs.indices {
            let leg = legs[index]
            guard fallbackEventType(for: leg) != .groundTransport else {
                continue
            }
            let startValue = leg.depUTC ?? leg.stdUTC ?? ""
            let endValue = leg.arrUTC ?? leg.staUTC ?? ""
            guard let start = try? TripJSONExportService.exportTimestamp(
                startValue,
                timeZoneID: resolvedTimeZoneID(for: leg.depAirport)
            ),
                  let end = try? TripJSONExportService.exportTimestamp(
                    endValue,
                    timeZoneID: resolvedTimeZoneID(for: leg.arrAirport)
                  ) else {
                issues.append(issue(
                    code: "invalidLegTimestamp",
                    subjectID: tripID,
                    fieldGroup: "events",
                    message: "A displayed leg could not be exported because its UTC interval was invalid."
                ))
                continue
            }

            let type = fallbackEventType(for: leg)
            let segment = ExportEvent(
                id: "event-\(tripID)-\(type.rawValue)-\(nextSequence)",
                type: type,
                sequence: nextSequence,
                start: start,
                end: end,
                flightNumber: leg.flight.isEmpty ? nil : leg.flight,
                origin: leg.depAirport.isEmpty ? nil : leg.depAirport,
                destination: leg.arrAirport.isEmpty ? nil : leg.arrAirport,
                blockTime: leg.block.isEmpty ? nil : leg.block
            )
            events.append(segment)
            nextSequence += 1

            let remainingLegs = legs.suffix(from: index + 1)
            guard let nextIndex = remainingLegs.firstIndex(where: {
                fallbackEventType(for: $0) != .groundTransport
            }) else { continue }
            let nextLeg = legs[nextIndex]
            let nextType = fallbackEventType(for: nextLeg)
            let hasStructuredLayover = [
                leg.layoverStation,
                leg.layoverHotelName,
                leg.layoverDuration
            ].contains { normalizedOptional($0) != nil }
            guard hasStructuredLayover,
                  hasContinuousStationChain(
                    from: leg,
                    through: legs[(index + 1)..<nextIndex],
                    to: nextLeg
                  ),
                  let blockIn = TripJSONExportService.parseInstant(endValue),
                  let nextBlockOut = TripJSONExportService.parseInstant(nextLeg.depUTC ?? nextLeg.stdUTC ?? ""),
                  nextBlockOut > blockIn,
                  let layoverStart = try? TripJSONExportService.exportTimestamp(
                    TripJSONExportService.utcString(blockIn),
                    timeZoneID: resolvedTimeZoneID(for: leg.arrAirport)
                  ),
                  let layoverEnd = try? TripJSONExportService.exportTimestamp(
                    TripJSONExportService.utcString(nextBlockOut),
                    timeZoneID: resolvedTimeZoneID(for: nextLeg.depAirport)
                  ) else { continue }

            let durationMinutes = Int(nextBlockOut.timeIntervalSince(blockIn) / 60)
            events.append(ExportEvent(
                id: "event-\(tripID)-layover-\(nextSequence)",
                type: .layover,
                sequence: nextSequence,
                start: layoverStart,
                end: layoverEnd,
                station: normalizedOptional(leg.layoverStation) ?? normalizedOptional(leg.arrAirport),
                previousSegmentID: segment.id,
                nextSegmentID: "event-\(tripID)-\(nextType.rawValue)-\(nextSequence + 1)",
                blockGap: ExportDerivedInterval(
                    start: layoverStart,
                    end: layoverEnd,
                    durationMinutes: durationMinutes,
                    derived: true,
                    derivation: "previousSegment.end_to_nextSegment.start"
                ),
                scheduledRest: try? TripJSONExportService.scheduledRest(
                    blockIn: blockIn,
                    nextBlockOut: nextBlockOut,
                    dutyEndTimeZoneID: resolvedTimeZoneID(for: leg.arrAirport),
                    nextDutyStartTimeZoneID: resolvedTimeZoneID(for: nextLeg.depAirport)
                ),
                hotel: normalizedOptional(leg.layoverHotelName).map {
                    ExportHotel(name: $0, address: nil, phone: nil)
                }
            ))
            nextSequence += 1
        }
        return events
    }

    private static func hasContinuousStationChain(
        from leg: TripLeg,
        through intermediateLegs: ArraySlice<TripLeg>,
        to nextLeg: TripLeg
    ) -> Bool {
        var station = leg.arrAirport.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !station.isEmpty else { return false }

        for intermediate in intermediateLegs {
            let departure = intermediate.depAirport
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard fallbackEventType(for: intermediate) == .groundTransport,
                  station == departure else {
                return false
            }
            station = intermediate.arrAirport
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
        }
        return station == nextLeg.depAirport
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    private static func fallbackEventType(for leg: TripLeg) -> ExportEventType {
        if leg.status.caseInsensitiveCompare("GND") == .orderedSame
            || leg.flight.caseInsensitiveCompare("GND") == .orderedSame {
            return .groundTransport
        }
        if leg.status.caseInsensitiveCompare("DH") == .orderedSame {
            return .deadhead
        }
        return .flight
    }

    private static func exportCalendarEvents(
        input: BidPeriodScheduleExportInput,
        timeZone: TimeZone
    ) -> [BidPeriodExportCalendarEvent] {
        var events: [BidPeriodExportCalendarEvent] = []

        for event in input.manualOperationalEvents where overlaps(
            start: event.startUTC,
            end: event.endUTC,
            bidPeriod: input.bidPeriod
        ) {
            let eventTimeZone = event.crewBase.timeZone
            events.append(BidPeriodExportCalendarEvent(
                id: "manual-operational-\(event.id.uuidString.lowercased())",
                category: .operational,
                kind: event.code.rawValue,
                title: event.code.rawValue,
                timing: timedTiming(
                    start: event.startUTC,
                    end: event.endUTC,
                    timeZone: eventTimeZone,
                    timeZoneSource: "eventCrewBase"
                ),
                notes: normalizedOptional(event.notes),
                source: .userCreated
            ))
        }

        for event in input.manualPersonalEvents where overlaps(
            start: event.startUTC,
            end: event.endUTC,
            bidPeriod: input.bidPeriod
        ) {
            events.append(BidPeriodExportCalendarEvent(
                id: "manual-personal-\(event.id.uuidString.lowercased())",
                category: .personal,
                kind: event.code.rawValue,
                title: event.code.rawValue,
                timing: timedTiming(
                    start: event.startUTC,
                    end: event.endUTC,
                    timeZone: timeZone,
                    timeZoneSource: "selectedBidPeriodDomicile"
                ),
                notes: normalizedOptional(event.notes),
                source: .userCreated
            ))
        }

        events.append(contentsOf: BidPeriodCalendarEventService.events(
            in: input.bidPeriod,
            qualification: input.pilotQualification
        ).map { event in
            BidPeriodExportCalendarEvent(
                id: event.id,
                category: event.category == .bid ? .bid : .financial,
                kind: event.kind.rawValue,
                title: event.title,
                timing: allDayTiming(dateKey: event.dateKey, timeZone: timeZone),
                notes: nil,
                source: .calendarRule
            )
        })

        let profileDates: [(id: String, kind: String, title: String, date: String?)] = [
            ("profile-faa-medical-expiry", "faaMedicalExpiry", "FAA Medical Expiry Date", input.faaMedicalExpiryDate),
            ("profile-passport-expiry", "passportExpiry", "Passport Expiry Date", input.passportExpiryDate),
            ("profile-china-visa-expiry", "chinaVisaExpiry", "China Visa Expiry Date", input.chinaVisaExpiryDate)
        ]
        let visibleDateKeys = Set(input.bidPeriod.days.map(\.displayDateKey))
        for profileDate in profileDates {
            guard let dateKey = normalizedOptional(profileDate.date),
                  visibleDateKeys.contains(dateKey) else { continue }
            events.append(BidPeriodExportCalendarEvent(
                id: "\(profileDate.id)-\(dateKey)",
                category: .personal,
                kind: profileDate.kind,
                title: profileDate.title,
                timing: allDayTiming(dateKey: dateKey, timeZone: timeZone),
                notes: nil,
                source: .profileDate
            ))
        }

        return events.sorted(by: calendarEventSort)
    }

    private static func timedTiming(
        start: Date,
        end: Date,
        timeZone: TimeZone,
        timeZoneSource: String
    ) -> ExportCalendarEventTiming {
        ExportCalendarEventTiming(
            semantics: .timed,
            start: timestamp(start, timeZone: timeZone),
            end: timestamp(end, timeZone: timeZone),
            localStartDate: nil,
            localEndDateExclusive: nil,
            timeZone: timeZone.identifier,
            timeZoneSource: timeZoneSource
        )
    }

    private static func allDayTiming(
        dateKey: String,
        timeZone: TimeZone
    ) -> ExportCalendarEventTiming {
        ExportCalendarEventTiming(
            semantics: .allDay,
            start: nil,
            end: nil,
            localStartDate: dateKey,
            localEndDateExclusive: nextDateKey(after: dateKey),
            timeZone: timeZone.identifier,
            timeZoneSource: "selectedBidPeriodDomicile"
        )
    }

    private static func timestamp(_ date: Date, timeZone: TimeZone) -> ExportTimestamp {
        (try? TripJSONExportService.exportTimestamp(
            TripJSONExportService.utcString(date),
            timeZoneID: timeZone.identifier
        )) ?? utcTimestamp(date)
    }

    private static func utcTimestamp(_ date: Date) -> ExportTimestamp {
        let value = TripJSONExportService.utcString(date)
        return ExportTimestamp(instant: value, local: String(value.prefix(19)), timeZone: "GMT", utcOffset: "+00:00")
    }

    private static func overlaps(start: Date, end: Date, bidPeriod: CalendarBidPeriod) -> Bool {
        start < bidPeriod.endDateUTC && end > bidPeriod.startDateUTC
    }

    private static func nextDateKey(after dateKey: String) -> String? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateKey),
              let next = formatter.calendar.date(byAdding: .day, value: 1, to: date) else {
            return nil
        }
        return formatter.string(from: next)
    }

    private static func stableTripID(pairing: String, startUTC: Date) -> String {
        let identifier = TripJSONExportService.stableIDComponent(pairing)
        let date = TripJSONExportService.utcString(startUTC).prefix(10)
        return "trip-\(identifier)-\(date)"
    }

    private static func resolvedTimeZoneID(for airport: String) -> String? {
        IATATimeZoneResolver.shared.resolve(
            airport.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        )
    }

    private static func firstMeaningful(_ values: String...) -> String? {
        values.lazy.compactMap { value -> String? in
            let trimmed = value
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
            guard !trimmed.isEmpty,
                  trimmed != "-",
                  trimmed.caseInsensitiveCompare("unknown") != .orderedSame,
                  !trimmed.uppercased().hasPrefix("GEMS ") else { return nil }
            return trimmed
        }.first
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func issue(
        code: String,
        subjectID: String,
        fieldGroup: String,
        message: String
    ) -> ExportDiagnosticIssue {
        ExportDiagnosticIssue(
            severity: .warning,
            code: code,
            scope: "trip",
            subjectID: subjectID,
            fieldGroup: fieldGroup,
            message: message
        )
    }

    private static func legSort(_ lhs: TripLeg, _ rhs: TripLeg) -> Bool {
        let lhsDate = TripJSONExportService.parseInstant(lhs.depUTC ?? "") ?? .distantFuture
        let rhsDate = TripJSONExportService.parseInstant(rhs.depUTC ?? "") ?? .distantFuture
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        if lhs.leg != rhs.leg { return lhs.leg < rhs.leg }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func eventSort(_ lhs: ExportEvent, _ rhs: ExportEvent) -> Bool {
        (lhs.start.instant, lhs.sequence, lhs.id) < (rhs.start.instant, rhs.sequence, rhs.id)
    }

    private static func tripSort(_ lhs: BidPeriodExportTrip, _ rhs: BidPeriodExportTrip) -> Bool {
        (lhs.start.instant, lhs.tripNumber, lhs.id) < (rhs.start.instant, rhs.tripNumber, rhs.id)
    }

    private static func calendarEventSort(
        _ lhs: BidPeriodExportCalendarEvent,
        _ rhs: BidPeriodExportCalendarEvent
    ) -> Bool {
        (calendarEventSortKey(lhs), lhs.category.rawValue, lhs.title, lhs.id)
            < (calendarEventSortKey(rhs), rhs.category.rawValue, rhs.title, rhs.id)
    }

    private static func calendarEventSortKey(_ event: BidPeriodExportCalendarEvent) -> String {
        event.timing.start?.instant ?? event.timing.localStartDate ?? "9999-12-31"
    }

    private static func diagnosticSort(
        _ lhs: ExportDiagnosticIssue,
        _ rhs: ExportDiagnosticIssue
    ) -> Bool {
        (
            lhs.severity.rawValue,
            lhs.scope,
            lhs.subjectID ?? "",
            lhs.fieldGroup ?? "",
            lhs.code
        ) < (
            rhs.severity.rawValue,
            rhs.scope,
            rhs.subjectID ?? "",
            rhs.fieldGroup ?? "",
            rhs.code
        )
    }
}
