import Foundation
import XCTest
@testable import RehireBar

final class LiveSessionStatusProviderTests: XCTestCase {
    func testSuccessfulEmptyCollectionCanClearPreviouslyVisibleTasks() async throws {
        let provider = LiveSessionStatusProvider(
            session: StubLiveSessionFetcher(result: .failure(UsageError.unavailable)),
            sessions: StubLiveSessionCollectionFetcher(result: .success([]))
        )

        let status = try await provider.fetchStatus()

        XCTAssertTrue(status.includesSessions)
        XCTAssertTrue(status.sessions.isEmpty)
        XCTAssertNil(status.session)
    }

    func testSelectedTaskCannotReappearAfterCatalogRemoval() async throws {
        let current = CurrentSessionSnapshot(
            sessionID: "selected", threadID: "10000000-0000-4000-8000-000000000002",
            usedTokens: 10, contextWindow: 100, model: nil, effort: nil, observedAt: .now
        )
        let status = try await LiveSessionStatusProvider(
            session: StubLiveSessionFetcher(result: .success(current)),
            sessions: StubLiveSessionCollectionFetcher(result: .success([]))
        ).fetchStatus()
        XCTAssertTrue(status.sessions.isEmpty)
        XCTAssertNil(status.session)

        let fallback = try await LiveSessionStatusProvider(
            session: StubLiveSessionFetcher(result: .success(current)),
            sessions: StubLiveSessionCollectionFetcher(result: .failure(UsageError.unavailable))
        ).fetchStatus()
        XCTAssertEqual(fallback.sessions.map(\.identity), [current.identity])
    }

    func testFastModeStaysOnAsRolloutProgressAndDesktopRefreshAlternate() async throws {
        // Progress records do not carry Desktop's current service tier. Their
        // newer token/model timestamp must not clear the catalog's resolved tier.
        for (progressAt, desktopAt) in [(201.0, 200.0), (201, 204), (206, 204)] {
            let current = tierSnapshot(tier: nil, observed: progressAt, usedTokens: 120)
            let catalog = tierSnapshot(tier: "priority", observed: desktopAt, usedTokens: 100)
            let status = try await LiveSessionStatusProvider(
                session: StubLiveSessionFetcher(result: .success(current)),
                sessions: StubLiveSessionCollectionFetcher(result: .success([catalog])),
                now: { Date(timeIntervalSince1970: 220) }
            ).fetchStatus()

            XCTAssertEqual(status.session?.serviceTier, "priority")
            XCTAssertEqual(status.session?.isFastMode, true)
            XCTAssertEqual(status.session?.usedTokens, progressAt > desktopAt ? 120 : 100)
            XCTAssertEqual(status.sessions.map(\.identity), [catalog.identity])
        }
    }

    func testResolvedFastModeOffSurvivesNewerHistoricalRolloutProgress() async throws {
        for tier in [nil, "default"] as [String?] {
            let current = tierSnapshot(tier: "priority", observed: 206, usedTokens: 120)
            let catalog = tierSnapshot(tier: tier, observed: 204, usedTokens: 100)
            let status = try await LiveSessionStatusProvider(
                session: StubLiveSessionFetcher(result: .success(current)),
                sessions: StubLiveSessionCollectionFetcher(result: .success([catalog])),
                now: { Date(timeIntervalSince1970: 220) }
            ).fetchStatus()

            XCTAssertEqual(status.session?.serviceTier, tier)
            XCTAssertEqual(status.session?.isFastMode, false)
            XCTAssertEqual(status.session?.usedTokens, 120)
        }
    }

    private func tierSnapshot(tier: String?, observed: TimeInterval, usedTokens: Int) -> CurrentSessionSnapshot {
        CurrentSessionSnapshot(
            sessionID: "local-rollout", threadID: "10000000-0000-4000-8000-000000000002",
            usedTokens: usedTokens, contextWindow: 1_000,
            model: "gpt-6-astra", effort: "high", serviceTier: tier,
            observedAt: Date(timeIntervalSince1970: observed),
            executionState: .working
        )
    }

