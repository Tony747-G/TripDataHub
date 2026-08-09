import XCTest
@testable import TripDataHub

/// CrewAccess per-leg time history (INV-012): merge behaviour, leg identity, and the model-level
/// guarantees that keep history alive across reconcile and relaunch.
///
/// Scope note: the `makePayload` / `makeMultiPayload` helpers below construct **already-classified**
/// payloads. They are fixtures for the *merge* logic and deliberately do not prove anything about
/// the Scheduled-versus-Actual classification itself — they mirror that rule rather than exercise
/// it. Classification is covered against real PDFs through the production parser in
/// `CrewAccessParserRegressionTests`
/// (`test_classificationMatrixPDF_...`, `test_arrivalBoundaryPDF_...`,
/// `test_extractPDFCreatedUTC_...`). Do not add classification assertions here.

final class CrewAccessLegHistoryTests: XCTestCase {
    func test_initialPreflightImport_isOriginalScheduledAndWhite() throws {
        let payload = makePayload(
            created: "2026-08-05T18:42:00Z",
            departure: "2026-08-05T23:34:00Z",
            arrival: "2026-08-06T04:36:00Z"
        )
        let schedule = try XCTUnwrap(AppViewModel.buildCrewAccessSchedule(from: payload, modifiedAt: .now))
        let leg = try XCTUnwrap(schedule.legs.first)

        XCTAssertEqual(leg.originalSTDUTC, leg.stdUTC)
        XCTAssertEqual(leg.originalSTAUTC, leg.staUTC)
        XCTAssertNil(leg.atdUTC)
        XCTAssertNil(leg.ataUTC)
        XCTAssertEqual(TimelineFlightVisualState.resolve(for: leg, legacyIsPast: false), .originalScheduled)
    }

    func test_preflightRevisionPreservesOriginalAndBecomesAmber() throws {
        let original = makePayload(
            created: "2026-08-05T18:42:00Z",
            departure: "2026-08-05T23:34:00Z",
            arrival: "2026-08-06T04:36:00Z"
        )
        let revised = makePayload(
            created: "2026-08-05T20:00:00Z",
            departure: "2026-08-06T05:34:00Z",
            arrival: "2026-08-06T10:30:00Z"
        )
        let merged = AppViewModel.mergeCrewAccessLegHistory(incoming: revised, existingPayloads: [original])
        let leg = try XCTUnwrap(AppViewModel.buildCrewAccessSchedule(from: merged, modifiedAt: .now)?.legs.first)

        XCTAssertEqual(leg.originalSTDUTC, "2026-08-05T23:34:00Z")
        XCTAssertEqual(leg.stdUTC, "2026-08-06T05:34:00Z")
        XCTAssertEqual(leg.originalSTAUTC, "2026-08-06T04:36:00Z")
        XCTAssertEqual(leg.staUTC, "2026-08-06T10:30:00Z")
        XCTAssertNil(leg.atdUTC)
        XCTAssertEqual(TimelineFlightVisualState.resolve(for: leg, legacyIsPast: false), .revisedScheduled)
    }

    func test_largeDelayUsesIncomingDepartureNotExpiredOriginalForClassification() throws {
        let original = makePayload(
            created: "2026-08-05T10:00:00Z",
            departure: "2026-08-05T12:00:00Z",
            arrival: "2026-08-05T18:00:00Z"
        )
        let delayed = makePayload(
            created: "2026-08-05T13:00:00Z",
            departure: "2026-08-05T18:00:00Z",
            arrival: "2026-08-06T00:00:00Z"
        )
        let merged = AppViewModel.mergeCrewAccessLegHistory(incoming: delayed, existingPayloads: [original])
        let item = try XCTUnwrap(merged.items.first)

        XCTAssertEqual(item.originalStdUtc, "2026-08-05T12:00:00Z")
        XCTAssertEqual(item.stdUtc, "2026-08-05T18:00:00Z")
        XCTAssertNil(item.atdUtc)
    }

