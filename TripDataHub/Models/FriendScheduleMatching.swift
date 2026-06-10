import Foundation

struct SharedScheduleFlight: Identifiable, Codable, Hashable {
    let id: String
    let flightNumber: String
    let departureAirport: String
    let arrivalAirport: String
    let departureUTC: Date
    let arrivalUTC: Date
    let isDeadhead: Bool
}

struct SharedRestWindow: Identifiable, Codable, Hashable {
    let id: String
    let station: String
    let hotelName: String?
    let startUTC: Date
    let endUTC: Date
    let durationMinutes: Int
    let arrivalLegID: String
    let departureLegID: String
}

struct SharedScheduleSnapshot: Identifiable, Codable, Hashable {
    let id: String
    let ownerGEMSID: String
    let generatedAtUTC: Date
    let flights: [SharedScheduleFlight]
    let restWindows: [SharedRestWindow]
}

struct FriendFlightMatch: Identifiable, Codable, Hashable {
    let id: String
    let friendGEMSID: String
    let flightNumber: String
    let departureAirport: String
    let arrivalAirport: String
    let departureUTC: Date
    let myFlightID: String
    let friendFlightID: String
}

struct FriendRestOverlap: Identifiable, Codable, Hashable {
    let id: String
    let friendGEMSID: String
    let station: String
    let overlapStartUTC: Date
    let overlapEndUTC: Date
    let overlapMinutes: Int
    let myRestWindowID: String
    let friendRestWindowID: String
}

struct FriendScheduleMatches: Hashable {
    let flightMatchesByLegID: [UUID: [FriendFlightMatch]]
    let restOverlapsByArrivalLegID: [UUID: [FriendRestOverlap]]

    static let empty = FriendScheduleMatches(flightMatchesByLegID: [:], restOverlapsByArrivalLegID: [:])
}

enum SharedScheduleExporter {
    static func snapshot(
        ownerGEMSID: String,
        schedules: [PayPeriodSchedule],
        generatedAtUTC: Date = Date()
    ) -> SharedScheduleSnapshot {
        let legData = TimelineLegData(schedules: schedules, now: generatedAtUTC)
        let flights = legData.allLegs.compactMap { flight(from: $0) }
        let restWindows = legData.allLegs.compactMap { leg in
            restWindow(from: leg, nextLeg: legData.nextLegByID[leg.id])
        }

        return SharedScheduleSnapshot(
            id: ownerGEMSID,
            ownerGEMSID: ownerGEMSID,
            generatedAtUTC: generatedAtUTC,
            flights: flights,
            restWindows: restWindows
        )
    }

    private static func flight(from leg: TripLeg) -> SharedScheduleFlight? {
        guard let departureUTC = LegConnectionTextBuilder.parseUTC(leg.depUTC),
              let arrivalUTC = LegConnectionTextBuilder.parseUTC(leg.arrUTC)
        else {
            return nil
        }

        return SharedScheduleFlight(
            id: leg.id.uuidString,
            flightNumber: normalizedFlightNumber(leg.flight),
            departureAirport: normalizedAirport(leg.depAirport),
            arrivalAirport: normalizedAirport(leg.arrAirport),
            departureUTC: departureUTC,
            arrivalUTC: arrivalUTC,
            isDeadhead: leg.isDeadheadOrCML
        )
    }

    private static func restWindow(from leg: TripLeg, nextLeg: TripLeg?) -> SharedRestWindow? {
        guard let nextLeg,
              leg.pairing == nextLeg.pairing,
              normalizedAirport(leg.arrAirport) == normalizedAirport(nextLeg.depAirport),
              let arrivalUTC = LegConnectionTextBuilder.parseUTC(leg.arrUTC),
              let nextDepartureUTC = LegConnectionTextBuilder.parseUTC(nextLeg.depUTC)
        else {
            return nil
        }

        let startUTC = arrivalUTC.addingTimeInterval(30 * 60)
        let endUTC = TimelineLayoverSupport.restInfo(arrDate: arrivalUTC, nextLeg: nextLeg)?.dutyStartUTC
            ?? nextDepartureUTC.addingTimeInterval(-90 * 60)
        guard endUTC > startUTC else { return nil }

        let durationMinutes = Int(endUTC.timeIntervalSince(startUTC) / 60)
        let station = normalizedAirport(leg.layoverStation ?? leg.arrAirport)

        return SharedRestWindow(
            id: leg.id.uuidString,
            station: station,
            hotelName: leg.layoverHotelName,
            startUTC: startUTC,
            endUTC: endUTC,
            durationMinutes: durationMinutes,
            arrivalLegID: leg.id.uuidString,
            departureLegID: nextLeg.id.uuidString
        )
    }

    static func normalizedAirport(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func normalizedFlightNumber(_ raw: String) -> String {
        FlightNumberNormalizer.displayValue(raw)
    }
}

enum FriendScheduleMatchDetector {
    static let minimumRestOverlapMinutes = 60
    static let flightDepartureTolerance: TimeInterval = 30 * 60

