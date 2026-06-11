import CoreGraphics
import XCTest
@testable import TripDataHub

final class CalendarBidPeriodGenerationTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_generateBidPeriodDays_returns56Days() {
        let days = generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!)
        XCTAssertEqual(days.count, 56)
    }

    func test_generateBidPeriodDays_supportsShortBidPeriod() {
        let days = generateBidPeriodDays(
            startUTC: Self.iso.date(from: "2026-11-01T00:00:00Z")!,
            payPeriodCount: 1
        )
        XCTAssertEqual(days.count, 28)
        XCTAssertEqual(days[0].payPeriodIndex, 0)
        XCTAssertEqual(days[27].payPeriodIndex, 0)
    }

    func test_generateBidPeriodDays_usesSundayFirstIndexing() {
        let days = generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!)
        XCTAssertEqual(days[0].weekIndex, 0)
        XCTAssertEqual(days[0].weekdayIndex, 0)
        XCTAssertEqual(days[6].weekIndex, 0)
        XCTAssertEqual(days[6].weekdayIndex, 6)
        XCTAssertEqual(days[7].weekIndex, 1)
        XCTAssertEqual(days[7].weekdayIndex, 0)
    }

    func test_generateBidPeriodDays_assignsPayPeriodIndexAcross56DayWindow() {
        let days = generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!)
        XCTAssertEqual(days[0].payPeriodIndex, 0)
        XCTAssertEqual(days[27].payPeriodIndex, 0)
        XCTAssertEqual(days[28].payPeriodIndex, 1)
        XCTAssertEqual(days[55].payPeriodIndex, 1)
    }

    func test_generateBidPeriodDays_areConsecutiveUTCDays() {
        let days = generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!)
        for index in 1..<days.count {
            XCTAssertEqual(days[index - 1].dayEndUTC, days[index].dayStartUTC)
        }
    }

    func test_bidPeriod_endDateUTC_isExclusive() {
        let period = bidPeriod(for: Self.iso.date(from: "2026-03-22T12:00:00Z")!)
        XCTAssertNotNil(period)
        XCTAssertNotEqual(bidPeriod(for: period!.endDateUTC)?.id, period?.id)
    }

    func test_bidPeriod_forShortBidPeriod_uses28DayWindow() {
        let period = bidPeriod(for: Self.iso.date(from: "2026-11-15T12:00:00Z")!)
        XCTAssertEqual(period?.id, "BP26-07")
        XCTAssertEqual(period?.days.count, 28)
        XCTAssertEqual(period?.endDateUTC, Self.iso.date(from: "2026-11-29T12:00:00Z"))
        XCTAssertEqual(bidPeriod(for: period!.endDateUTC)?.id, "BP27-01")
    }

    func test_bidPeriodWindow_keepsTwoPeriodsOnEachSide() throws {
        let center = try XCTUnwrap(bidPeriod(identifier: "BP26-04"))

        XCTAssertEqual(
            bidPeriodWindow(centeredOn: center, previousCount: 2, nextCount: 2).map(\.id),
            ["BP26-02", "BP26-03", "BP26-04", "BP26-05", "BP26-06"]
        )
    }

    func test_bidPeriodWindow_clampsAtKnownCalendarEdges() throws {
        let center = try XCTUnwrap(bidPeriod(identifier: "BP26-01"))

        XCTAssertEqual(
            bidPeriodWindow(centeredOn: center, previousCount: 2, nextCount: 2).map(\.id),
            ["BP26-01", "BP26-02", "BP26-03"]
        )
    }

    func test_bidPeriod_matchesPayPeriodPairs() {
        let bp2604 = bidPeriod(for: Self.iso.date(from: "2026-05-17T12:00:00Z")!)
        XCTAssertEqual(bp2604?.id, "BP26-04")
        XCTAssertEqual(bp2604?.startDateUTC, Self.iso.date(from: "2026-05-17T11:00:00Z"))
        XCTAssertEqual(bp2604?.endDateUTC, Self.iso.date(from: "2026-07-12T11:00:00Z"))

        let bp2701 = bidPeriod(for: Self.iso.date(from: "2026-11-29T12:00:00Z")!)
        XCTAssertEqual(bp2701?.id, "BP27-01")
        XCTAssertEqual(bp2701?.startDateUTC, Self.iso.date(from: "2026-11-29T12:00:00Z"))
        XCTAssertEqual(bp2701?.endDateUTC, Self.iso.date(from: "2027-01-24T12:00:00Z"))

        let bp2707 = bidPeriod(for: Self.iso.date(from: "2027-11-28T12:00:00Z")!)
        XCTAssertEqual(bp2707?.id, "BP27-07")
        XCTAssertEqual(bp2707?.startDateUTC, Self.iso.date(from: "2027-10-31T11:00:00Z"))
        XCTAssertEqual(bp2707?.endDateUTC, Self.iso.date(from: "2027-12-26T12:00:00Z"))
    }

    func test_bidPeriod_usesAnchorage0300Boundary() {
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T10:59:59Z")!)?.id,
            "BP26-03"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T11:00:00Z")!)?.id,
            "BP26-04"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-07-12T10:59:59Z")!)?.id,
            "BP26-04"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-07-12T11:00:00Z")!)?.id,
            "BP26-05"
        )
    }

    func test_bidPeriod_usesDomicile0300Boundary() {
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T06:59:59Z")!, domicile: "SDF")?.id,
            "BP26-03"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T07:00:00Z")!, domicile: "SDF")?.id,
            "BP26-04"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T06:59:59Z")!, domicile: "SDFZ")?.id,
            "BP26-03"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T07:00:00Z")!, domicile: "SDFZ")?.id,
            "BP26-04"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T06:59:59Z")!, domicile: "MIA")?.id,
            "BP26-03"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T07:00:00Z")!, domicile: "MIA")?.id,
            "BP26-04"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T09:59:59Z")!, domicile: "ONT")?.id,
            "BP26-03"
        )
        XCTAssertEqual(
            bidPeriod(for: Self.iso.date(from: "2026-05-17T10:00:00Z")!, domicile: "ONT")?.id,
            "BP26-04"
        )
    }
}

final class ManualOperationalEventTimeRuleTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_ancReserveC_resolvesOvernightStandardTime() throws {
        try assertEvent(
            code: .reserveC,
            base: .anc,
            localDate: localDate(year: 2026, month: 1, day: 15),
            startUTC: "2026-01-16T05:15:00Z",
            endUTC: "2026-01-16T17:14:00Z"
        )
    }

    func test_ontReserveA_resolvesOvernightStandardTime() throws {
        try assertEvent(
            code: .reserveA,
            base: .ont,
            localDate: localDate(year: 2026, month: 1, day: 15),
            startUTC: "2026-01-16T07:00:00Z",
            endUTC: "2026-01-16T18:59:00Z"
        )
    }

    func test_sdfReserveC_resolvesOvernightStandardTime() throws {
        try assertEvent(
            code: .reserveC,
            base: .sdf,
            localDate: localDate(year: 2026, month: 1, day: 15),
            startUTC: "2026-01-15T21:00:00Z",
            endUTC: "2026-01-16T08:59:00Z"
        )
    }

    func test_miaReserveD_resolvesStandardTime() throws {
        try assertEvent(
            code: .reserveD,
            base: .mia,
            localDate: localDate(year: 2026, month: 1, day: 15),
            startUTC: "2026-01-15T10:00:00Z",
            endUTC: "2026-01-15T21:59:00Z"
        )
    }

    func test_rcid_resolvesForSelectedBase() throws {
        try assertEvent(
            code: .rcid,
            base: .sdfz,
            localDate: localDate(year: 2026, month: 1, day: 15),
            startUTC: "2026-01-15T14:00:00Z",
            endUTC: "2026-01-15T18:00:00Z"
        )
    }

    func test_lco_resolvesForSelectedBase() throws {
        try assertEvent(
            code: .lco,
            base: .anc,
            localDate: localDate(year: 2026, month: 1, day: 15),
            startUTC: "2026-01-15T17:00:00Z",
            endUTC: "2026-01-15T23:00:00Z"
        )
    }

    func test_dstBoundary_usesDomicileTimeZoneSemantics() throws {
        try assertEvent(
            code: .rcid,
            base: .sdf,
            localDate: localDate(year: 2025, month: 3, day: 9),
            startUTC: "2025-03-09T13:00:00Z",
            endUTC: "2025-03-09T17:00:00Z"
        )
        try assertEvent(
            code: .rcid,
            base: .sdf,
            localDate: localDate(year: 2025, month: 11, day: 2),
            startUTC: "2025-11-02T14:00:00Z",
            endUTC: "2025-11-02T18:00:00Z"
        )
    }

    func test_sdfAndSdfz_useSameReserveRulesAndTimeZone() throws {
        let localDate = localDate(year: 2026, month: 1, day: 15)
        let sdf = try ManualOperationalEvent(code: .reserveC, crewBase: .sdf, localStartDate: localDate)
        let sdfz = try ManualOperationalEvent(code: .reserveC, crewBase: .sdfz, localStartDate: localDate)

        XCTAssertEqual(sdf.startUTC, sdfz.startUTC)
        XCTAssertEqual(sdf.endUTC, sdfz.endUTC)
    }

    func test_manualOperationalCodes_doNotIncludeDHOrRCIT() {
        let rawCodes = ManualOperationalCode.allCases.map(\.rawValue)

        XCTAssertTrue(rawCodes.contains("RCID"))
        XCTAssertFalse(rawCodes.contains("RCIT"))
        XCTAssertFalse(rawCodes.contains("DH"))
    }

    func test_manualOperationalEvents_areOperationalLayerOnly() throws {
        let event = try ManualOperationalEvent(
            code: .reserveC,
            crewBase: .anc,
            localStartDate: localDate(year: 2026, month: 1, day: 15)
        )

        XCTAssertEqual(event.layer, .operational)
        XCTAssertEqual(event.code.layer, .operational)
    }

    func test_unsupportedBaseReserveAndUnspecifiedCodes_haveNoDefaultTimeRange() {
        let miaRule = CrewBaseRule.rule(for: .mia)
        XCTAssertNil(miaRule.defaultTimeRange(for: .reserveA))
        XCTAssertNil(miaRule.defaultTimeRange(for: .reserveB))

        let ancRule = CrewBaseRule.rule(for: .anc)
        XCTAssertNil(ancRule.defaultTimeRange(for: .hot))
        XCTAssertNil(ancRule.defaultTimeRange(for: .cq12))
        XCTAssertNil(ancRule.defaultTimeRange(for: .cq6))
    }

    func test_operationalSettings_defaultCrewBaseIsANC() throws {
        let defaults = try makeIsolatedDefaults()

        XCTAssertEqual(OperationalSettings.selectedCrewBase(defaults: defaults), .anc)
    }

    func test_operationalSettings_persistsSelectedCrewBase() throws {
        let defaults = try makeIsolatedDefaults()

        OperationalSettings.setSelectedCrewBase(.ont, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: OperationalSettings.crewBaseKey), "ONT")
        XCTAssertEqual(OperationalSettings.selectedCrewBase(defaults: defaults), .ont)
    }

    func test_manualOperationalEvent_canResolveCrewBaseFromSettings() throws {
        let defaults = try makeIsolatedDefaults()
        OperationalSettings.setSelectedCrewBase(.ont, defaults: defaults)

        let event = try ManualOperationalEvent(
            code: .reserveA,
            localStartDate: localDate(year: 2026, month: 1, day: 15),
            defaults: defaults
        )

        XCTAssertEqual(event.crewBase, .ont)
        XCTAssertEqual(event.startUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-16T07:00:00Z")))
        XCTAssertEqual(event.endUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-16T18:59:00Z")))
    }

    func test_manualOperationalEvent_defaultRangeAllowsEditableCrossMidnightEndDate() throws {
        let event = try ManualOperationalEvent(
            code: .reserveC,
            crewBase: .anc,
            localStartDate: localDate(year: 2026, month: 1, day: 15),
            localEndDate: localDate(year: 2026, month: 1, day: 16)
        )

        XCTAssertEqual(event.startUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-16T05:15:00Z")))
        XCTAssertEqual(event.endUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-16T17:14:00Z")))
        XCTAssertGreaterThan(event.endUTC, event.startUTC)
    }

    func test_manualOperationalEvent_autoFillRangeCreatesDailyEventsNotContinuousBar() throws {
        let events = try ManualOperationalEvent.dailyAutoFilledEvents(
            code: .lco,
            crewBase: .anc,
            localStartDate: localDate(year: 2026, month: 1, day: 15),
            localEndDate: localDate(year: 2026, month: 1, day: 17)
        )

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].startUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-15T17:00:00Z")))
        XCTAssertEqual(events[0].endUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-15T23:00:00Z")))
        XCTAssertEqual(events[1].startUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-16T17:00:00Z")))
        XCTAssertEqual(events[1].endUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-16T23:00:00Z")))
        XCTAssertEqual(events[2].startUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-17T17:00:00Z")))
        XCTAssertEqual(events[2].endUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-17T23:00:00Z")))
        XCTAssertLessThan(events[0].endUTC.timeIntervalSince(events[0].startUTC), 24 * 60 * 60)
    }

    func test_manualOperationalEvent_autoFillRangeCreatesCrossMidnightDailyEvents() throws {
        let events = try ManualOperationalEvent.dailyAutoFilledEvents(
            code: .reserveC,
            crewBase: .anc,
            localStartDate: localDate(year: 2026, month: 1, day: 15),
            localEndDate: localDate(year: 2026, month: 1, day: 16)
        )

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].startUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-16T05:15:00Z")))
        XCTAssertEqual(events[0].endUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-16T17:14:00Z")))
        XCTAssertEqual(events[1].startUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-17T05:15:00Z")))
        XCTAssertEqual(events[1].endUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-17T17:14:00Z")))
    }

    func test_manualEventStore_persistsOperationalAndPersonalEvents() throws {
        let defaults = try makeIsolatedDefaults()
        let directory = try makeTemporaryDirectory()
        let store = ManualEventStore(defaults: defaults, directory: directory)
        let operational = try ManualOperationalEvent(
            code: .reserveC,
            crewBase: .anc,
            localStartDate: localDate(year: 2026, month: 1, day: 15)
        )
        let personal = try ManualPersonalEvent(
            code: .medical,
            startUTC: try XCTUnwrap(Self.iso.date(from: "2026-01-15T18:00:00Z")),
            endUTC: try XCTUnwrap(Self.iso.date(from: "2026-01-15T19:00:00Z"))
        )

        try store.save(ManualEventStoreSnapshot(operationalEvents: [operational], personalEvents: [personal]))

        let reloaded = ManualEventStore(defaults: defaults, directory: directory).load()
        XCTAssertEqual(reloaded.operationalEvents, [operational])
        XCTAssertEqual(reloaded.personalEvents, [personal])
    }

    func test_manualEventStore_persistsDailyAutoFilledOperationalEvents() throws {
        let defaults = try makeIsolatedDefaults()
        let directory = try makeTemporaryDirectory()
        let store = ManualEventStore(defaults: defaults, directory: directory)
        let events = try ManualOperationalEvent.dailyAutoFilledEvents(
            code: .lco,
            crewBase: .anc,
            localStartDate: localDate(year: 2026, month: 1, day: 15),
            localEndDate: localDate(year: 2026, month: 1, day: 17)
        )

        try store.save(ManualEventStoreSnapshot(operationalEvents: events, personalEvents: []))

        let reloaded = ManualEventStore(defaults: defaults, directory: directory).load()
        XCTAssertEqual(reloaded.operationalEvents.count, 3)
        XCTAssertEqual(reloaded.operationalEvents.first?.startUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-15T17:00:00Z")))
        XCTAssertEqual(reloaded.operationalEvents.first?.endUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-15T23:00:00Z")))
        XCTAssertEqual(reloaded.operationalEvents.last?.startUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-17T17:00:00Z")))
        XCTAssertEqual(reloaded.operationalEvents.last?.endUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-17T23:00:00Z")))
    }

    func test_manualOperationalAutoFillReplacingOverlapsRemovesOldContinuousDuplicate() throws {
        let oldContinuous = try ManualOperationalEvent(
            code: .reserveA,
            crewBase: .anc,
            localStartDate: localDate(year: 2026, month: 1, day: 15),
            localEndDate: localDate(year: 2026, month: 1, day: 17)
        )
        let dailyEvents = try ManualOperationalEvent.dailyAutoFilledEvents(
            code: .reserveA,
            crewBase: .anc,
            localStartDate: localDate(year: 2026, month: 1, day: 15),
            localEndDate: localDate(year: 2026, month: 1, day: 17)
        )

        let merged = mergeManualOperationalEventsReplacingOverlaps(
            existing: [oldContinuous],
            replacements: dailyEvents
        )

        XCTAssertEqual(merged.count, 3)
        XCTAssertFalse(merged.contains { $0.id == oldContinuous.id })
        XCTAssertEqual(merged.map(\.startUTC), dailyEvents.map(\.startUTC))
    }

    func test_manualOperationalAutoFillReplacingOverlapsKeepsDifferentCodeOrBase() throws {
        let sameDayLCO = try ManualOperationalEvent(
            code: .lco,
            crewBase: .anc,
            localStartDate: localDate(year: 2026, month: 1, day: 15)
        )
        let differentBaseRSVA = try ManualOperationalEvent(
            code: .reserveA,
            crewBase: .ont,
            localStartDate: localDate(year: 2026, month: 1, day: 15)
        )
        let dailyEvents = try ManualOperationalEvent.dailyAutoFilledEvents(
            code: .reserveA,
            crewBase: .anc,
            localStartDate: localDate(year: 2026, month: 1, day: 15),
            localEndDate: localDate(year: 2026, month: 1, day: 17)
        )

        let merged = mergeManualOperationalEventsReplacingOverlaps(
            existing: [sameDayLCO, differentBaseRSVA],
            replacements: dailyEvents
        )

        XCTAssertEqual(merged.count, 5)
        XCTAssertTrue(merged.contains(sameDayLCO))
        XCTAssertTrue(merged.contains(differentBaseRSVA))
    }

    func test_manualEventSnapshotMerge_tombstonePreventsDeletedOperationalEventResurrection() throws {
        let eventID = UUID()
        let createdAt = try XCTUnwrap(Self.iso.date(from: "2026-01-15T10:00:00Z"))
        let deletedAt = try XCTUnwrap(Self.iso.date(from: "2026-01-15T11:00:00Z"))
        let staleRemoteEvent = try ManualOperationalEvent(
            id: eventID,
            code: .reserveA,
            crewBase: .anc,
            startUTC: try XCTUnwrap(Self.iso.date(from: "2026-01-15T16:30:00Z")),
            endUTC: try XCTUnwrap(Self.iso.date(from: "2026-01-16T04:29:00Z")),
            createdAt: createdAt,
            updatedAt: createdAt
        )

        let merged = mergeManualEventSnapshots(
            local: ManualEventStoreSnapshot(
                operationalEvents: [],
                personalEvents: [],
                tombstones: [ManualEventTombstone(id: eventID, deletedAt: deletedAt)]
            ),
            remote: ManualEventStoreSnapshot(
                operationalEvents: [staleRemoteEvent],
                personalEvents: [],
                tombstones: []
            )
        )

        XCTAssertTrue(merged.operationalEvents.isEmpty)
        XCTAssertEqual(merged.tombstones, [ManualEventTombstone(id: eventID, deletedAt: deletedAt)])
    }

    func test_manualEventSnapshotMerge_newerEventSurvivesOlderTombstone() throws {
        let eventID = UUID()
        let deletedAt = try XCTUnwrap(Self.iso.date(from: "2026-01-15T10:00:00Z"))
        let updatedAt = try XCTUnwrap(Self.iso.date(from: "2026-01-15T11:00:00Z"))
        let newerRemoteEvent = try ManualOperationalEvent(
            id: eventID,
            code: .lco,
            crewBase: .anc,
            startUTC: try XCTUnwrap(Self.iso.date(from: "2026-01-15T17:00:00Z")),
            endUTC: try XCTUnwrap(Self.iso.date(from: "2026-01-15T23:00:00Z")),
            createdAt: updatedAt,
            updatedAt: updatedAt
        )

        let merged = mergeManualEventSnapshots(
            local: ManualEventStoreSnapshot(
                operationalEvents: [],
                personalEvents: [],
                tombstones: [ManualEventTombstone(id: eventID, deletedAt: deletedAt)]
            ),
            remote: ManualEventStoreSnapshot(
                operationalEvents: [newerRemoteEvent],
                personalEvents: [],
                tombstones: []
            )
        )

        XCTAssertEqual(merged.operationalEvents, [newerRemoteEvent])
        XCTAssertEqual(merged.tombstones, [ManualEventTombstone(id: eventID, deletedAt: deletedAt)])
    }

    func test_manualOperationalEvent_allowsExplicitTimesForCodesWithoutDefaultRange() throws {
        let startUTC = try XCTUnwrap(Self.iso.date(from: "2026-01-15T18:00:00Z"))
        let endUTC = try XCTUnwrap(Self.iso.date(from: "2026-01-15T20:00:00Z"))

        let event = try ManualOperationalEvent(
            code: .hot,
            crewBase: .anc,
            startUTC: startUTC,
            endUTC: endUTC
        )

        XCTAssertEqual(event.code, .hot)
        XCTAssertEqual(event.startUTC, startUTC)
        XCTAssertEqual(event.endUTC, endUTC)
        XCTAssertEqual(event.layer, .operational)
    }

    private func assertEvent(
        code: ManualOperationalCode,
        base: CrewBase,
        localDate: DateComponents,
        startUTC: String,
        endUTC: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let event = try ManualOperationalEvent(code: code, crewBase: base, localStartDate: localDate)

        XCTAssertEqual(event.startUTC, try XCTUnwrap(Self.iso.date(from: startUTC)), file: file, line: line)
        XCTAssertEqual(event.endUTC, try XCTUnwrap(Self.iso.date(from: endUTC)), file: file, line: line)
        XCTAssertGreaterThan(event.endUTC, event.startUTC, file: file, line: line)
    }

    private func localDate(year: Int, month: Int, day: Int) -> DateComponents {
        DateComponents(year: year, month: month, day: day)
    }

    private func makeIsolatedDefaults(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UserDefaults {
        let suiteName = "ManualOperationalEventTimeRuleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualOperationalEventTimeRuleTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

final class OpenTimeSectionBuilderTests: XCTestCase {
    func test_openTimePPLabel_usesLegUTCBeforeDomicile0300Boundary() {
        let trip = openTimeTrip(
            payPeriod: "PP_TRIPBOARD_FALLBACK",
            pairing: "OT-early",
            startLocal: "2026-05-17 02:59",
            depUTC: "2026-05-17T06:59:00Z"
        )
        let sections = OpenTimeSectionBuilder.build(
            schedules: [schedule(id: "OT", label: "PP_TRIPBOARD_FALLBACK", legs: [], openTimeTrips: [trip])],
            domicile: "SDF"
        )

        XCTAssertEqual(sections.map { $0.label }, ["PP26-05"])
    }

    func test_openTimePPLabel_usesLegUTCAtDomicile0300Boundary() {
        let trip = openTimeTrip(
            payPeriod: "PP_TRIPBOARD_FALLBACK",
            pairing: "OT-boundary",
            startLocal: "2026-05-17 03:00",
            depUTC: "2026-05-17T07:00:00Z"
        )
        let sections = OpenTimeSectionBuilder.build(
            schedules: [schedule(id: "OT", label: "PP_TRIPBOARD_FALLBACK", legs: [], openTimeTrips: [trip])],
            domicile: "SDF"
        )

        XCTAssertEqual(sections.map { $0.label }, ["PP26-06"])
    }
}

final class CalendarNormalizationTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_normalizeCalendarTrips_groupsByPayPeriodAndPairing() {
        let schedules = [
            schedule(
                id: "A",
                label: "PP26-04",
                legs: [
                    leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-22T02:00:00Z", arrUTC: "2026-03-22T05:00:00Z"),
                    leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X2", depAirport: "SDF", arrAirport: "ANC", depUTC: "2026-03-22T07:00:00Z", arrUTC: "2026-03-22T10:00:00Z")
                ]
            ),
            schedule(
                id: "B",
                label: "PP26-05",
                legs: [
                    leg(payPeriod: "PP26-05", pairing: "1234", flight: "5X3", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-04-19T02:00:00Z", arrUTC: "2026-04-19T05:00:00Z")
                ],
                openTimeTrips: [openTimeTrip(payPeriod: "PP26-05", pairing: "OT100")]
            )
        ]

        let trips = normalizeCalendarTrips(from: schedules)
        XCTAssertEqual(trips.map(\.id), ["PP26-04|1234", "PP26-05|1234"])
    }

    func test_normalizeCalendarTrips_sortsLegsByUTCDeparture() throws {
        let schedules = [
            schedule(
                id: "A",
                label: "PP26-04",
                legs: [
                    leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X2", depAirport: "SDF", arrAirport: "ANC", depUTC: "2026-03-22T07:00:00Z", arrUTC: "2026-03-22T10:00:00Z", legNumber: 2),
                    leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-22T02:00:00Z", arrUTC: "2026-03-22T05:00:00Z", legNumber: 1)
                ]
            )
        ]

        let trip = try XCTUnwrap(normalizeCalendarTrips(from: schedules).first)
        XCTAssertEqual(trip.legs.map(\.flight), ["5X1", "5X2"])
        XCTAssertEqual(trip.startUTC, Self.iso.date(from: "2026-03-22T02:00:00Z"))
        XCTAssertEqual(trip.endUTC, Self.iso.date(from: "2026-03-22T10:00:00Z"))
    }

    func test_normalizeCalendarTrips_excludesMalformedTrips() {
        let schedules = [
            schedule(
                id: "A",
                label: "PP26-04",
                legs: [
                    leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: nil, arrUTC: "2026-03-22T05:00:00Z")
                ]
            )
        ]

        XCTAssertTrue(normalizeCalendarTrips(from: schedules).isEmpty)
    }

    func test_normalizeCalendarTrips_excludesOpenTimeTrips() {
        let schedules = [
            schedule(
                id: "A",
                label: "PP26-04",
                legs: [],
                openTimeTrips: [openTimeTrip(payPeriod: "PP26-04", pairing: "OT100")]
            )
        ]

        XCTAssertTrue(normalizeCalendarTrips(from: schedules).isEmpty)
    }
}

final class CalendarVisibilityTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_visibleTrips_includesPartialOverlapAtStart() {
        let bidPeriod = makeBidPeriod(startUTC: "2026-03-22T00:00:00Z")
        let trip = calendarTrip(
            id: "PP26-04|1234",
            pairing: "1234",
            payPeriod: "PP26-04",
            legs: [],
            startUTC: "2026-03-21T23:00:00Z",
            endUTC: "2026-03-22T02:00:00Z"
        )

        XCTAssertEqual(visibleTrips(in: bidPeriod, trips: [trip]).map(\.id), [trip.id])
    }

    func test_visibleTrips_includesPartialOverlapAtEnd() {
        let bidPeriod = makeBidPeriod(startUTC: "2026-03-22T00:00:00Z")
        let trip = calendarTrip(
            id: "PP26-04|1234",
            pairing: "1234",
            payPeriod: "PP26-04",
            legs: [],
            startUTC: "2026-05-16T23:00:00Z",
            endUTC: "2026-05-17T02:00:00Z"
        )

        XCTAssertEqual(visibleTrips(in: bidPeriod, trips: [trip]).map(\.id), [trip.id])
    }

    func test_visibleTrips_excludesFullyOutsideTrips() {
        let bidPeriod = makeBidPeriod(startUTC: "2026-03-22T00:00:00Z")
        let trip = calendarTrip(
            id: "PP26-04|1234",
            pairing: "1234",
            payPeriod: "PP26-04",
            legs: [],
            startUTC: "2026-05-17T00:00:00Z",
            endUTC: "2026-05-17T02:00:00Z"
        )

        XCTAssertTrue(visibleTrips(in: bidPeriod, trips: [trip]).isEmpty)
    }
}

final class CalendarLocalHelperTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_resolveDayIndex_usesProvidedTimeZoneDeterministically() throws {
        let days = generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!)
        let utcDate = Self.iso.date(from: "2026-03-22T01:00:00Z")!
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let anchorage = try XCTUnwrap(TimeZone(identifier: "America/Anchorage"))

        XCTAssertEqual(resolveDayIndex(for: utcDate, timeZone: tokyo, calendarDays: days), 0)
        XCTAssertEqual(resolveDayIndex(for: utcDate, timeZone: anchorage, calendarDays: days), 0)
        XCTAssertEqual(resolveDayIndex(for: utcDate, timeZone: tokyo, calendarDays: days), resolveDayIndex(for: utcDate, timeZone: tokyo, calendarDays: days))
    }

    func test_dayKey_and_fractionHelpers_useStructuredLocalTime() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let utcDate = Self.iso.date(from: "2026-03-22T12:30:45Z")!

        XCTAssertEqual(dayKey(from: utcDate, timeZone: tokyo), "2026-03-22")
        XCTAssertEqual(localComponents(for: utcDate, timeZone: tokyo).hour, 21)
        XCTAssertEqual(startFraction(for: utcDate, timeZone: tokyo), (21 + (30.0 / 60) + (45.0 / 3600)) / 24, accuracy: 0.000001)
        XCTAssertEqual(endFraction(for: utcDate, timeZone: tokyo), startFraction(for: utcDate, timeZone: tokyo), accuracy: 0.000001)
    }

    func test_fractionHelpers_clampToZeroThroughOne() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let utcDate = Self.iso.date(from: "2026-03-22T23:59:59Z")!
        XCTAssertLessThanOrEqual(startFraction(for: utcDate, timeZone: utc), 1)
        XCTAssertGreaterThanOrEqual(startFraction(for: utcDate, timeZone: utc), 0)
    }
}

final class CalendarRegressionMetadataTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_localRegressionMetadata_sameTimezoneNormalTrip_hasNoRegression() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-22T14:00:00Z", arrUTC: "2026-03-22T20:00:00Z")
            ]
        )

        XCTAssertTrue(localRegressionMetadata(for: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!)).isEmpty)
    }

    func test_localRegressionMetadata_sameTimezoneOvernightTrip_isNotRegression() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "SDF", arrAirport: "SDF", depUTC: "2026-03-22T03:00:00Z", arrUTC: "2026-03-22T10:00:00Z")
            ]
        )

        XCTAssertTrue(localRegressionMetadata(for: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!)).isEmpty)
    }

    func test_localRegressionMetadata_domicileForwardCase_hasNoRegression() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                // ANC dep wall time = 06:00, arrival in ANC domicile time = 12:00.
                // The visual end is not after actual domicile arrival, so no orange cue.
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-22T14:00:00Z", arrUTC: "2026-03-22T20:00:00Z")
            ]
        )

        let metadata = localRegressionMetadata(for: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertTrue(metadata.isEmpty)
    }

    func test_localRegressionMetadata_dateLineStyleCase_detectsRegression() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "NRT", arrAirport: "ANC", depUTC: "2026-03-22T06:00:00Z", arrUTC: "2026-03-22T09:00:00Z")
            ]
        )

        let metadata = localRegressionMetadata(for: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertFalse(metadata.isEmpty)
    }

    func test_localRegressionMetadata_previousLocalDateWithLaterClock_detectsRegression() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                // ICN local dep = Mar 23 07:00, ANC local arr = Mar 22 22:00.
                // The clock number is later, but the displayed local date moves backward.
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ICN", arrAirport: "ANC", depUTC: "2026-03-22T22:00:00Z", arrUTC: "2026-03-23T06:00:00Z")
            ]
        )

        let metadata = localRegressionMetadata(for: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertFalse(metadata.isEmpty)
    }

    func test_localRegressionMetadata_intermediateRegressionOnly_isIgnored() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "NRT", arrAirport: "ANC", depUTC: "2026-03-22T06:00:00Z", arrUTC: "2026-03-22T09:00:00Z", legNumber: 1),
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X2", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-22T14:00:00Z", arrUTC: "2026-03-22T20:00:00Z", legNumber: 2)
            ]
        )

        let metadata = localRegressionMetadata(for: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertTrue(metadata.isEmpty)
    }

    func test_localRegressionMetadata_dstBoundaryDoesNotBreakUTCOrdering() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "SDF", arrAirport: "SDF", depUTC: "2026-03-08T06:30:00Z", arrUTC: "2026-03-08T09:30:00Z")
            ]
        )

        XCTAssertTrue(localRegressionMetadata(for: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-08T00:00:00Z")!)).isEmpty)
        XCTAssertLessThan(trip.startUTC, trip.endUTC)
    }
}