    func test_destinationAndFlightChangePreserveStableLegHistory() throws {
        let original = makePayload(
            created: "2026-08-05T10:00:00Z",
            departure: "2026-08-05T18:00:00Z",
            arrival: "2026-08-05T23:00:00Z",
            flight: "5X059",
            destination: "ONT"
        )
        let changed = makePayload(
            created: "2026-08-05T12:00:00Z",
            departure: "2026-08-05T19:00:00Z",
            arrival: "2026-08-06T00:30:00Z",
            flight: "5X061",
            destination: "SDF"
        )
        let merged = AppViewModel.mergeCrewAccessLegHistory(incoming: changed, existingPayloads: [original])
        let item = try XCTUnwrap(merged.items.first)

        XCTAssertEqual(item.stableLegId, original.items.first?.stableLegId)
        XCTAssertEqual(item.originalStdUtc, "2026-08-05T18:00:00Z")
        XCTAssertEqual(item.flight, "5X061")
        XCTAssertEqual(item.arrAirport, "SDF")
        XCTAssertNil(item.atdUtc)
    }

    func test_flightNumberChangeOnlyReconnectsUnambiguousLeg() throws {
        let original = makeMultiPayload(
            created: "2026-08-05T10:00:00Z",
            legs: [.init(1, "ANC", "ONT", "5X059", "2026-08-05T18:00:00Z", "2026-08-05T23:00:00Z")]
        )
        let revised = makeMultiPayload(
            created: "2026-08-05T12:00:00Z",
            legs: [.init(1, "ANC", "ONT", "5X061", "2026-08-05T19:00:00Z", "2026-08-06T00:00:00Z")]
        )

        let merged = AppViewModel.mergeCrewAccessLegHistory(incoming: revised, existingPayloads: [original])

        XCTAssertEqual(merged.items.first?.stableLegId, original.items.first?.stableLegId)
        XCTAssertEqual(merged.items.first?.originalStdUtc, "2026-08-05T18:00:00Z")
        XCTAssertEqual(merged.items.first?.flight, "5X061")
    }

    func test_destinationChangeReconnectsOnlyWhenSequenceOriginAndUTCDateAreUnambiguous() throws {
        let original = makeMultiPayload(
            created: "2026-08-05T10:00:00Z",
            legs: [.init(1, "ANC", "ONT", "5X059", "2026-08-05T18:00:00Z", "2026-08-05T23:00:00Z")]
        )
        let revised = makeMultiPayload(
            created: "2026-08-05T12:00:00Z",
            legs: [.init(1, "ANC", "SDF", "5X059", "2026-08-05T19:00:00Z", "2026-08-06T00:30:00Z")]
        )

        let merged = AppViewModel.mergeCrewAccessLegHistory(incoming: revised, existingPayloads: [original])

        XCTAssertEqual(merged.items.first?.stableLegId, original.items.first?.stableLegId)
        XCTAssertEqual(merged.items.first?.originalStaUtc, "2026-08-05T23:00:00Z")
        XCTAssertEqual(merged.items.first?.arrAirport, "SDF")
    }

    func test_insertedLegDoesNotStealLaterLegHistoryAfterSequenceShift() throws {
        let original = makeMultiPayload(
            created: "2026-08-05T08:00:00Z",
            legs: [
                .init(1, "A", "B", "101", "2026-08-05T10:00:00Z", "2026-08-05T11:00:00Z"),
                .init(2, "B", "C", "102", "2026-08-05T12:00:00Z", "2026-08-05T13:00:00Z"),
                .init(3, "C", "D", "103", "2026-08-05T14:00:00Z", "2026-08-05T15:00:00Z")
            ]
        )
        let revised = makeMultiPayload(
            created: "2026-08-05T09:00:00Z",
            legs: [
                .init(1, "A", "B", "101", "2026-08-05T10:10:00Z", "2026-08-05T11:10:00Z"),
                .init(2, "B", "X", "102", "2026-08-05T12:10:00Z", "2026-08-05T13:10:00Z"),
                .init(3, "X", "C", "900", "2026-08-05T13:20:00Z", "2026-08-05T13:50:00Z"),
                .init(4, "C", "D", "103", "2026-08-05T14:10:00Z", "2026-08-05T15:10:00Z")
            ]
        )
        let oldLaterLeg = try XCTUnwrap(original.items.first { $0.sequence == 3 })
        let incomingInsertedLeg = try XCTUnwrap(revised.items.first { $0.sequence == 3 })

        let merged = AppViewModel.mergeCrewAccessLegHistory(incoming: revised, existingPayloads: [original])
        let insertedLeg = try XCTUnwrap(merged.items.first { $0.sequence == 3 })
        let shiftedLaterLeg = try XCTUnwrap(merged.items.first { $0.sequence == 4 })

        XCTAssertEqual(insertedLeg.stableLegId, incomingInsertedLeg.stableLegId)
        XCTAssertNotEqual(insertedLeg.stableLegId, oldLaterLeg.stableLegId)
        XCTAssertEqual(insertedLeg.originalStdUtc, "2026-08-05T13:20:00Z")
        XCTAssertEqual(shiftedLaterLeg.stableLegId, oldLaterLeg.stableLegId)
        XCTAssertEqual(shiftedLaterLeg.originalStdUtc, "2026-08-05T14:00:00Z")
    }

