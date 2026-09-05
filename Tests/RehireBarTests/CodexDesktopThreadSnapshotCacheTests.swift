import XCTest
@testable import RehireBar

final class CodexDesktopThreadSnapshotCacheTests: XCTestCase {
    func testFirstReadReturnsCurrentSnapshotAndShortCacheDeduplicatesImmediateRead() async throws {
        let expected = CodexDesktopThreadSnapshot(
            identity: .init(hostID: "local", threadID: "thread"),
            observedAt: .now,
            usedTokens: 80_000,
            contextWindow: 200_000,
            model: "gpt-5.6-sol",
            effort: "high",
            executionState: .working,
            isCompactingContext: true
        )
        let upstream = ImmediateDesktopSnapshotFetcher(snapshot: expected)
        let cache = CodexDesktopThreadSnapshotCache(
            upstream: upstream,
            successLifetime: 1
        )

        let first = try await cache.fetchThreadSnapshot(threadID: "thread", hostID: "local")
        let second = try await cache.fetchThreadSnapshot(threadID: "thread", hostID: "local")
        let cached = await cache.cachedThreadSnapshot(threadID: "thread", hostID: "local")

        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected)
        XCTAssertEqual(cached, expected)
        let fetchCount = await upstream.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testFailedRefreshPreservesTheLastSuccessfulSnapshot() async throws {
        let expected = CodexDesktopThreadSnapshot(
            identity: .init(hostID: "local", threadID: "thread"),
            observedAt: .now,
            usedTokens: 80_000,
            contextWindow: 200_000,
            model: "gpt-5.6-sol",
            effort: "high",
            executionState: .working
        )
        let upstream = FailingAfterFirstDesktopSnapshotFetcher(snapshot: expected)
        let cache = CodexDesktopThreadSnapshotCache(
            upstream: upstream,
            successLifetime: -1,
            failureLifetime: 30
        )

        _ = try await cache.fetchThreadSnapshot(threadID: "thread", hostID: "local")
        do {
            _ = try await cache.fetchThreadSnapshot(threadID: "thread", hostID: "local")
            XCTFail("Expected the refresh to fail")
        } catch {}

        let cached = await cache.cachedThreadSnapshot(threadID: "thread", hostID: "local")
        XCTAssertEqual(cached, expected)
        let fetchCount = await upstream.fetchCount
        XCTAssertEqual(fetchCount, 2)
    }

    func testCallerCanUseLongerLifetimeForLowValueIdleRefreshes() async throws {
        let expected = CodexDesktopThreadSnapshot(
            identity: .init(hostID: "local", threadID: "thread"),
            observedAt: .now,
            usedTokens: 1,
            contextWindow: 100,
            model: "gpt-5.6-sol",
            effort: "low",
            executionState: .idle
        )
        let upstream = ImmediateDesktopSnapshotFetcher(snapshot: expected)
        let cache = CodexDesktopThreadSnapshotCache(
            upstream: upstream,
            successLifetime: -1
        )

        _ = try await cache.fetchThreadSnapshot(threadID: "thread", hostID: "local")
        _ = try await cache.fetchThreadSnapshot(
            threadID: "thread",
            hostID: "local",
            maximumAge: 15
        )
        let fetchCount = await upstream.fetchCount

        XCTAssertEqual(fetchCount, 1)
    }

    func testRepeatedRuntimeFailuresUsePerThreadExponentialBackoff() async throws {
        let clock = SnapshotCacheClock()
        let expected = CodexDesktopThreadSnapshot(
            identity: .init(hostID: "local", threadID: "thread"),
            observedAt: Date(timeIntervalSince1970: 0),
            usedTokens: 1,
            contextWindow: 100,
            model: nil,
            effort: nil,
            executionState: .idle
        )
        let upstream = FailingAfterFirstDesktopSnapshotFetcher(snapshot: expected)
        let cache = CodexDesktopThreadSnapshotCache(
            upstream: upstream,
            successLifetime: -1,
            failureLifetime: 30,
            now: { clock.now }
        )
        _ = try await cache.fetchThreadSnapshot(threadID: "thread", hostID: "local")
        _ = try? await cache.fetchThreadSnapshot(threadID: "thread", hostID: "local")

        clock.now = Date(timeIntervalSince1970: 29)
        let cachedDuringBackoff = try await cache.fetchThreadSnapshot(
            threadID: "thread",
            hostID: "local"
        )
        XCTAssertEqual(cachedDuringBackoff, expected)
        var fetchCount = await upstream.fetchCount
        XCTAssertEqual(fetchCount, 2)

        clock.now = Date(timeIntervalSince1970: 30)
        _ = try? await cache.fetchThreadSnapshot(threadID: "thread", hostID: "local")
        clock.now = Date(timeIntervalSince1970: 89)
        _ = try await cache.fetchThreadSnapshot(threadID: "thread", hostID: "local")
        fetchCount = await upstream.fetchCount
        XCTAssertEqual(fetchCount, 3)
    }