final class CalendarSegmentationTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_buildSegments_oneDayTrip() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-22T18:00:00Z", arrUTC: "2026-03-22T23:00:00Z")
            ]
        )

        let segments = buildSegments(trip: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertEqual(segments.count, 1)
        XCTAssertLessThanOrEqual(segments[0].startFraction, segments[0].endFraction)
    }

    func test_buildSegments_overnightTrip() {
        // Calendar cells are Domicile-local days, independent from the 03:00 BP/PP
        // operational boundary. For SDF domicile, this leg crosses local midnight.
        // SDF = EDT (UTC-4): dep = 19:00 local, arr = 02:00 local next day.
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "SDF", arrAirport: "SDF", depUTC: "2026-03-22T23:00:00Z", arrUTC: "2026-03-23T06:00:00Z")
            ]
        )

        let segments = buildSegments(
            trip: trip,
            days: generateBidPeriodDays(
                startUTC: Self.iso.date(from: "2026-03-22T07:00:00Z")!,
                payPeriodCount: 2,
                domicile: "SDF"
            )
        )
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].endFraction, 1, accuracy: 0.000001)
        XCTAssertEqual(segments[1].startFraction, 0, accuracy: 0.000001)
    }

    func test_buildSegments_multiDayTrip() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-22T18:00:00Z", arrUTC: "2026-03-24T12:00:00Z")
            ]
        )

        let segments = buildSegments(trip: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[1].startFraction, 0, accuracy: 0.000001)
        XCTAssertEqual(segments[1].endFraction, 1, accuracy: 0.000001)
    }

    func test_buildSegments_weekCrossingTrip() {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-28T18:00:00Z", arrUTC: "2026-03-30T12:00:00Z")
            ]
        )

        let segments = buildSegments(trip: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertEqual(segments.map(\.weekIndex), [1, 1, 1])
    }

    func test_buildSegments_tinySegmentNearMidnight() {
        // A 2-minute flight spanning ANC domicile midnight crosses a calendar day
        // boundary, producing two tiny segments even though the duration is negligible.
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "ANC", depUTC: "2026-03-22T07:59:00Z", arrUTC: "2026-03-22T08:01:00Z")
            ]
        )

        let segments = buildSegments(trip: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertEqual(segments.count, 2)
    }

    func test_buildSegments_manualOperationalEventSplitsAcrossLocalMidnight() throws {
        let event = try ManualOperationalEvent(
            code: .reserveC,
            crewBase: .anc,
            localStartDate: DateComponents(year: 2026, month: 1, day: 15)
        )
        let days = generateBidPeriodDays(
            startUTC: Self.iso.date(from: "2026-01-15T09:00:00Z")!,
            payPeriodCount: 1,
            domicile: "ANC"
        )

        let segments = buildSegments(event: event, days: days)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].tripID, manualOperationalSegmentID(for: event))
        XCTAssertEqual(segments[0].dayIndex, 0)
        XCTAssertEqual(segments[0].startFraction, (20.0 + 15.0 / 60.0) / 24.0, accuracy: 0.000001)
        XCTAssertEqual(segments[0].endFraction, 1, accuracy: 0.000001)
        XCTAssertEqual(segments[1].dayIndex, 1)
        XCTAssertEqual(segments[1].startFraction, 0, accuracy: 0.000001)
        XCTAssertEqual(segments[1].endFraction, (8.0 + 14.0 / 60.0) / 24.0, accuracy: 0.000001)
        XCTAssertFalse(segments.contains { $0.hasLocalTimeRegression })
    }

    func test_visibleManualOperationalEventsIncludesPartialOverlapOnly() throws {
        let bidPeriod = makeBidPeriod(startUTC: "2026-01-15T09:00:00Z")
        let overlapping = try ManualOperationalEvent(
            code: .lco,
            crewBase: .anc,
            startUTC: Self.iso.date(from: "2026-01-16T17:00:00Z")!,
            endUTC: Self.iso.date(from: "2026-01-16T23:00:00Z")!
        )
        let outside = try ManualOperationalEvent(
            code: .lco,
            crewBase: .anc,
            startUTC: Self.iso.date(from: "2026-03-20T17:00:00Z")!,
            endUTC: Self.iso.date(from: "2026-03-20T23:00:00Z")!
        )

        XCTAssertEqual(visibleManualOperationalEvents(in: bidPeriod, events: [overlapping, outside]), [overlapping])
    }

    func test_buildSegments_finalLegRegressionExtendsToDepartureWallClockInDomicileCell() throws {
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                // HKG dep wall time = Apr 29 19:38. ANC arrival = Apr 29 13:07.
                // The bar should remain on the ANC Apr 29 cell, blue through 13:07,
                // and orange from 13:07 to the unconverted HKG wall-clock 19:38.
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "HKG", arrAirport: "ANC", depUTC: "2026-04-29T11:38:00Z", arrUTC: "2026-04-29T21:07:00Z")
            ]
        )

        let segments = buildSegments(trip: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-04-29T08:00:00Z")!))
        let segment = try XCTUnwrap(segments.first)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segment.startFraction, (3.0 + 38.0 / 60.0) / 24.0, accuracy: 0.000001)
        XCTAssertEqual(segment.endFraction, (19.0 + 38.0 / 60.0) / 24.0, accuracy: 0.000001)
        XCTAssertTrue(segment.hasLocalTimeRegression)
        let range = try XCTUnwrap(segment.regressedRange)
        XCTAssertEqual(range.lowerBound, (13.0 + 7.0 / 60.0) / 24.0, accuracy: 0.000001)
        XCTAssertEqual(range.upperBound, (19.0 + 38.0 / 60.0) / 24.0, accuracy: 0.000001)
    }

    // MARK: - Carry-in / carry-out across BP boundaries

    /// A trip whose departure is in the previous BP but whose arrival lands inside
    /// the displayed BP must produce a partial bar starting at the left edge of the
    /// first visible day, not be dropped entirely.
    func test_buildSegments_tripCarriesInFromPreviousBP() {
        // Displayed BP starts March 22 UTC; trip departed March 20 (2 days earlier)
        // and arrives March 23 12:00 UTC (well inside the displayed BP).
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-03-20T18:00:00Z", arrUTC: "2026-03-23T12:00:00Z")
            ]
        )

        let segments = buildSegments(trip: trip, days: generateBidPeriodDays(startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!))
        XCTAssertFalse(segments.isEmpty, "Carry-in trip must produce at least one segment")
        let first = segments.min { $0.dayIndex < $1.dayIndex }
        XCTAssertEqual(first?.dayIndex, 0)
        XCTAssertEqual(first?.startFraction ?? -1, 0, accuracy: 0.000001,
                       "First visible day for a carry-in trip starts at the cell's left edge")
    }

    /// A trip that starts inside the displayed BP but whose arrival is in the next
    /// BP must extend its final visible-day segment all the way to the right edge.
    func test_buildSegments_tripCarriesOutIntoNextBP() {
        // Displayed BP is the 28-day grid starting March 22 UTC (day index 0..27).
        // Trip departs April 17 12:00 UTC (day 26) and arrives April 22 (past end).
        let trip = makeTrip(
            payPeriod: "PP26-04",
            pairing: "1234",
            legs: [
                leg(payPeriod: "PP26-04", pairing: "1234", flight: "5X1", depAirport: "ANC", arrAirport: "SDF", depUTC: "2026-04-17T12:00:00Z", arrUTC: "2026-04-22T12:00:00Z")
            ]
        )

        let days = generateBidPeriodDays(
            startUTC: Self.iso.date(from: "2026-03-22T00:00:00Z")!,
            payPeriodCount: 1
        )
        let segments = buildSegments(trip: trip, days: days)
        XCTAssertFalse(segments.isEmpty, "Carry-out trip must produce at least one segment")
        let last = segments.max { $0.dayIndex < $1.dayIndex }
        XCTAssertNotNil(last)
        // BP has 28 days (indices 0..27); trip extends past day 27 so the final
        // visible segment must reach the right edge.
        XCTAssertEqual(last?.dayIndex, 27)
        XCTAssertEqual(last?.endFraction ?? -1, 1, accuracy: 0.000001,
                       "Last visible day for a carry-out trip ends at the cell's right edge")
    }
}