    func test_ambiguousOperationalIdentityCreatesNewLegHistory() throws {
        let original = makeMultiPayload(
            created: "2026-08-05T08:00:00Z",
            legs: [
                .init(1, "A", "B", "101", "2026-08-05T10:00:00Z", "2026-08-05T11:00:00Z"),
                .init(2, "A", "B", "101", "2026-08-05T12:00:00Z", "2026-08-05T13:00:00Z")
            ]
        )
        let incoming = makeMultiPayload(
            created: "2026-08-05T09:00:00Z",
            legs: [.init(3, "A", "B", "101", "2026-08-05T14:00:00Z", "2026-08-05T15:00:00Z")]
        )

        let merged = AppViewModel.mergeCrewAccessLegHistory(incoming: incoming, existingPayloads: [original])
        let item = try XCTUnwrap(merged.items.first)

        XCTAssertEqual(item.stableLegId, incoming.items.first?.stableLegId)
        XCTAssertFalse(original.items.compactMap(\.stableLegId).contains(item.stableLegId ?? ""))
        XCTAssertEqual(item.originalStdUtc, "2026-08-05T14:00:00Z")
    }

    func test_A70393RPostTripBecomesActualAndKeepsScheduleAndBlock() throws {
        let preTrip = makePayload(
            created: "2026-08-05T18:42:00Z",
            departure: "2026-08-05T23:34:00Z",
            arrival: "2026-08-06T04:36:00Z",
            block: "04:58"
        )
        let postTrip = makePayload(
            created: "2026-08-09T02:15:00Z",
            departure: "2026-08-05T23:45:00Z",
            arrival: "2026-08-06T04:43:00Z",
            block: "04:58"
        )
        let merged = AppViewModel.mergeCrewAccessLegHistory(incoming: postTrip, existingPayloads: [preTrip])
        let leg = try XCTUnwrap(AppViewModel.buildCrewAccessSchedule(from: merged, modifiedAt: .now)?.legs.first)

        XCTAssertEqual(leg.stdUTC, "2026-08-05T23:34:00Z")
        XCTAssertEqual(leg.staUTC, "2026-08-06T04:36:00Z")
        XCTAssertEqual(leg.atdUTC, "2026-08-05T23:45:00Z")
        XCTAssertEqual(leg.ataUTC, "2026-08-06T04:43:00Z")
        XCTAssertEqual(leg.block, "04:58")
        XCTAssertEqual(TimelineFlightVisualState.resolve(for: leg, legacyIsPast: false), .actual)
    }

