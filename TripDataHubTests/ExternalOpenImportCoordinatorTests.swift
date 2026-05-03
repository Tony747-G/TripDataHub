import XCTest
@testable import TripData_Hub

final class ExternalOpenImportCoordinatorTests: XCTestCase {
    func test_enqueueDeduplicatesQueuedKey() async {
        let coordinator = ExternalOpenImportCoordinator(dedupTTL: 30)
        let now = Date(timeIntervalSince1970: 100)

        let first = await coordinator.enqueue(key: "same", url: url("one.pdf"), now: now)
        let second = await coordinator.enqueue(key: "same", url: url("two.pdf"), now: now)

        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let item = await coordinator.dequeueNext()
        XCTAssertEqual(item?.key, "same")
        let next = await coordinator.dequeueNext()
        XCTAssertNil(next)
    }

    func test_concurrentEnqueue_allowsOnlyOneAcceptedKey() async {
        let coordinator = ExternalOpenImportCoordinator(dedupTTL: 30)
        let now = Date(timeIntervalSince1970: 100)

        let acceptedCount = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<40 {
                group.addTask {
                    await coordinator.enqueue(key: "same", url: self.url("file-\(index).pdf"), now: now)
                }
            }

            var count = 0
            for await accepted in group where accepted {
                count += 1
            }
            return count
        }

        XCTAssertEqual(acceptedCount, 1)
    }

    func test_finishFailureAllowsImmediateRetry() async {
        let coordinator = ExternalOpenImportCoordinator(dedupTTL: 30)
        let now = Date(timeIntervalSince1970: 100)

        let initialEnqueue = await coordinator.enqueue(key: "retry", url: url("one.pdf"), now: now)
        XCTAssertTrue(initialEnqueue)
        let item = await coordinator.dequeueNext()
        XCTAssertEqual(item?.key, "retry")
        let markedInFlight = await coordinator.markInFlight("retry")
        XCTAssertTrue(markedInFlight)
        await coordinator.finish(key: "retry", success: false)

        let retryEnqueue = await coordinator.enqueue(key: "retry", url: url("one.pdf"), now: now.addingTimeInterval(1))
        XCTAssertTrue(retryEnqueue)
    }

    func test_finishSuccessSuppressesRetryUntilTTLExpires() async {
        let coordinator = ExternalOpenImportCoordinator(dedupTTL: 30)
        let now = Date(timeIntervalSince1970: 100)

        let initialEnqueue = await coordinator.enqueue(key: "done", url: url("one.pdf"), now: now)
        XCTAssertTrue(initialEnqueue)
        _ = await coordinator.dequeueNext()
        let markedInFlight = await coordinator.markInFlight("done")
        XCTAssertTrue(markedInFlight)
        await coordinator.finish(key: "done", success: true, now: now)

        let earlyRetry = await coordinator.enqueue(key: "done", url: url("one.pdf"), now: now.addingTimeInterval(1))
        let ttlRetry = await coordinator.enqueue(key: "done", url: url("one.pdf"), now: now.addingTimeInterval(31))
        XCTAssertFalse(earlyRetry)
        XCTAssertTrue(ttlRetry)
    }

    func test_resetDoesNotClearInFlightKey() async {
        let coordinator = ExternalOpenImportCoordinator(dedupTTL: 30)
        let now = Date(timeIntervalSince1970: 100)

        let initialEnqueue = await coordinator.enqueue(key: "active", url: url("one.pdf"), now: now)
        XCTAssertTrue(initialEnqueue)
        _ = await coordinator.dequeueNext()
        let markedInFlight = await coordinator.markInFlight("active")
        XCTAssertTrue(markedInFlight)
        await coordinator.reset()

        let enqueueWhileInFlight = await coordinator.enqueue(key: "active", url: url("one.pdf"), now: now.addingTimeInterval(1))
        XCTAssertFalse(enqueueWhileInFlight)
        await coordinator.finish(key: "active", success: false)
        let enqueueAfterFinish = await coordinator.enqueue(key: "active", url: url("one.pdf"), now: now.addingTimeInterval(2))
        XCTAssertTrue(enqueueAfterFinish)
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }
}