final class CalendarLaneAllocationTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_assignLanes_separatesOverlappingSegments() {
        let segments = assignLanes(to: [
            segment(tripID: "A", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0.1, endFraction: 0.5),
            segment(tripID: "B", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T02:00:00Z", startFraction: 0.2, endFraction: 0.6)
        ])

        XCTAssertNotEqual(segments[0].lane, segments[1].lane)
    }

    func test_assignLanes_handlesIdenticalStartTimesDeterministically() {
        let source = [
            segment(tripID: "A", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0.1, endFraction: 0.4),
            segment(tripID: "B", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0.1, endFraction: 0.3)
        ]

        XCTAssertEqual(assignLanes(to: source), assignLanes(to: source))
    }

    func test_assignLanes_sameTripPrefersSameLane() {
        let segments = assignLanes(to: [
            segment(tripID: "A", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0.1, endFraction: 0.2),
            segment(tripID: "A", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T03:00:00Z", startFraction: 0.3, endFraction: 0.4)
        ])

        XCTAssertEqual(segments[0].lane, segments[1].lane)
    }

    func test_assignLanes_isDeterministicAcrossRepeatedRuns() {
        let source = [
            segment(tripID: "B", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T02:00:00Z", startFraction: 0.2, endFraction: 0.4),
            segment(tripID: "A", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0.8, endFraction: 0.9),
            segment(tripID: "C", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T03:00:00Z", startFraction: 0.1, endFraction: 0.5)
        ]

        XCTAssertEqual(assignLanes(to: source), assignLanes(to: source))
    }

    func test_assignLanes_sortsBySegmentStartUTC_notStartFraction() {
        let assigned = assignLanes(to: [
            segment(tripID: "LateUTC", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T03:00:00Z", startFraction: 0.1, endFraction: 0.2),
            segment(tripID: "EarlyUTC", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0.9, endFraction: 1.0)
        ])

        XCTAssertEqual(assigned.first?.tripID, "EarlyUTC")
    }
}

final class CalendarLayerRegressionHardeningTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_bidAndPersonalSameDay_usesBidRepresentativeWithOverflow() throws {
        let day = try makeDay(startUTC: "2026-01-15T00:00:00Z")
        let personal = try ManualPersonalEvent(
            code: .medical,
            startUTC: day.dayStartUTC.addingTimeInterval(60 * 60),
            endUTC: day.dayStartUTC.addingTimeInterval(2 * 60 * 60)
        )
        let bid = CalendarStackItem(
            id: "vto-close",
            title: "VTO Bid Close BP26-02",
            compactTitle: "VTO BID CLOSE",
            layer: .bid
        )

        let summary = try XCTUnwrap(calendarStackSummary(
            bidItems: [bid],
            personalItems: manualPersonalStackItems(for: day, events: [personal])
        ))

        XCTAssertEqual(summary.representative, bid)
        XCTAssertEqual(summary.overflowCount, 1)
        XCTAssertEqual(summary.items.map(\.layer), [.bid, .personal])
    }

    func test_personalOnlyDay_usesPersonalRepresentative() throws {
        let day = try makeDay(startUTC: "2026-01-15T00:00:00Z")
        let personal = try ManualPersonalEvent(
            code: .other,
            startUTC: day.dayStartUTC.addingTimeInterval(60 * 60),
            endUTC: day.dayStartUTC.addingTimeInterval(2 * 60 * 60)
        )

        let summary = try XCTUnwrap(calendarStackSummary(
            bidItems: [],
            personalItems: manualPersonalStackItems(for: day, events: [personal])
        ))

        XCTAssertEqual(summary.representative.compactTitle, "OTHER")
        XCTAssertEqual(summary.representative.layer, .personal)
        XCTAssertEqual(summary.overflowCount, 0)
    }

    func test_manualOperationalSameDay_staysOperationalLaneOnly() throws {
        let bidPeriod = makeBidPeriod(startUTC: "2026-01-15T09:00:00Z")
        let event = try ManualOperationalEvent(
            code: .rcid,
            crewBase: .anc,
            startUTC: try XCTUnwrap(Self.iso.date(from: "2026-01-15T18:00:00Z")),
            endUTC: try XCTUnwrap(Self.iso.date(from: "2026-01-15T22:00:00Z"))
        )

        let segments = visibleManualOperationalEvents(in: bidPeriod, events: [event])
            .flatMap { buildSegments(event: $0, days: bidPeriod.days) }
        let stack = calendarStackSummary(bidItems: [], personalItems: [])

        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(segments.allSatisfy { $0.tripID == manualOperationalSegmentID(for: event) })
        XCTAssertNil(stack)
    }

    func test_deletePersonal_updatesStackCount() throws {
        let day = try makeDay(startUTC: "2026-01-15T00:00:00Z")
        let deletedID = UUID()
        let deleted = try ManualPersonalEvent(
            id: deletedID,
            code: .medical,
            startUTC: day.dayStartUTC.addingTimeInterval(60 * 60),
            endUTC: day.dayStartUTC.addingTimeInterval(2 * 60 * 60)
        )
        let kept = try ManualPersonalEvent(
            code: .commute,
            startUTC: day.dayStartUTC.addingTimeInterval(3 * 60 * 60),
            endUTC: day.dayStartUTC.addingTimeInterval(4 * 60 * 60)
        )

        let before = manualPersonalStackItems(for: day, events: [deleted, kept])
        let after = manualPersonalStackItems(for: day, events: [deleted, kept].filter { $0.id != deletedID })

        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.manualPersonalEventID, kept.id)
    }

    func test_deleteOperational_updatesOperationalLaneSegments() throws {
        let bidPeriod = makeBidPeriod(startUTC: "2026-01-15T09:00:00Z")
        let deletedID = UUID()
        let deleted = try ManualOperationalEvent(
            id: deletedID,
            code: .lco,
            crewBase: .anc,
            startUTC: try XCTUnwrap(Self.iso.date(from: "2026-01-15T17:00:00Z")),
            endUTC: try XCTUnwrap(Self.iso.date(from: "2026-01-15T23:00:00Z"))
        )

        let before = visibleManualOperationalEvents(in: bidPeriod, events: [deleted])
            .flatMap { buildSegments(event: $0, days: bidPeriod.days) }
        let after = visibleManualOperationalEvents(in: bidPeriod, events: [deleted].filter { $0.id != deletedID })
            .flatMap { buildSegments(event: $0, days: bidPeriod.days) }

        XCTAssertFalse(before.isEmpty)
        XCTAssertTrue(after.isEmpty)
    }

    func test_crewBaseChangeDoesNotRecalculateExistingManualOperationalEvent() throws {
        let defaults = try makeIsolatedDefaults()
        OperationalSettings.setSelectedCrewBase(.anc, defaults: defaults)
        let event = try ManualOperationalEvent(
            code: .reserveC,
            localStartDate: DateComponents(year: 2026, month: 1, day: 15),
            defaults: defaults
        )

        OperationalSettings.setSelectedCrewBase(.ont, defaults: defaults)

        XCTAssertEqual(event.crewBase, .anc)
        XCTAssertEqual(event.startUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-16T05:15:00Z")))
        XCTAssertEqual(event.endUTC, try XCTUnwrap(Self.iso.date(from: "2026-01-16T17:14:00Z")))
    }

    func test_rcidSpellingRemainsFixedInOperationalCodesAndTimelineEntryIDs() throws {
        let event = try ManualOperationalEvent(
            code: .rcid,
            crewBase: .anc,
            startUTC: try XCTUnwrap(Self.iso.date(from: "2026-01-15T18:00:00Z")),
            endUTC: try XCTUnwrap(Self.iso.date(from: "2026-01-15T22:00:00Z"))
        )

        XCTAssertEqual(event.code.rawValue, "RCID")
        XCTAssertFalse(ManualOperationalCode.allCases.map(\.rawValue).contains("RCIT"))
        XCTAssertEqual(TimelineDutyEntry.manualOperational(event).id, "manual-operational-\(event.id.uuidString)")
    }

    private func makeDay(startUTC: String) throws -> CalendarDay {
        try XCTUnwrap(generateBidPeriodDays(startUTC: try XCTUnwrap(Self.iso.date(from: startUTC))).first)
    }

    private func makeIsolatedDefaults(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UserDefaults {
        let suiteName = "CalendarLayerRegressionHardeningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

final class CalendarGeometryTests: XCTestCase {
    func test_frameForSegment_mapsHorizontalBoundsCorrectly() {
        let rect = frameForSegment(
            segment(tripID: "A", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0.25, endFraction: 0.75),
            dayFrame: CGRect(x: 10, y: 20, width: 200, height: 40),
            laneHeight: 12,
            laneSpacing: 4
        )

        XCTAssertEqual(rect.minX, 60, accuracy: 0.000001)
        XCTAssertEqual(rect.width, 100, accuracy: 0.000001)
    }

    func test_frameForSegment_usesLaneSpacingInVerticalPosition() {
        let rect = frameForSegment(
            segment(tripID: "A", dayIndex: 0, weekIndex: 0, startUTC: "2026-03-22T01:00:00Z", startFraction: 0, endFraction: 1, lane: 2),
            dayFrame: CGRect(x: 0, y: 20, width: 100, height: 40),
            laneHeight: 10,
            laneSpacing: 3
        )

        XCTAssertEqual(rect.minY, 46, accuracy: 0.000001)
    }
}

final class TimelinePastStateSupportTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_flightRowIsPastAfterArrivalEvenDuringFollowingLayover() {
        let departure = Self.iso.date(from: "2026-05-16T08:48:00Z")!
        let arrival = Self.iso.date(from: "2026-05-16T18:12:00Z")!
        let honoluluAfternoonAfterArrival = Self.iso.date(from: "2026-05-17T02:11:00Z")!

        XCTAssertTrue(
            TimelinePastStateSupport.isPastFlightRow(
                arrivalUTC: arrival,
                departureUTC: departure,
                now: honoluluAfternoonAfterArrival
            )
        )
    }

    func test_flightRowIsNotPastBeforeArrival() {
        let departure = Self.iso.date(from: "2026-05-16T08:48:00Z")!
        let arrival = Self.iso.date(from: "2026-05-16T18:12:00Z")!
        let beforeArrival = Self.iso.date(from: "2026-05-16T17:59:00Z")!

        XCTAssertFalse(
            TimelinePastStateSupport.isPastFlightRow(
                arrivalUTC: arrival,
                departureUTC: departure,
                now: beforeArrival
            )
        )
    }
}

final class TimelineChronologySupportTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    func test_timelineLegData_includesManualOperationalEventsAsDutyEntries() throws {
        let event = try ManualOperationalEvent(
            code: .reserveC,
            crewBase: .anc,
            localStartDate: DateComponents(year: 2026, month: 1, day: 15)
        )

        let data = TimelineLegData(
            schedules: [],
            manualOperationalEvents: [event],
            now: Self.iso.date(from: "2026-01-15T12:00:00Z")!
        )

        XCTAssertEqual(data.daySections.count, 1)
        XCTAssertEqual(data.daySections[0].id, "2026-01-15")
        XCTAssertEqual(data.daySections[0].legs.count, 0)
        XCTAssertEqual(data.daySections[0].entries.count, 1)
        if case .manualOperational(let entryEvent) = data.daySections[0].entries[0] {
            XCTAssertEqual(entryEvent, event)
        } else {
            XCTFail("Manual operational event should remain an operational chronology entry")
        }
    }

    func test_timelineLegData_sortsFlightsAndManualOperationalEventsByUTC() throws {
        let flight = leg(
            payPeriod: "PP26-01",
            pairing: "1234",
            flight: "5X1",
            depAirport: "ANC",
            arrAirport: "SDF",
            depUTC: "2026-01-15T19:00:00Z",
            arrUTC: "2026-01-16T03:00:00Z"
        )
        let event = try ManualOperationalEvent(
            code: .rcid,
            crewBase: .anc,
            startUTC: Self.iso.date(from: "2026-01-15T18:00:00Z")!,
            endUTC: Self.iso.date(from: "2026-01-15T22:00:00Z")!
        )
        let tripSchedule = schedule(id: "schedule", label: "PP26-01", legs: [flight])

        let data = TimelineLegData(
            schedules: [tripSchedule],
            manualOperationalEvents: [event],
            now: Self.iso.date(from: "2026-01-15T12:00:00Z")!
        )

        let entries = data.daySections.flatMap(\.entries)
        XCTAssertEqual(entries.count, 2)
        if case .manualOperational = entries[0] {
            // Expected first.
        } else {
            XCTFail("Manual RCID starts before the flight and should sort first")
        }
        if case .leg(let entryLeg) = entries[1] {
            XCTAssertEqual(entryLeg.id, flight.id)
        } else {
            XCTFail("Flight should remain in chronology after the manual duty")
        }
    }

    /// Bid-period definitions are a hardcoded table that must be extended by hand.
    /// When the table runs out, the calendar silently returns nil for every lookup
    /// and the BP/PP UI stops working. This test fails ~90 days before the horizon
    /// so a release goes red while there is still time to add the next year's table.
    func test_bidPeriodDefinitions_coverAtLeastNinetyDaysAhead() {
        let ninetyDaysAhead = Date().addingTimeInterval(90 * 24 * 60 * 60)
        for domicile in ["ANC", "SDF"] {
            XCTAssertNotNil(
                bidPeriod(for: ninetyDaysAhead, domicile: domicile),
                """
                Bid-period table covers less than 90 days ahead for \(domicile). \
                Append the next bid periods to bidPeriodDefinitions in BidPeriodService.swift \
                (and the matching bid-event tables in iPadBidPeriodCalendarView.swift).
                """
            )
        }
    }
}

private func schedule(
    id: String,
    label: String,
    legs: [TripLeg],
    openTimeTrips: [OpenTimeTrip] = []
) -> PayPeriodSchedule {
    PayPeriodSchedule(
        id: id,
        label: label,
        tripCount: legs.isEmpty ? 0 : 1,
        legCount: legs.count,
        openTimeCount: openTimeTrips.count,
        updatedAt: Date(timeIntervalSince1970: 0),
        legs: legs,
        openTimeTrips: openTimeTrips
    )
}

private func leg(
    payPeriod: String,
    pairing: String,
    flight: String,
    depAirport: String,
    arrAirport: String,
    depUTC: String?,
    arrUTC: String?,
    legNumber: Int = 1
) -> TripLeg {
    TripLeg(
        payPeriod: payPeriod,
        pairing: pairing,
        leg: legNumber,
        flight: flight,
        depAirport: depAirport,
        depLocal: "",
        arrAirport: arrAirport,
        arrLocal: "",
        depUTC: depUTC,
        arrUTC: arrUTC,
        status: "-",
        block: ""
    )
}

private func openTimeTrip(payPeriod: String, pairing: String) -> OpenTimeTrip {
    OpenTimeTrip(
        payPeriod: payPeriod,
        pairing: pairing,
        startLocal: "",
        endLocal: "",
        route: "",
        credit: "",
        requestType: "",
        status: ""
    )
}

private func openTimeTrip(
    payPeriod: String,
    pairing: String,
    startLocal: String,
    depUTC: String
) -> OpenTimeTrip {
    OpenTimeTrip(
        payPeriod: payPeriod,
        pairing: pairing,
        startLocal: startLocal,
        endLocal: startLocal,
        route: "SDF-ANC",
        credit: "",
        requestType: "",
        status: "",
        legs: [
            TripLeg(
                payPeriod: payPeriod,
                pairing: pairing,
                leg: 1,
                flight: "5X1",
                depAirport: "SDF",
                depLocal: startLocal,
                arrAirport: "ANC",
                arrLocal: startLocal,
                depUTC: depUTC,
                arrUTC: depUTC,
                status: "-",
                block: ""
            )
        ]
    )
}

private func makeBidPeriod(startUTC: String) -> CalendarBidPeriod {
    let formatter = ISO8601DateFormatter()
    let start = formatter.date(from: startUTC)!
    let days = generateBidPeriodDays(startUTC: start)
    let end = start.addingTimeInterval(TimeInterval(days.count) * 86_400)
    return CalendarBidPeriod(
        id: "BP",
        startDateUTC: start,
        endDateUTC: end,
        days: days
    )
}

private func calendarTrip(
    id: String,
    pairing: String,
    payPeriod: String,
    legs: [TripLeg],
    startUTC: String,
    endUTC: String
) -> CalendarTrip {
    let formatter = ISO8601DateFormatter()
    return CalendarTrip(
        id: id,
        pairing: pairing,
        payPeriod: payPeriod,
        legs: legs,
        startUTC: formatter.date(from: startUTC)!,
        endUTC: formatter.date(from: endUTC)!
    )
}

private func makeTrip(payPeriod: String, pairing: String, legs: [TripLeg]) -> CalendarTrip {
    let startUTC = legs.compactMap { LegConnectionTextBuilder.parseUTC($0.depUTC) }.min()!
    let endUTC = legs.compactMap { LegConnectionTextBuilder.parseUTC($0.arrUTC) }.max()!
    return CalendarTrip(
        id: "\(payPeriod)|\(pairing)",
        pairing: pairing,
        payPeriod: payPeriod,
        legs: legs,
        startUTC: startUTC,
        endUTC: endUTC
    )
}

private func segment(
    tripID: String,
    dayIndex: Int,
    weekIndex: Int,
    startUTC: String,
    startFraction: Double,
    endFraction: Double,
    lane: Int = 0
) -> CalendarSegment {
    let formatter = ISO8601DateFormatter()
    return CalendarSegment(
        tripID: tripID,
        weekIndex: weekIndex,
        dayIndex: dayIndex,
        segmentStartUTC: formatter.date(from: startUTC)!,
        startFraction: startFraction,
        endFraction: endFraction,
        lane: lane,
        hasLocalTimeRegression: false,
        regressedRange: nil
    )
}