    func test_registrationAndHistorySurviveReimportJSONRoundTripAndExport() throws {
        let original = makePayload(
            created: "2026-08-05T18:42:00Z",
            departure: "2026-08-05T23:34:00Z",
            arrival: "2026-08-06T04:36:00Z",
            tailNumber: "N605UP"
        )
        let actual = makePayload(
            created: "2026-08-09T02:15:00Z",
            departure: "2026-08-05T23:45:00Z",
            arrival: "2026-08-06T04:43:00Z"
        )
        let merged = AppViewModel.mergeCrewAccessLegHistory(incoming: actual, existingPayloads: [original])
        let relaunched = try JSONDecoder().decode(
            CrewAccessTripJSON.self,
            from: JSONEncoder().encode(merged)
        )
        let schedule = try XCTUnwrap(AppViewModel.buildCrewAccessSchedule(from: relaunched, modifiedAt: .now))
        let leg = try XCTUnwrap(schedule.legs.first)
        let event = try XCTUnwrap(TripJSONExportService.publicEvents(
            payload: relaunched,
            schedule: schedule,
            tripID: "trip-a70393r-2026-08-05"
        ).first)

        XCTAssertEqual(leg.aircraftRegistration, "N605UP")
        XCTAssertEqual(event.aircraft, "B748")
        XCTAssertEqual(event.aircraftRegistration, "N605UP")
        XCTAssertEqual(event.blockTime, "04:58")
        XCTAssertEqual(event.departure?.originalScheduled?.instant, "2026-08-05T23:34:00Z")
        XCTAssertEqual(event.departure?.scheduled?.observedAt, "2026-08-05T18:42:00Z")
        XCTAssertEqual(event.departure?.actual?.instant, "2026-08-05T23:45:00Z")
        XCTAssertEqual(event.departure?.actual?.observedAt, "2026-08-09T02:15:00Z")
        XCTAssertEqual(event.arrival?.actual?.instant, "2026-08-06T04:43:00Z")
    }

    /// A revision can move a trip across the 03:00 domicile-local Bid Period boundary, which
    /// changes its Bid Period trip key. Predecessor lookup must fall back to the normalized Trip
    /// ID, otherwise the merge returns `incoming` untouched and the Original Scheduled values and
    /// the manual registration are lost in the same transaction that tombstones the old artifact.
    func test_bidPeriodBoundaryRevisionKeepsOriginalHistoryAndRegistration() throws {
        // BP26-05 starts 2026-07-12 03:00 domicile-local, so 2026-07-11 resolves to BP26-04 and
        // 2026-07-13 to BP26-05. Two days apart in wall-clock terms, but a different Bid Period
        // identity — the realistic shape of a boundary-crossing revision.
        var original = makePayload(
            created: "2026-07-10T10:00:00Z",
            departure: "2026-07-11T10:00:00Z",
            arrival: "2026-07-11T16:00:00Z",
            tailNumber: "N605UP"
        )
        original = Self.payload(
            original,
            generatedAt: "2026-07-10T10:00:00Z",
            tripInformationDate: "2026-07-11"
        )

        var revised = makePayload(
            created: "2026-07-10T20:00:00Z",
            departure: "2026-07-13T10:00:00Z",
            arrival: "2026-07-13T16:00:00Z"
        )
        revised = Self.payload(
            revised,
            generatedAt: "2026-07-10T20:00:00Z",
            tripInformationDate: "2026-07-13"
        )

        XCTAssertNotEqual(
            bidPeriod(for: Self.utc("2026-07-11T00:00:00Z"))?.id,
            bidPeriod(for: Self.utc("2026-07-13T00:00:00Z"))?.id,
            "precondition: the two generations sit in different Bid Period identities"
        )

        let merged = AppViewModel.mergeCrewAccessLegHistory(
            incoming: revised,
            existingPayloads: [original]
        )
        let item = try XCTUnwrap(merged.items.first)

        XCTAssertEqual(item.originalStdUtc, "2026-07-11T10:00:00Z", "original schedule must survive")
        XCTAssertEqual(item.originalStaUtc, "2026-07-11T16:00:00Z")
        XCTAssertEqual(item.stdUtc, "2026-07-13T10:00:00Z", "current schedule is the revision")
        XCTAssertEqual(item.tailNumber, "N605UP", "manual registration must survive")
        XCTAssertEqual(item.stableLegId, original.items.first?.stableLegId)
    }

