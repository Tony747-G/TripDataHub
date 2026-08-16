import XCTest
@testable import TripDataHub

final class ImportFingerprintLedgerTests: XCTestCase {
    func test_activeFingerprintIsSuppressedWithoutTTL() throws {
        let context = try makeContext()
        XCTAssertEqual(context.ledger.claim("A"), .accepted)

        context.clock.advance(by: 24 * 60 * 60)

        XCTAssertEqual(context.ledger.claim("A"), .suppressed(.active))
    }

    func test_consumedAndDismissedUseOnlyTheDeliveryBurstWindow() throws {
        let context = try makeContext()
        XCTAssertEqual(context.ledger.claim("consumed"), .accepted)
        context.ledger.markConsumed("consumed")
        XCTAssertEqual(context.ledger.claim("dismissed"), .accepted)
        context.ledger.markDismissed("dismissed")

        context.clock.advance(by: 119)
        XCTAssertEqual(context.ledger.claim("consumed"), .suppressed(.consumed))
        XCTAssertEqual(context.ledger.claim("dismissed"), .suppressed(.dismissed))

        context.clock.advance(by: 2)
        XCTAssertEqual(context.ledger.claim("consumed"), .accepted)
        XCTAssertEqual(context.ledger.claim("dismissed"), .accepted)
    }

    func test_multipleFingerprintsDoNotOverwriteEachOther() throws {
        let context = try makeContext()
        XCTAssertEqual(context.ledger.claim("A"), .accepted)
        XCTAssertEqual(context.ledger.claim("B"), .accepted)
        context.ledger.markConsumed("A")

        XCTAssertEqual(context.ledger.suppressionState(for: "A"), .consumed)
        XCTAssertEqual(context.ledger.suppressionState(for: "B"), .active)
    }

    func test_interruptedActiveClaimRecoversAsShortDismissedBurst() throws {
        let context = try makeContext()
        XCTAssertEqual(context.ledger.claim("A"), .accepted)

        let clock = context.clock
        let relaunched = ImportFingerprintLedger(defaults: context.defaults, now: { clock.now() })
        XCTAssertEqual(relaunched.claim("A"), .suppressed(.dismissed))

        context.clock.advance(by: 121)
        XCTAssertEqual(relaunched.claim("A"), .accepted)
    }

    func test_T35_releaseActiveClaimAllowsImmediateRetryWithoutWeakeningBurstStates() throws {
        let context = try makeContext()
        XCTAssertEqual(context.ledger.claim("failed"), .accepted)
        XCTAssertEqual(context.ledger.claim("consumed"), .accepted)
        context.ledger.markConsumed("consumed")
        XCTAssertEqual(context.ledger.claim("dismissed"), .accepted)
        context.ledger.markDismissed("dismissed")

        context.ledger.releaseActiveClaim("failed")
        context.ledger.releaseActiveClaim("consumed")
        context.ledger.releaseActiveClaim("dismissed")

        XCTAssertEqual(context.ledger.claim("failed"), .accepted)
        XCTAssertEqual(context.ledger.claim("consumed"), .suppressed(.consumed))
        XCTAssertEqual(context.ledger.claim("dismissed"), .suppressed(.dismissed))
    }

    private func makeContext() throws -> (
        ledger: ImportFingerprintLedger,
        clock: LedgerTestClock,
        defaults: UserDefaults
    ) {
        let suite = "ImportFingerprintLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let clock = LedgerTestClock(Date(timeIntervalSince1970: 1_000))
        return (ImportFingerprintLedger(defaults: defaults, now: { clock.now() }), clock, defaults)
    }
}

private final class LedgerTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = value.addingTimeInterval(interval)
    }
}