    static func detect(
        mySchedules: [PayPeriodSchedule],
        friendSchedules: [(gemsID: String, schedules: [PayPeriodSchedule])],
        now: Date = Date()
    ) -> FriendScheduleMatches {
        guard !mySchedules.isEmpty, !friendSchedules.isEmpty else { return .empty }

        let mySnapshot = SharedScheduleExporter.snapshot(ownerGEMSID: "me", schedules: mySchedules, generatedAtUTC: now)
        var flightMatchesByLegID: [UUID: [FriendFlightMatch]] = [:]
        var restOverlapsByArrivalLegID: [UUID: [FriendRestOverlap]] = [:]

        for friend in friendSchedules {
            let friendSnapshot = SharedScheduleExporter.snapshot(
                ownerGEMSID: friend.gemsID,
                schedules: friend.schedules,
                generatedAtUTC: now
            )

            for myFlight in mySnapshot.flights {
                for friendFlight in friendSnapshot.flights where flightsMatch(myFlight, friendFlight) {
                    guard let legID = UUID(uuidString: myFlight.id) else { continue }
                    let match = FriendFlightMatch(
                        id: "\(friend.gemsID)|\(myFlight.id)|\(friendFlight.id)",
                        friendGEMSID: friend.gemsID,
                        flightNumber: myFlight.flightNumber,
                        departureAirport: myFlight.departureAirport,
                        arrivalAirport: myFlight.arrivalAirport,
                        departureUTC: myFlight.departureUTC,
                        myFlightID: myFlight.id,
                        friendFlightID: friendFlight.id
                    )
                    flightMatchesByLegID[legID, default: []].append(match)
                }
            }

            for myRest in mySnapshot.restWindows {
                for friendRest in friendSnapshot.restWindows {
                    guard let overlap = restOverlap(myRest, friendRest),
                          overlap.minutes >= minimumRestOverlapMinutes,
                          let legID = UUID(uuidString: myRest.arrivalLegID)
                    else {
                        continue
                    }
                    let match = FriendRestOverlap(
                        id: "\(friend.gemsID)|\(myRest.id)|\(friendRest.id)",
                        friendGEMSID: friend.gemsID,
                        station: myRest.station,
                        overlapStartUTC: overlap.start,
                        overlapEndUTC: overlap.end,
                        overlapMinutes: overlap.minutes,
                        myRestWindowID: myRest.id,
                        friendRestWindowID: friendRest.id
                    )
                    restOverlapsByArrivalLegID[legID, default: []].append(match)
                }
            }
        }

        return FriendScheduleMatches(
            flightMatchesByLegID: flightMatchesByLegID.mapValues(deduplicatedSortedFlightMatches),
            restOverlapsByArrivalLegID: restOverlapsByArrivalLegID.mapValues(deduplicatedSortedRestOverlaps)
        )
    }

    private static func flightsMatch(_ lhs: SharedScheduleFlight, _ rhs: SharedScheduleFlight) -> Bool {
        lhs.flightNumber == rhs.flightNumber
            && lhs.departureAirport == rhs.departureAirport
            && lhs.arrivalAirport == rhs.arrivalAirport
            && abs(lhs.departureUTC.timeIntervalSince(rhs.departureUTC)) <= flightDepartureTolerance
    }

    private static func restOverlap(
        _ lhs: SharedRestWindow,
        _ rhs: SharedRestWindow
    ) -> (start: Date, end: Date, minutes: Int)? {
        guard lhs.station == rhs.station else { return nil }
        let start = max(lhs.startUTC, rhs.startUTC)
        let end = min(lhs.endUTC, rhs.endUTC)
        guard end > start else { return nil }
        return (start, end, Int(end.timeIntervalSince(start) / 60))
    }

    private static func deduplicatedSortedFlightMatches(_ matches: [FriendFlightMatch]) -> [FriendFlightMatch] {
        Array(Dictionary(grouping: matches, by: \.id).compactMap { $0.value.first })
            .sorted { lhs, rhs in
                if lhs.friendGEMSID == rhs.friendGEMSID { return lhs.departureUTC < rhs.departureUTC }
                return lhs.friendGEMSID < rhs.friendGEMSID
            }
    }

    private static func deduplicatedSortedRestOverlaps(_ matches: [FriendRestOverlap]) -> [FriendRestOverlap] {
        Array(Dictionary(grouping: matches, by: \.id).compactMap { $0.value.first })
            .sorted { lhs, rhs in
                if lhs.friendGEMSID == rhs.friendGEMSID { return lhs.overlapMinutes > rhs.overlapMinutes }
                return lhs.friendGEMSID < rhs.friendGEMSID
            }
    }
}

extension TripLeg {
    var isDeadheadOrCML: Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized == "DH" || normalized == "CML"
    }
}