    /// The cross-Bid-Period fallback must stay bounded. Trip IDs are reused between Bid Periods,
    /// and attaching a previous trip's history to an unrelated trip that merely reuses the
    /// identifier is worse than starting a fresh leg identity.
    func test_sameTripIDInADifferentBidPeriodDoesNotInheritHistory() throws {
        var lastYear = makePayload(
            created: "2026-05-19T10:00:00Z",
            departure: "2026-05-20T10:00:00Z",
            arrival: "2026-05-20T16:00:00Z",
            tailNumber: "N605UP"
        )
        lastYear = Self.payload(
            lastYear,
            generatedAt: "2026-05-19T10:00:00Z",
            tripInformationDate: "2026-05-20"
        )

        // Same Trip ID and same route, but a whole Bid Period later: a different physical trip.
        var thisPeriod = makePayload(
            created: "2026-08-04T10:00:00Z",
            departure: "2026-08-05T10:00:00Z",
            arrival: "2026-08-05T16:00:00Z"
        )
        thisPeriod = Self.payload(
            thisPeriod,
            generatedAt: "2026-08-04T10:00:00Z",
            tripInformationDate: "2026-08-05"
        )

        let merged = AppViewModel.mergeCrewAccessLegHistory(
            incoming: thisPeriod,
            existingPayloads: [lastYear]
        )
        let item = try XCTUnwrap(merged.items.first)

        XCTAssertEqual(item.originalStdUtc, "2026-08-05T10:00:00Z", "must keep its own history")
        XCTAssertNil(item.tailNumber, "must not inherit an unrelated trip's registration")
        XCTAssertEqual(
            item.stableLegId,
            thisPeriod.items.first?.stableLegId,
            "must keep its own leg identity"
        )
    }

