import Foundation
import XCTest
@testable import AgentStatusCore
@testable import RehireBar

final class StatusCacheTests: XCTestCase {
    func testFileCacheRoundTripsTaskAndFastModeMetadata() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StatusCacheStore(
            snapshotURL: root.appending(path: "nested/status-cache.json")
        )
        let snapshot = StatusCacheSnapshot(
            primaryRemainingPercent: 72,
            secondaryRemainingPercent: 41,
            sessionUsedTokens: 98_321,
            sessionContextWindow: 258_400,
            model: "gpt-5.6-sol",
            effort: "high",
            serviceTier: "priority",
            observedAt: Date(timeIntervalSince1970: 1),
            usageObservedAt: Date(timeIntervalSince1970: 1),
            sessionObservedAt: Date(timeIntervalSince1970: 4),
            primaryResetAt: Date(timeIntervalSince1970: 2),
            secondaryResetAt: Date(timeIntervalSince1970: 3)
        )

        store.save(snapshot)

        XCTAssertEqual(store.load(), snapshot)
    }

    func testNewInstallationStartsWithAnUnavailableCache() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = StatusCachePaths.defaultURL(applicationSupportDirectory: root)
        XCTAssertEqual(url, root.appending(path: "RehireBar/status-cache.json"))
        XCTAssertEqual(StatusCacheStore(snapshotURL: url).load(), .unavailable)
    }

    @MainActor
    func testPublisherStoresOnlyTouchBarDisplayFields() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StatusCacheStore(
            snapshotURL: root.appending(path: "status-cache.json")
        )
        let status = TouchBarStatusSnapshot(
            usage: UsageSnapshot(
                primary: .init(label: "5H", usedPercent: 28, windowMinutes: 300, resetsAt: 2),
                secondary: .init(label: "7D", usedPercent: 59, windowMinutes: 10_080, resetsAt: 3),
                observedAt: Date(timeIntervalSince1970: 1),
                isStale: false
            ),
            session: CurrentSessionSnapshot(
                sessionID: "session",
                usedTokens: 98_321,
                contextWindow: 258_400,
                model: "gpt-5.6-sol",
                effort: "high",
                serviceTier: "priority",
                observedAt: Date(timeIntervalSince1970: 4)
            )
        )
        StatusCachePublisher(store: store, clock: { Date(timeIntervalSince1970: 4) })
            .publish(status)

        let cached = store.load()
        XCTAssertEqual(cached.primaryRemainingPercent, 72)
        XCTAssertEqual(cached.secondaryRemainingPercent, 41)
        XCTAssertEqual(cached.serviceTier, "priority")
        XCTAssertEqual(cached.observedAt, Date(timeIntervalSince1970: 4))
        XCTAssertEqual(cached.usageObservedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(cached.sessionObservedAt, Date(timeIntervalSince1970: 4))

        let hydrated = TouchBarStatusSnapshot(
            cached: cached,
            now: Date(timeIntervalSince1970: 4)
        )
        XCTAssertEqual(hydrated.usage?.observedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(hydrated.session?.observedAt, Date(timeIntervalSince1970: 4))
    }

    func testCachedContextAndModelExpireOnIndependentFieldDeadlines() {
        let cached = StatusCacheSnapshot(
            primaryRemainingPercent: nil,
            secondaryRemainingPercent: nil,
            sessionUsedTokens: 80_000,
            sessionContextWindow: 100_000,
            model: "gpt-5.6-sol",
            effort: "high",
            observedAt: Date(timeIntervalSince1970: 1),
            sessionObservedAt: Date(timeIntervalSince1970: 1),
            sessionContextObservedAt: Date(timeIntervalSince1970: 100),
            sessionModelObservedAt: Date(timeIntervalSince1970: 100)
        )

        let contextExpired = TouchBarStatusSnapshot(
            cached: cached,
            now: Date(timeIntervalSince1970: 200)
        )
        let allExpired = TouchBarStatusSnapshot(
            cached: cached,
            now: Date(timeIntervalSince1970: 500)
        )

        XCTAssertEqual(contextExpired.session?.contextWindow, 0)
        XCTAssertEqual(contextExpired.session?.model, "gpt-5.6-sol")
        XCTAssertNil(allExpired.session)
    }
}