    func testSameThreadIDOnDifferentHostsUsesIndependentCacheEntries() async throws {
        let upstream = HostAwareDesktopSnapshotFetcher()
        let cache = CodexDesktopThreadSnapshotCache(upstream: upstream, successLifetime: 60)

        let local = try await cache.fetchThreadSnapshot(threadID: "same", hostID: "local")
        let remote = try await cache.fetchThreadSnapshot(
            threadID: "same",
            hostID: "remote-control:environment"
        )

        XCTAssertEqual(local.identity, TaskIdentity(hostID: "local", threadID: "same"))
        XCTAssertEqual(
            remote.identity,
            TaskIdentity(hostID: "remote-control:environment", threadID: "same")
        )
        let fetchCount = await upstream.fetchCount
        XCTAssertEqual(fetchCount, 2)
    }

    func testMismatchedUpstreamIdentityIsRejectedAndNotCached() async throws {
        let wrong = CodexDesktopThreadSnapshot(
            identity: TaskIdentity(hostID: "other-host", threadID: "same"),
            observedAt: .now,
            usedTokens: 1,
            contextWindow: 100,
            model: nil,
            effort: nil,
            executionState: .working
        )
        let cache = CodexDesktopThreadSnapshotCache(
            upstream: ImmediateDesktopSnapshotFetcher(snapshot: wrong)
        )

        do {
            _ = try await cache.fetchThreadSnapshot(threadID: "same", hostID: "local")
            XCTFail("Expected identity mismatch to fail closed")
        } catch {}
        let cached = await cache.cachedThreadSnapshot(threadID: "same", hostID: "local")
        XCTAssertNil(cached)
    }
}

private final class SnapshotCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 0)

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

private actor ImmediateDesktopSnapshotFetcher: DesktopThreadSnapshotFetching {
    private let snapshot: CodexDesktopThreadSnapshot
    private(set) var fetchCount = 0

    init(snapshot: CodexDesktopThreadSnapshot) { self.snapshot = snapshot }

    func fetchThreadSnapshot(
        threadID: String,
        hostID: String
    ) async throws -> CodexDesktopThreadSnapshot {
        fetchCount += 1
        return snapshot
    }
}

private actor FailingAfterFirstDesktopSnapshotFetcher: DesktopThreadSnapshotFetching {
    private let snapshot: CodexDesktopThreadSnapshot
    private(set) var fetchCount = 0

    init(snapshot: CodexDesktopThreadSnapshot) { self.snapshot = snapshot }

    func fetchThreadSnapshot(
        threadID: String,
        hostID: String
    ) async throws -> CodexDesktopThreadSnapshot {
        fetchCount += 1
        guard fetchCount == 1 else { throw UsageError.unavailable }
        return snapshot
    }
}

private actor HostAwareDesktopSnapshotFetcher: DesktopThreadSnapshotFetching {
    private(set) var fetchCount = 0

    func fetchThreadSnapshot(
        threadID: String,
        hostID: String
    ) async throws -> CodexDesktopThreadSnapshot {
        fetchCount += 1
        return CodexDesktopThreadSnapshot(
            identity: TaskIdentity(hostID: hostID, threadID: threadID),
            observedAt: .now,
            usedTokens: hostID == "local" ? 1 : 2,
            contextWindow: 100,
            model: nil,
            effort: nil,
            executionState: .idle
        )
    }
}
