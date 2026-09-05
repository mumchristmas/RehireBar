import Foundation
import XCTest
@testable import RehireBar

final class CodexUsageProviderTests: XCTestCase {
    func testPrimarySuccessDoesNotCallFallback() async throws {
        let expected = snapshot(used: 10, observedAt: Date(timeIntervalSince1970: 100))
        let primary = StubFetcher([.success(expected)])
        let fallback = StubFetcher([.failure(.failed)])

        let actual = try await CodexUsageProvider(
            primary: primary, fallback: fallback,
            clock: { Date(timeIntervalSince1970: 100) }
        ).fetch()

        XCTAssertEqual(actual, expected)
        let fallbackCalls = await fallback.callCount
        XCTAssertEqual(fallbackCalls, 0)
    }

    func testPrimaryFailureUsesFallback() async throws {
        let expected = snapshot(used: 20, observedAt: Date(timeIntervalSince1970: 100))
        let provider = CodexUsageProvider(
            primary: StubFetcher([.failure(.failed)]),
            fallback: StubFetcher([.success(expected)]),
            clock: { Date(timeIntervalSince1970: 100) }
        )

        let actual = try await provider.fetch()
        XCTAssertEqual(actual, expected)
    }

    func testBothFailuresReturnCachedSnapshotMarkedStaleAtExactlyFifteenMinutes() async throws {
        let fresh = snapshot(used: 30, observedAt: Date(timeIntervalSince1970: 100))
        let clock = TestClock(Date(timeIntervalSince1970: 100))
        let provider = CodexUsageProvider(
            primary: StubFetcher([.success(fresh), .failure(.failed)]),
            fallback: StubFetcher([.failure(.failed)]),
            clock: { clock.now }
        )
        _ = try await provider.fetch()
        clock.now = Date(timeIntervalSince1970: 1_000)

        let stale = try await provider.fetch()

        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.primary, fresh.primary)
        XCTAssertEqual(stale.secondary, fresh.secondary)
        XCTAssertEqual(stale.observedAt, fresh.observedAt)
    }

    func testCacheOlderThanFifteenMinutesThrowsUnavailable() async throws {
        let fresh = snapshot(used: 30, observedAt: Date(timeIntervalSince1970: 100))
        let clock = TestClock(Date(timeIntervalSince1970: 100))
        let provider = CodexUsageProvider(
            primary: StubFetcher([.success(fresh), .failure(.failed)]),
            fallback: StubFetcher([.failure(.failed)]),
            clock: { clock.now }
        )
        _ = try await provider.fetch()
        clock.now = Date(timeIntervalSince1970: 1_001)

        do {
            _ = try await provider.fetch()
            XCTFail("Expected unavailable")
        } catch {
            XCTAssertEqual(error as? UsageError, .unavailable)
        }
    }

    func testRepeatedSuccessfulReadsOfHistoricalFallbackNeverExtendItsLifetime() async throws {
        let historical = snapshot(used: 30, observedAt: Date(timeIntervalSince1970: 100))
        let clock = TestClock(Date(timeIntervalSince1970: 500))
        let provider = CodexUsageProvider(
            primary: StubFetcher([.failure(.failed), .failure(.failed), .failure(.failed)]),
            fallback: StubFetcher([.success(historical), .success(historical), .failure(.failed)]),
            clock: { clock.now }
        )

        let first = try await provider.fetch()
        XCTAssertTrue(first.isStale)
        clock.now = Date(timeIntervalSince1970: 900)
        let second = try await provider.fetch()
        XCTAssertTrue(second.isStale)
        clock.now = Date(timeIntervalSince1970: 1_001)

        await XCTAssertThrowsUnavailable { _ = try await provider.fetch() }
    }

    func testObservationAtFreshnessThresholdIsCurrent() async throws {
        let recent = snapshot(used: 30, observedAt: Date(timeIntervalSince1970: 100))
        let clock = TestClock(Date(timeIntervalSince1970: 130))
        let provider = CodexUsageProvider(
            primary: StubFetcher([.failure(.failed)]),
            fallback: StubFetcher([.success(recent)]),
            clock: { clock.now }
        )
        let result = try await provider.fetch()
        XCTAssertFalse(result.isStale)
    }

    private func snapshot(used: Double, observedAt: Date) -> UsageSnapshot {
        try! UsageSnapshot.from(
            primary: .init(usedPercent: used, windowMinutes: 300, resetsAt: 2_000),
            secondary: .init(usedPercent: used, windowMinutes: 10_080, resetsAt: 3_000),
            observedAt: observedAt
        )
    }
}

private func XCTAssertThrowsUnavailable(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do { try await operation(); XCTFail("Expected unavailable", file: file, line: line) }
    catch { XCTAssertEqual(error as? UsageError, .unavailable, file: file, line: line) }
}

private enum StubError: Error, Sendable { case failed }

private actor StubFetcher: UsageFetching {
    private var results: [Result<UsageSnapshot, StubError>]
    private(set) var callCount = 0

    init(_ results: [Result<UsageSnapshot, StubError>]) { self.results = results }

    func fetch() async throws -> UsageSnapshot {
        callCount += 1
        return try results.removeFirst().get()
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