    func testSameThreadIDOnDifferentHostsDoesNotCrossMergeRuntimeFields() async throws {
        let threadID = "10000000-0000-4000-8000-000000000002"
        let selectedPlaceholder = CurrentSessionSnapshot(
            sessionID: "selected-thread", threadID: threadID, title: "Stale local title",
            usedTokens: 0, contextWindow: 0, model: nil, effort: nil, observedAt: .now
        )
        let remoteRuntime = CurrentSessionSnapshot(
            sessionID: "remote", threadID: threadID, title: "Live Codex App title",
            usedTokens: 196_000, contextWindow: 258_000, model: "gpt-5.6-sol",
            effort: "xhigh", serviceTier: "priority", observedAt: .now,
            activeSince: Date(timeIntervalSince1970: 100), isCompactingContext: true,
            projectName: "RemoteProject", hostName: "TestHost", isRemote: true,
            executionState: .working
        )
        let provider = LiveSessionStatusProvider(
            session: StubLiveSessionFetcher(result: .success(selectedPlaceholder)),
            sessions: StubLiveSessionCollectionFetcher(result: .success([remoteRuntime]))
        )

        let status = try await provider.fetchStatus()

        XCTAssertEqual(status.sessions.count, 1)
        XCTAssertFalse(status.sessions.contains { $0.hostID == "local" })
        let remote = try XCTUnwrap(status.sessions.first { $0.identity == remoteRuntime.identity })
        XCTAssertEqual(remote.usedTokens, 196_000)
        XCTAssertEqual(remote.model, remoteRuntime.model)
        XCTAssertEqual(status.session?.identity, remoteRuntime.identity)
    }

    func testCollectionPrioritizesRunningRemoteOverFocusedInactiveTask() async throws {
        let current = CurrentSessionSnapshot(
            sessionID: "local", threadID: "local-thread", usedTokens: 1,
            contextWindow: 100, model: nil, effort: nil, observedAt: .now
        )
        let remote = CurrentSessionSnapshot(
            sessionID: "remote", threadID: "remote-thread", title: "Remote task",
            usedTokens: 0, contextWindow: 0, model: nil, effort: nil, observedAt: .now,
            projectName: "RemoteProject", isRemote: true, executionState: .working
        )
        let provider = LiveSessionStatusProvider(
            session: StubLiveSessionFetcher(result: .success(current)),
            sessions: StubLiveSessionCollectionFetcher(result: .success([remote, current]))
        )

        let status = try await provider.fetchStatus()

        XCTAssertEqual(status.sessions.map(\.sessionID), ["remote", "local"])
    }

    func testUniqueRemoteCatalogTaskReplacesHostlessFocusedPlaceholder() async throws {
        let threadID = "10000000-0000-4000-8000-000000000002"
        let placeholder = CurrentSessionSnapshot(
            sessionID: "selected-thread",
            threadID: threadID,
            usedTokens: 0,
            contextWindow: 0,
            model: nil,
            effort: nil,
            observedAt: .now,
            isPlaceholder: true
        )
        let remote = CurrentSessionSnapshot(
            sessionID: "remote",
            threadID: threadID,
            title: "Remote task",
            usedTokens: 196_000,
            contextWindow: 258_000,
            model: "gpt-5.6-sol",
            effort: "xhigh",
            observedAt: .now,
            projectName: "RemoteProject",
            hostName: "TestHost",
            hostID: "remote-ssh-codex-managed:TestHost",
            hostKind: .ssh,
            executionState: .working
        )
        let provider = LiveSessionStatusProvider(
            session: StubLiveSessionFetcher(result: .success(placeholder)),
            sessions: StubLiveSessionCollectionFetcher(result: .success([remote]))
        )

        let status = try await provider.fetchStatus()

        XCTAssertEqual(status.sessions, [remote])
        XCTAssertEqual(status.session?.identity, remote.identity)
        XCTAssertEqual(status.session?.usedTokens, 196_000)
    }

    func testBothSourcesFailAsUnavailable() async {
        let provider = LiveSessionStatusProvider(
            session: StubLiveSessionFetcher(result: .failure(UsageError.unavailable)),
            sessions: StubLiveSessionCollectionFetcher(result: .failure(UsageError.unavailable))
        )
        do {
            _ = try await provider.fetchStatus()
            XCTFail("Expected unavailable")
        } catch let error as UsageError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private struct StubLiveSessionFetcher: SessionFetching {
    let result: Result<CurrentSessionSnapshot, Error>
    func fetchSession() async throws -> CurrentSessionSnapshot { try result.get() }
}

private struct StubLiveSessionCollectionFetcher: SessionCollectionFetching {
    let result: Result<[CurrentSessionSnapshot], Error>
    func fetchSessions() async throws -> [CurrentSessionSnapshot] { try result.get() }
}