    private static func utc(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value) ?? .distantPast
    }

    /// The merge must not treat the incoming generation as its own predecessor when the same file
    /// is already on disk (re-confirming an identical import).
    func test_mergeIgnoresIdenticalIncomingGenerationAsItsOwnPredecessor() throws {
        let payload = makePayload(
            created: "2026-08-05T18:42:00Z",
            departure: "2026-08-05T23:34:00Z",
            arrival: "2026-08-06T04:36:00Z"
        )
        let merged = AppViewModel.mergeCrewAccessLegHistory(
            incoming: payload,
            existingPayloads: [payload]
        )
        let item = try XCTUnwrap(merged.items.first)
        XCTAssertEqual(item.stableLegId, payload.items.first?.stableLegId)
        XCTAssertEqual(item.originalStdUtc, "2026-08-05T23:34:00Z")
        XCTAssertEqual(item.stdUtc, "2026-08-05T23:34:00Z")
    }

    /// Predecessor selection must pick the newest generation by `generatedAt`, independently of
    /// the order the payloads happen to be enumerated from the imports directory.
    func test_predecessorSelectionPicksNewestRegardlessOfInputOrder() throws {
        var older = makePayload(
            created: "2026-08-01T10:00:00Z",
            departure: "2026-08-05T23:34:00Z",
            arrival: "2026-08-06T04:36:00Z"
        )
        older = Self.payload(older, generatedAt: "2026-08-01T10:00:00Z")

        var newer = makePayload(
            created: "2026-08-02T10:00:00Z",
            departure: "2026-08-05T23:00:00Z",
            arrival: "2026-08-06T04:00:00Z",
            tailNumber: "N999UP"
        )
        newer = Self.payload(newer, generatedAt: "2026-08-02T10:00:00Z")

        let incoming = makePayload(
            created: "2026-08-03T10:00:00Z",
            departure: "2026-08-05T22:00:00Z",
            arrival: "2026-08-06T03:00:00Z"
        )

        // Feed them in reverse chronological order to prove the ordering is not positional.
        let merged = AppViewModel.mergeCrewAccessLegHistory(
            incoming: incoming,
            existingPayloads: [newer, older]
        )
        let item = try XCTUnwrap(merged.items.first)
        XCTAssertEqual(item.tailNumber, "N999UP", "the newest predecessor must be selected")
        XCTAssertEqual(item.originalStdUtc, "2026-08-05T23:00:00Z")
    }

    // MARK: - Model-level guarantees

    /// C-1 regression. `TripLeg` is copy-and-mutate precisely so that a derived leg cannot silently
    /// lose fields. Two production transforms used to rebuild legs memberwise and dropped the
    /// entire history block plus the manual registration.
    func test_copyAndMutatePreservesEveryOtherField() throws {
        let leg = Self.fullyPopulatedLeg()
        var copy = leg
        copy.depUTC = "2026-08-05T23:59:00Z"
        copy.depLocal = "2026-08-05 15:59"

        XCTAssertEqual(copy.depUTC, "2026-08-05T23:59:00Z")
        XCTAssertEqual(copy.depLocal, "2026-08-05 15:59")
        // Everything the old memberwise reconstructions forgot:
        XCTAssertEqual(copy.originalSTDUTC, leg.originalSTDUTC)
        XCTAssertEqual(copy.originalSTAUTC, leg.originalSTAUTC)
        XCTAssertEqual(copy.scheduledDepartureObservedAtUTC, leg.scheduledDepartureObservedAtUTC)
        XCTAssertEqual(copy.scheduledArrivalObservedAtUTC, leg.scheduledArrivalObservedAtUTC)
        XCTAssertEqual(copy.actualDepartureObservedAtUTC, leg.actualDepartureObservedAtUTC)
        XCTAssertEqual(copy.actualArrivalObservedAtUTC, leg.actualArrivalObservedAtUTC)
        XCTAssertEqual(copy.aircraftType, leg.aircraftType)
        XCTAssertEqual(copy.aircraftRegistration, leg.aircraftRegistration)
        XCTAssertEqual(copy.id, leg.id)
    }

    func test_withHotelNamePreservesHistoryAndRegistration() throws {
        let leg = Self.fullyPopulatedLeg()
        let renamed = leg.withHotelName("Some Hotel")

        XCTAssertEqual(renamed.layoverHotelName, "Some Hotel")
        XCTAssertEqual(renamed.aircraftRegistration, "N605UP")
        XCTAssertEqual(renamed.originalSTDUTC, leg.originalSTDUTC)
        XCTAssertEqual(renamed.actualArrivalObservedAtUTC, leg.actualArrivalObservedAtUTC)
    }

    /// M-9 regression. The synthesized `Decodable` initializer cannot run the memberwise `init`,
    /// so any normalization done there makes a decoded leg unequal to the leg it was encoded from.
    /// `TripLeg` is `Equatable` and that inequality would leak into change detection and dedupe.
    func test_decodedLegEqualsConstructedLegAcrossRoundTrip() throws {
        let leg = Self.fullyPopulatedLeg()
        let decoded = try JSONDecoder().decode(TripLeg.self, from: JSONEncoder().encode(leg))
        XCTAssertEqual(decoded, leg)
        XCTAssertEqual(decoded.hashValue, leg.hashValue)
    }

    /// A nil original means "never observed" and must not be quietly replaced by the current
    /// scheduled value — including through `init`, which used to apply a `?? stdUTC` fallback that
    /// the decoder had no way of matching.
    func test_nilOriginalScheduledMeansUnknownInBothInitAndDecode() throws {
        let leg = TripLeg(
            payPeriod: "CA26-08-A70393R",
            pairing: "A70393R",
            leg: 1,
            flight: "5X059",
            depAirport: "ANC",
            depLocal: "2026-08-05 15:34",
            arrAirport: "ONT",
            arrLocal: "2026-08-05 21:36",
            depUTC: "2026-08-05T23:34:00Z",
            arrUTC: "2026-08-06T04:36:00Z",
            status: "-",
            block: "04:58",
            stdUTC: "2026-08-05T23:34:00Z",
            staUTC: "2026-08-06T04:36:00Z"
        )

        XCTAssertNil(leg.originalSTDUTC, "init must not synthesize an original from the current value")
        XCTAssertNil(leg.originalSTAUTC)
        XCTAssertFalse(leg.hasRevisedSchedule, "an unknown original is not evidence of a revision")

        let decoded = try JSONDecoder().decode(TripLeg.self, from: JSONEncoder().encode(leg))
        XCTAssertEqual(decoded, leg)
        XCTAssertNil(decoded.originalSTDUTC)
    }

    /// Identity and planning resolve Scheduled first; only display resolves Actual first.
    func test_plannedTimesIgnoreActualsButFallBackWhenScheduleUnknown() throws {
        var leg = Self.fullyPopulatedLeg()
        XCTAssertEqual(leg.plannedDepartureUTC, leg.stdUTC)
        XCTAssertEqual(leg.plannedArrivalUTC, leg.staUTC)
        XCTAssertNotEqual(leg.plannedDepartureUTC, leg.atdUTC, "an Actual must not become planning time")

        // Actual-only leg (post-flight first import): no schedule was ever observed.
        leg.stdUTC = nil
        leg.staUTC = nil
        leg.originalSTDUTC = nil
        leg.originalSTAUTC = nil
        XCTAssertEqual(leg.plannedDepartureUTC, leg.depUTC, "falls back only when nothing else is known")
    }

    func test_completionFlagsDistinguishAirborneFromFlown() throws {
        var leg = Self.fullyPopulatedLeg()
        XCTAssertTrue(leg.isCompleted)
        XCTAssertTrue(leg.hasActualTimes)

        leg.ataUTC = nil
        XCTAssertFalse(leg.isCompleted, "an ATD without an ATA is airborne, not flown")
        XCTAssertTrue(leg.hasActualTimes)
    }

    private static func fullyPopulatedLeg() -> TripLeg {
        TripLeg(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
            payPeriod: "CA26-08-A70393R",
            pairing: "A70393R",
            leg: 1,
            flight: "5X059",
            depAirport: "ANC",
            depLocal: "2026-08-05 15:45",
            arrAirport: "ONT",
            arrLocal: "2026-08-05 21:43",
            depUTC: "2026-08-05T23:45:00Z",
            arrUTC: "2026-08-06T04:43:00Z",
            status: "-",
            block: "04:58",
            layoverStation: "ONT",
            layoverHotelName: "Original Hotel",
            layoverDuration: "18:00",
            stdUTC: "2026-08-05T23:34:00Z",
            staUTC: "2026-08-06T04:36:00Z",
            atdUTC: "2026-08-05T23:45:00Z",
            ataUTC: "2026-08-06T04:43:00Z",
            originalSTDUTC: "2026-08-05T23:20:00Z",
            originalSTAUTC: "2026-08-06T04:30:00Z",
            scheduledDepartureObservedAtUTC: "2026-08-05T18:42:00Z",
            scheduledArrivalObservedAtUTC: "2026-08-05T18:42:00Z",
            actualDepartureObservedAtUTC: "2026-08-09T02:15:00Z",
            actualArrivalObservedAtUTC: "2026-08-09T02:15:00Z",
            aircraftType: "B748",
            aircraftRegistration: "N605UP"
        )
    }

    /// Rebuilds a payload with selected trip-level fields replaced.
    private static func payload(
        _ source: CrewAccessTripJSON,
        generatedAt: String? = nil,
        tripInformationDate: String? = nil
    ) -> CrewAccessTripJSON {
        CrewAccessTripJSON(
            schemaVersion: source.schemaVersion,
            source: source.source,
            sourceVersion: source.sourceVersion,
            mappingVersion: source.mappingVersion,
            generatedAt: generatedAt ?? source.generatedAt,
            pdfCreatedUtc: source.pdfCreatedUtc,
            tripId: source.tripId,
            tripInformationDate: tripInformationDate ?? source.tripInformationDate,
            creditTime: source.creditTime,
            tripDays: source.tripDays,
            tafb: source.tafb,
            dutyTotals: source.dutyTotals,
            hotelDetails: source.hotelDetails,
            crew: source.crew,
            items: source.items
        )
    }

    private func makePayload(
        created: String,
        departure: String,
        arrival: String,
        flight: String = "5X059",
        destination: String = "ONT",
        block: String = "04:58",
        tailNumber: String? = nil
    ) -> CrewAccessTripJSON {
        let createdDate = ISO8601DateFormatter().date(from: created)!
        let departureDate = ISO8601DateFormatter().date(from: departure)!
        let arrivalDate = ISO8601DateFormatter().date(from: arrival)!
        let departureScheduled = createdDate < departureDate
        let arrivalScheduled = createdDate < arrivalDate
        let item = CrewAccessTripItemJSON(
            sequence: 1,
            depAirport: "ANC",
            arrAirport: destination,
            deadhead: false,
            flight: flight,
            startUtc: departure,
            endUtc: arrival,
            startLocalDisplay: "2026-08-05 15:34",
            endLocalDisplay: "2026-08-05 21:36",
            originTz: "America/Anchorage",
            destinationTz: "America/Los_Angeles",
            timeDerivation: "from_utc",
            aircraft: "B748",
            block: block,
            stdUtc: departureScheduled ? departure : nil,
            staUtc: arrivalScheduled ? arrival : nil,
            atdUtc: departureScheduled ? nil : departure,
            ataUtc: arrivalScheduled ? nil : arrival,
            tailNumber: tailNumber,
            stableLegId: UUID().uuidString,
            originalStdUtc: departureScheduled ? departure : nil,
            originalStaUtc: arrivalScheduled ? arrival : nil,
            scheduledDepartureObservedAtUtc: departureScheduled ? created : nil,
            scheduledArrivalObservedAtUtc: arrivalScheduled ? created : nil,
            actualDepartureObservedAtUtc: departureScheduled ? nil : created,
            actualArrivalObservedAtUtc: arrivalScheduled ? nil : created
        )
        return CrewAccessTripJSON(
            schemaVersion: 2,
            source: "crewaccess-pdf",
            sourceVersion: "test",
            mappingVersion: "test",
            generatedAt: created,
            pdfCreatedUtc: created,
            tripId: "A70393R",
            tripInformationDate: "2026-08-05",
            creditTime: nil,
            tripDays: nil,
            tafb: nil,
            dutyTotals: [],
            hotelDetails: [],
            crew: [],
            items: [item]
        )
    }

    private struct MultiLegInput {
        let sequence: Int
        let origin: String
        let destination: String
        let flight: String
        let departure: String
        let arrival: String

        init(
            _ sequence: Int,
            _ origin: String,
            _ destination: String,
            _ flight: String,
            _ departure: String,
            _ arrival: String
        ) {
            self.sequence = sequence
            self.origin = origin
            self.destination = destination
            self.flight = flight
            self.departure = departure
            self.arrival = arrival
        }
    }

    private func makeMultiPayload(
        created: String,
        legs: [MultiLegInput]
    ) -> CrewAccessTripJSON {
        let formatter = ISO8601DateFormatter()
        let createdDate = formatter.date(from: created)!
        let items = legs.map { leg in
            let departureScheduled = createdDate < formatter.date(from: leg.departure)!
            let arrivalScheduled = createdDate < formatter.date(from: leg.arrival)!
            return CrewAccessTripItemJSON(
                sequence: leg.sequence,
                depAirport: leg.origin,
                arrAirport: leg.destination,
                deadhead: false,
                flight: leg.flight,
                startUtc: leg.departure,
                endUtc: leg.arrival,
                startLocalDisplay: leg.departure,
                endLocalDisplay: leg.arrival,
                originTz: "UTC",
                destinationTz: "UTC",
                timeDerivation: "from_utc",
                aircraft: "B748",
                block: "01:00",
                stdUtc: departureScheduled ? leg.departure : nil,
                staUtc: arrivalScheduled ? leg.arrival : nil,
                atdUtc: departureScheduled ? nil : leg.departure,
                ataUtc: arrivalScheduled ? nil : leg.arrival,
                tailNumber: nil,
                stableLegId: UUID().uuidString,
                originalStdUtc: departureScheduled ? leg.departure : nil,
                originalStaUtc: arrivalScheduled ? leg.arrival : nil,
                scheduledDepartureObservedAtUtc: departureScheduled ? created : nil,
                scheduledArrivalObservedAtUtc: arrivalScheduled ? created : nil,
                actualDepartureObservedAtUtc: departureScheduled ? nil : created,
                actualArrivalObservedAtUtc: arrivalScheduled ? nil : created
            )
        }
        return CrewAccessTripJSON(
            schemaVersion: 2,
            source: "crewaccess-pdf",
            sourceVersion: "test",
            mappingVersion: "test",
            generatedAt: created,
            pdfCreatedUtc: created,
            tripId: "MATCH01",
            tripInformationDate: "2026-08-05",
            creditTime: nil,
            tripDays: nil,
            tafb: nil,
            dutyTotals: [],
            hotelDetails: [],
            crew: [],
            items: items
        )
    }
}
