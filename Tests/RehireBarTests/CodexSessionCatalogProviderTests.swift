import Foundation
import SQLite3
import XCTest
@testable import RehireBar

final class CodexSessionCatalogProviderTests: XCTestCase {
    func testRepeatedCatalogReadObservesDatabaseChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let firstID = "10000000-0000-4000-8000-000000000002"
        let secondID = "10000000-0000-4000-8000-000000000003"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('local', '\(firstID)', 'First', '/tmp/First', 100, 100, 0);",
            into: databaseURL
        )
        let provider = CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            now: { Date(timeIntervalSince1970: 200) }
        )

        let first = try await provider.fetchSessions()
        let unchanged = try await provider.fetchSessions()
        XCTAssertEqual(first.map(\.identity), unchanged.map(\.identity))

        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('local', '\(secondID)', 'Second', '/tmp/Second', 110, 110, 0);",
            into: databaseURL
        )
        let updated = try await provider.fetchSessions()
        XCTAssertEqual(updated.count, 2)
    }

    func testTransientEmptyCatalogKeepsLastRowsAndStillRetriesRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let firstID = "10000000-0000-4000-8000-000000000002"
        let recoveredID = "10000000-0000-4000-8000-000000000003"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('remote-ssh-codex-managed:TestHost', '\(firstID)', 'Before gap', "
                + "'/tmp/Before', 100, 100, 0);",
            into: databaseURL
        )
        let provider = CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            now: { Date(timeIntervalSince1970: 200) }
        )

        let initial = try await provider.fetchSessions()
        try insert("DELETE FROM local_thread_catalog;", into: databaseURL)
        let duringGap = try await provider.fetchSessions()
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('remote-ssh-codex-managed:TestHost', '\(recoveredID)', 'After recovery', "
                + "'/tmp/After', 190, 190, 0);",
            into: databaseURL
        )
        let recovered = try await provider.fetchSessions()

        XCTAssertEqual(initial.map(\.threadID), [firstID])
        XCTAssertEqual(duringGap.map(\.threadID), [firstID])
        XCTAssertEqual(recovered.map(\.threadID), [recoveredID])
        XCTAssertEqual(recovered.first?.title, "After recovery")
    }

    func testTransientCatalogReadFailureKeepsLastSuccessfulRows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        let unavailableURL = root.appending(path: "codex-dev.db.unavailable")
        try makeCatalog(at: databaseURL)
        let threadID = "10000000-0000-4000-8000-000000000002"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('remote-ssh-codex-managed:TestHost', '\(threadID)', 'Remote task', "
                + "'/tmp/Remote', 100, 100, 0);",
            into: databaseURL
        )
        let provider = CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            now: { Date(timeIntervalSince1970: 200) }
        )

        let initial = try await provider.fetchSessions()
        try FileManager.default.moveItem(at: databaseURL, to: unavailableURL)
        let duringFailure = try await provider.fetchSessions()

        XCTAssertEqual(initial.map(\.threadID), [threadID])
        XCTAssertEqual(duringFailure.map(\.threadID), [threadID])
    }

    func testCodexAppRealtimeStatusOverridesAStaleRemoteCatalogRow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let localID = "10000000-0000-4000-8000-000000000002"
        let remoteID = "10000000-0000-4000-8000-000000000003"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('local', '\(localID)', 'Local caller', '/tmp/TouchBar', 150, 150, 0);",
            into: databaseURL
        )
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('remote-ssh-codex-managed:TestHost', '\(remoteID)', 'Room control', "
                + "'/Users/developer/codex-working/climate-agent', 100, 90, 0);",
            into: databaseURL
        )
        let realtime = FakeAppThreadStatusFetcher(statuses: [.init(
            threadID: remoteID,
            hostID: "remote-ssh-codex-managed:TestHost",
            executionState: .working,
            updatedAt: Date(timeIntervalSince1970: 199),
            activeSince: Date(timeIntervalSince1970: 180)
        )])

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            selectedThread: SelectedThreadState(initialThreadID: remoteID),
            appThreadStatuses: realtime,
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchSessions()

        XCTAssertEqual(sessions.first?.executionState, .working)
        XCTAssertEqual(sessions.first?.title, "Room control")
        XCTAssertEqual(sessions.first?.observedAt, Date(timeIntervalSince1970: 199))
        XCTAssertEqual(sessions.first?.activeSince, Date(timeIntervalSince1970: 180))
        let fetchCount = await realtime.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testFreshRemoteTurnStartIsAcceptedAsRuntimeEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let remoteID = "10000000-0000-4000-8000-000000000003"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('remote-ssh-codex-managed:TestHost', '\(remoteID)', 'Room control', "
                + "'/Users/developer/codex-working/climate-agent', 180, 220, 0);",
            into: databaseURL
        )
        let oldStart = FakeAppThreadStatusFetcher(statuses: [.init(
            threadID: remoteID,
            hostID: "remote-ssh-codex-managed:TestHost",
            executionState: .working,
            updatedAt: Date(timeIntervalSince1970: 199),
            activeSince: Date(timeIntervalSince1970: 199)
        )])

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            selectedThread: SelectedThreadState(initialThreadID: remoteID),
            appThreadStatuses: oldStart,
            now: { Date(timeIntervalSince1970: 225) }
        ).fetchSessions()

        XCTAssertEqual(sessions.first?.executionState, .working)
        XCTAssertEqual(sessions.first?.activeSince, Date(timeIntervalSince1970: 199))
        XCTAssertEqual(sessions.first?.observedAt, Date(timeIntervalSince1970: 220))
    }

    func testRemoteCatalogCompletionBeatsOmittedCompletionLogAndStaleRuntime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let remoteID = "10000000-0000-4000-8000-000000000003"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('remote-ssh-codex-managed:TestHost', '\(remoteID)', 'network-agent', "
                + "'/Users/developer/network-agent', 199, 220, 0);",
            into: databaseURL
        )
        let omittedCompletionLog = FakeAppThreadStatusFetcher(statuses: [.init(
            threadID: remoteID,
            hostID: "remote-ssh-codex-managed:TestHost",
            executionState: .working,
            updatedAt: Date(timeIntervalSince1970: 199),
            activeSince: Date(timeIntervalSince1970: 199)
        )])
        let staleRuntime = FakeDesktopSnapshotFetcher(snapshot: .init(
            observedAt: Date(timeIntervalSince1970: 199),
            usedTokens: 80_000,
            contextWindow: 200_000,
            model: "gpt-5.6-sol",
            effort: "high",
            executionState: .working
        ))

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            selectedThread: SelectedThreadState(initialThreadID: remoteID),
            desktopSnapshots: staleRuntime,
            appThreadStatuses: omittedCompletionLog,
            now: { Date(timeIntervalSince1970: 230) }
        ).fetchSessions()

        XCTAssertEqual(sessions.first?.executionState, .unknown)
        XCTAssertNil(sessions.first?.activeSince)
        XCTAssertNil(sessions.first?.executionStateObservedAt)
        XCTAssertEqual(sessions.first?.usedTokens, 80_000)
    }

    func testExplicitRemoteCompletionOverridesCatalogWorkingHeuristic() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let remoteID = "10000000-0000-4000-8000-000000000003"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('remote-ssh-codex-managed:TestHost', '\(remoteID)', 'Room control', "
                + "'/Users/developer/codex-working/climate-agent', 225, 220, 0);",
            into: databaseURL
        )
        let completed = FakeAppThreadStatusFetcher(statuses: [.init(
            threadID: remoteID,
            hostID: "remote-ssh-codex-managed:TestHost",
            executionState: .idle,
            updatedAt: Date(timeIntervalSince1970: 228),
            activeSince: nil
        )])
        let staleRuntime = FakeDesktopSnapshotFetcher(snapshot: .init(
            observedAt: Date(timeIntervalSince1970: 199),
            usedTokens: 80_000,
            contextWindow: 200_000,
            model: "gpt-5.6-sol",
            effort: "high",
            executionState: .working
        ))

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            selectedThread: SelectedThreadState(initialThreadID: remoteID),
            desktopSnapshots: staleRuntime,
            appThreadStatuses: completed,
            now: { Date(timeIntervalSince1970: 230) }
        ).fetchSessions()

        XCTAssertEqual(sessions.first?.executionState, .idle)
        XCTAssertNil(sessions.first?.activeSince)
        XCTAssertEqual(sessions.first?.executionStateObservedAt, Date(timeIntervalSince1970: 228))
        XCTAssertEqual(sessions.first?.usedTokens, 80_000)
    }

    func testDisconnectedRemoteWorkingTaskBecomesSyncingAndKeepsLastContext() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let remoteID = "10000000-0000-4000-8000-000000000003"
        let hostID = "remote-ssh-codex-managed:TestHost"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('\(hostID)', '\(remoteID)', 'Remote analysis', "
                + "'/Users/developer/codex-working/remote-analysis', 180, 220, 0);",
            into: databaseURL
        )
        let status = FakeAppThreadStatusFetcher(
            statuses: [.init(
                threadID: remoteID,
                hostID: hostID,
                executionState: .working,
                updatedAt: Date(timeIntervalSince1970: 199),
                activeSince: Date(timeIntervalSince1970: 199)
            )],
            hostStatuses: [.init(
                hostID: hostID,
                isSynchronizing: true,
                updatedAt: Date(timeIntervalSince1970: 225)
            )]
        )
        let staleRuntime = FakeDesktopSnapshotFetcher(snapshot: .init(
            observedAt: Date(timeIntervalSince1970: 220),
            usedTokens: 60_000,
            contextWindow: 100_000,
            model: "gpt-5.6-sol",
            effort: "high",
            executionState: .working,
            isCompactingContext: true
        ))

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            selectedThread: SelectedThreadState(initialThreadID: remoteID),
            desktopSnapshots: staleRuntime,
            appThreadStatuses: status,
            now: { Date(timeIntervalSince1970: 230) }
        ).fetchSessions()

        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.executionState, .syncing)
        XCTAssertNil(session.activeSince)
        XCTAssertFalse(session.isCompactingContext)
        XCTAssertEqual(session.usedTokens, 60_000)
        XCTAssertEqual(session.contextWindow, 100_000)
    }

    func testDisconnectedHostMarksAllOfItsRemoteTasksAsAwaitingSync() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let localID = "10000000-0000-4000-8000-000000000002"
        let latestRemoteID = "10000000-0000-4000-8000-000000000003"
        let olderRemoteID = "10000000-0000-4000-8000-000000000004"
        let hostID = "remote-ssh-codex-managed:TestHost"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('local', '\(localID)', 'Local', '/tmp/local', 230, 230, 0), "
                + "('\(hostID)', '\(latestRemoteID)', 'Latest remote', '/tmp/latest', 220, 220, 0), "
                + "('\(hostID)', '\(olderRemoteID)', 'Older remote', '/tmp/older', 100, 100, 0);",
            into: databaseURL
        )
        let status = FakeAppThreadStatusFetcher(
            statuses: [latestRemoteID, olderRemoteID].map {
                .init(
                    threadID: $0,
                    hostID: hostID,
                    executionState: .idle,
                    updatedAt: Date(timeIntervalSince1970: 225),
                    activeSince: nil
                )
            },
            hostStatuses: [.init(
                hostID: hostID,
                isSynchronizing: true,
                updatedAt: Date(timeIntervalSince1970: 229)
            )]
        )

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            selectedThread: SelectedThreadState(initialThreadID: localID),
            appThreadStatuses: status,
            now: { Date(timeIntervalSince1970: 230) }
        ).fetchSessions()
        let byID = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            session.threadID.map { ($0, session.executionState) }
        })

        XCTAssertEqual(byID[latestRemoteID], .syncing)
        XCTAssertEqual(byID[olderRemoteID], .syncing)
    }

    func testSelectedRemoteTaskUsesDesktopRuntimeContextAndStateWhenAvailable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let remoteID = "10000000-0000-4000-8000-000000000003"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('remote-ssh-codex-managed:TestHost', '\(remoteID)', 'Room control', "
                + "'/Users/developer/codex-working/climate-agent', 190, 190, 0);",
            into: databaseURL
        )
        let runtime = FakeDesktopSnapshotFetcher(snapshot: .init(
            observedAt: Date(timeIntervalSince1970: 200),
            usedTokens: 196_000,
            contextWindow: 258_000,
            model: "gpt-5.6-sol",
            effort: "xhigh",
            serviceTier: "priority",
            executionState: .waiting,
            isCompactingContext: true
        ))

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            selectedThread: SelectedThreadState(initialThreadID: remoteID),
            desktopSnapshots: runtime,
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchSessions()

        XCTAssertEqual(sessions.first?.usedTokens, 196_000)
        XCTAssertEqual(sessions.first?.contextWindow, 258_000)
        XCTAssertEqual(sessions.first?.executionState, .waiting)
        XCTAssertEqual(sessions.first?.model, "gpt-5.6-sol")
        XCTAssertEqual(sessions.first?.serviceTier, "priority")
        XCTAssertEqual(sessions.first?.isFastMode, true)
        XCTAssertEqual(sessions.first?.isCompactingContext, true)
        let requests = await runtime.requests
        XCTAssertEqual(requests, ["remote-ssh-codex-managed:TestHost|\(remoteID)"])
    }

    func testIdleRuntimeRefreshStartsBeforeStateFreshnessExpires() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let remoteID = "10000000-0000-4000-8000-000000000003"
        let hostID = "remote-ssh-codex-managed:TestHost"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('\(hostID)', '\(remoteID)', 'Idle remote', '/tmp/remote', 190, 190, 0);",
            into: databaseURL
        )
        let cache = RecordingDesktopSnapshotCache(snapshot: .init(
            identity: TaskIdentity(hostID: hostID, threadID: remoteID),
            observedAt: Date(timeIntervalSince1970: 200),
            usedTokens: 20_000,
            contextWindow: 100_000,
            model: "gpt-5.6-sol",
            effort: "xhigh",
            executionState: .idle
        ))

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            desktopSnapshots: cache,
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchSessions()
        for _ in 0..<20 {
            if !(await cache.maximumAges).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let maximumAges = await cache.maximumAges

        XCTAssertEqual(sessions.first?.executionState, .idle)
        XCTAssertEqual(maximumAges, [5])
        XCTAssertLessThan(try XCTUnwrap(maximumAges.first),
                          SessionEvidenceFreshness.runtimeState)
    }

    func testSelectedLocalTaskAlsoUsesDesktopRuntimeForLiveCompaction() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let localID = "10000000-0000-4000-8000-000000000002"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('local', '\(localID)', 'Local work', '/tmp/TouchBar', 100, 100, 0);",
            into: databaseURL
        )
        let runtime = FakeDesktopSnapshotFetcher(snapshot: .init(
            observedAt: Date(timeIntervalSince1970: 200),
            usedTokens: 80_000,
            contextWindow: 200_000,
            model: "gpt-5.6-sol",
            effort: "high",
            executionState: .working,
            isCompactingContext: true
        ))

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            selectedThread: SelectedThreadState(initialThreadID: localID),
            desktopSnapshots: runtime,
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchSessions()

        XCTAssertEqual(sessions.first?.isCompactingContext, true)
        let requests = await runtime.requests
        XCTAssertEqual(requests, ["local|\(localID)"])
    }

    func testNonSelectedVisibleLocalTaskGetsRealtimeTimerAndOwnModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let selectedID = "10000000-0000-4000-8000-000000000002"
        let secondLocalID = "10000000-0000-4000-8000-000000000004"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('local', '\(selectedID)', 'Selected local', '/tmp/TouchBar', 195, 195, 0);",
            into: databaseURL
        )
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('local', '\(secondLocalID)', 'Second local', '/tmp/HatchPet', 190, 190, 0);",
            into: databaseURL
        )
        let realtime = FakeAppThreadStatusFetcher(statuses: [.init(
            threadID: secondLocalID,
            executionState: .working,
            updatedAt: Date(timeIntervalSince1970: 219),
            activeSince: Date(timeIntervalSince1970: 210)
        )])
        let runtime = FakeDesktopSnapshotFetcher(snapshot: .init(
            observedAt: Date(timeIntervalSince1970: 220),
            usedTokens: 80_000,
            contextWindow: 200_000,
            model: nil,
            effort: nil,
            executionState: .working,
            isCompactingContext: false
        ))
        let metadata = FakeThreadMetadataReader(values: [
            secondLocalID: CodexThreadMetadata(
                threadID: secondLocalID,
                title: "Second local",
                rolloutURL: root.appending(path: "second.jsonl"),
                model: "gpt-5.6-luna",
                effort: "xhigh"
            )
        ])

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            selectedThread: SelectedThreadState(initialThreadID: selectedID),
            desktopSnapshots: runtime,
            appThreadStatuses: realtime,
            threadMetadata: metadata,
            now: { Date(timeIntervalSince1970: 220) }
        ).fetchSessions()

        let second = try XCTUnwrap(sessions.first { $0.threadID == secondLocalID })
        XCTAssertEqual(second.executionState, .working)
        XCTAssertEqual(second.activeSince, Date(timeIntervalSince1970: 210))
        XCTAssertEqual(second.model, "gpt-5.6-luna")
        XCTAssertEqual(second.effort, "xhigh")
        let requests = await runtime.requests
        XCTAssertEqual(
            Set(requests),
            Set(["local|\(selectedID)", "local|\(secondLocalID)"])
        )
    }

    func testLocalRolloutCompletionBeatsStaleDesktopWorkingSignals() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let localID = "10000000-0000-4000-8000-000000000005"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('local', '\(localID)', 'Completed local', '/tmp/TouchBar', 199, 221, 0);",
            into: databaseURL
        )
        try writeRollout(
            root: root,
            threadID: localID,
            lines: [
                taskEvent(timestamp: "1970-01-01T00:03:19Z", type: "task_started"),
                tokenCount(timestamp: "1970-01-01T00:03:40Z"),
                taskEvent(timestamp: "1970-01-01T00:03:41Z", type: "task_complete"),
            ]
        )
        let oldLogStart = FakeAppThreadStatusFetcher(statuses: [.init(
            threadID: localID,
            executionState: .working,
            updatedAt: Date(timeIntervalSince1970: 199),
            activeSince: Date(timeIntervalSince1970: 199)
        )])
        let staleRuntime = FakeDesktopSnapshotFetcher(snapshot: .init(
            observedAt: Date(timeIntervalSince1970: 199),
            usedTokens: 1_000,
            contextWindow: 100_000,
            model: "gpt-5.6-sol",
            effort: "high",
            executionState: .working
        ))

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            selectedThread: SelectedThreadState(initialThreadID: localID),
            desktopSnapshots: staleRuntime,
            appThreadStatuses: oldLogStart,
            now: { Date(timeIntervalSince1970: 230) }
        ).fetchSessions()

        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.executionState, .idle)
        XCTAssertNil(session.activeSince)
        XCTAssertEqual(session.executionStateObservedAt, Date(timeIntervalSince1970: 221))
    }

    func testNewerDesktopStartBeatsOlderLocalRolloutCompletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let localID = "10000000-0000-4000-8000-000000000006"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('local', '\(localID)', 'Restarted local', '/tmp/TouchBar', 200, 200, 0);",
            into: databaseURL
        )
        try writeRollout(
            root: root,
            threadID: localID,
            lines: [
                tokenCount(timestamp: "1970-01-01T00:03:19Z"),
                taskEvent(timestamp: "1970-01-01T00:03:20Z", type: "task_complete"),
            ]
        )
        let newLogStart = FakeAppThreadStatusFetcher(statuses: [.init(
            threadID: localID,
            executionState: .working,
            updatedAt: Date(timeIntervalSince1970: 220),
            activeSince: Date(timeIntervalSince1970: 220)
        )])

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            selectedThread: SelectedThreadState(initialThreadID: localID),
            appThreadStatuses: newLogStart,
            now: { Date(timeIntervalSince1970: 230) }
        ).fetchSessions()

        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.executionState, .working)
        XCTAssertEqual(session.activeSince, Date(timeIntervalSince1970: 220))
        XCTAssertEqual(session.executionStateObservedAt, Date(timeIntervalSince1970: 220))
    }

    func testReadsProjectsInActivityOrderWithoutInventingLocalIdle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)

        let selectedID = "10000000-0000-4000-8000-000000000002"
        let remoteID = "10000000-0000-4000-8000-000000000003"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('local', '\(selectedID)', 'Local work', '/tmp/TouchBar', 100, 100, 0);",
            into: databaseURL
        )
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('remote-ssh-codex-managed:TestHost', '\(remoteID)', 'Room control', "
                + "'/Users/developer/codex-working/climate-agent', 190, 190, 0);",
            into: databaseURL
        )

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            selectedThread: SelectedThreadState(initialThreadID: selectedID),
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchSessions()

        XCTAssertEqual(sessions.map(\.threadID), [remoteID, selectedID])
        let local = try XCTUnwrap(sessions.first { $0.threadID == selectedID })
        let remote = try XCTUnwrap(sessions.first { $0.threadID == remoteID })
        XCTAssertEqual(local.projectName, "TouchBar")
        XCTAssertEqual(local.executionState, .unknown)
        XCTAssertFalse(local.isRemote)
        XCTAssertEqual(remote.projectName, "climate-agent")
        XCTAssertEqual(remote.hostName, "TestHost")
        XCTAssertEqual(remote.executionState, .unknown)
        XCTAssertTrue(remote.isRemote)
        XCTAssertEqual(remote.contextWindow, 0)
    }

    func testUnknownTasksUseRecentActivityWithoutRemotePreference() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let localID = "10000000-0000-4000-8000-00000000000d"
        let remoteID = "10000000-0000-4000-8000-00000000000e"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('local', '\(localID)', 'Local idle', '/tmp/local', 200, 200, 0), "
                + "('remote-ssh-codex-managed:TestHost', '\(remoteID)', 'Remote unknown', "
                + "'/tmp/remote', 190, 190, 0);",
            into: databaseURL
        )

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            now: { Date(timeIntervalSince1970: 210) }
        ).fetchSessions()

        XCTAssertEqual(sessions.map(\.threadID), [localID, remoteID])
        XCTAssertTrue(sessions.allSatisfy { $0.executionState == .unknown })
        XCTAssertFalse(sessions[0].isRemote)
        XCTAssertTrue(sessions[1].isRemote)
    }

    func testUnscopedDesktopEventMapsToTheOnlyCatalogIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let threadID = "10000000-0000-4000-8000-000000000007"
        let hostID = "remote-ssh-codex-managed:TestHost"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('\(hostID)', '\(threadID)', 'Remote work', '/tmp/remote', 199, 199, 0);",
            into: databaseURL
        )
        let statuses = FakeAppThreadStatusFetcher(statuses: [
            .init(
                unscopedThreadID: threadID,
                executionState: .working,
                updatedAt: Date(timeIntervalSince1970: 199),
                activeSince: Date(timeIntervalSince1970: 198)
            ),
        ])

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            appThreadStatuses: statuses,
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchSessions()

        XCTAssertEqual(sessions.first?.hostID, hostID)
        XCTAssertEqual(sessions.first?.executionState, .working)
    }

    func testUnscopedDesktopEventIsRejectedWhenThreadIDExistsOnMultipleHosts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let threadID = "10000000-0000-4000-8000-000000000007"
        let hostID = "remote-ssh-codex-managed:TestHost"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('local', '\(threadID)', 'Local copy', '/tmp/local', 199, 199, 0), "
                + "('\(hostID)', '\(threadID)', 'Remote copy', '/tmp/remote', 198, 198, 0);",
            into: databaseURL
        )
        let statuses = FakeAppThreadStatusFetcher(statuses: [
            .init(
                unscopedThreadID: threadID,
                executionState: .working,
                updatedAt: Date(timeIntervalSince1970: 199),
                activeSince: Date(timeIntervalSince1970: 198)
            ),
        ])

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            appThreadStatuses: statuses,
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchSessions()
        let byHost = Dictionary(uniqueKeysWithValues: sessions.map { ($0.hostID, $0) })

        XCTAssertEqual(byHost["local"]?.executionState, .unknown)
        XCTAssertEqual(byHost[hostID]?.executionState, .unknown)
    }

    func testHostRecoveryInvalidatesAnOlderRemoteRunTransition() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let threadID = "10000000-0000-4000-8000-000000000007"
        let hostID = "remote-ssh-codex-managed:TestHost"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('\(hostID)', '\(threadID)', 'Remote work', '/tmp/remote', 199, 199, 0);",
            into: databaseURL
        )
        let statuses = FakeAppThreadStatusFetcher(
            statuses: [.init(
                threadID: threadID,
                hostID: hostID,
                executionState: .working,
                updatedAt: Date(timeIntervalSince1970: 198),
                activeSince: Date(timeIntervalSince1970: 197)
            )],
            hostStatuses: [.init(
                hostID: hostID,
                stage: .ready,
                updatedAt: Date(timeIntervalSince1970: 199)
            )]
        )

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            appThreadStatuses: statuses,
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchSessions()

        XCTAssertEqual(sessions.first?.executionState, .unknown)
    }

    func testCompositeIdentityIsolatesSameThreadAcrossAllSupportedHostKinds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let threadID = "10000000-0000-4000-8000-000000000008"
        let sshHost = "remote-ssh-codex-managed:TestHost"
        let pairedHost = "remote-control:environment-secret-123"
        try insert(
            "INSERT INTO local_thread_catalog_hosts VALUES "
                + "('\(pairedHost)', 'remote-control'); "
                + "INSERT INTO local_thread_catalog VALUES "
                + "('local', '\(threadID)', 'Local copy', '/tmp/local', 197, 197, 0), "
                + "('\(sshHost)', '\(threadID)', 'SSH copy', '/tmp/ssh', 198, 198, 0), "
                + "('\(pairedHost)', '\(threadID)', 'Paired copy', '/tmp/paired', 199, 199, 0);",
            into: databaseURL
        )
        let statuses = FakeAppThreadStatusFetcher(statuses: [
            .init(
                threadID: threadID,
                hostID: sshHost,
                executionState: .working,
                updatedAt: Date(timeIntervalSince1970: 199),
                activeSince: Date(timeIntervalSince1970: 198)
            ),
            .init(
                threadID: threadID,
                hostID: pairedHost,
                executionState: .error,
                updatedAt: Date(timeIntervalSince1970: 199),
                activeSince: nil
            ),
        ])

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            appThreadStatuses: statuses,
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchSessions()
        let byHost = Dictionary(uniqueKeysWithValues: sessions.map { ($0.hostID, $0) })

        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(byHost["local"]?.hostKind, .local)
        XCTAssertEqual(byHost["local"]?.executionState, .unknown)
        XCTAssertEqual(byHost[sshHost]?.hostKind, .ssh)
        XCTAssertEqual(byHost[sshHost]?.executionState, .working)
        XCTAssertEqual(byHost[pairedHost]?.hostKind, .remoteControl)
        XCTAssertEqual(byHost[pairedHost]?.executionState, .error)
        XCTAssertEqual(byHost[pairedHost]?.hostName, "Remote")
        XCTAssertFalse(byHost[pairedHost]?.hostName?.contains("environment-secret") ?? true)
    }

    func testExpiredRuntimeDropsActiveStateAndContextBeforeModelMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let threadID = "10000000-0000-4000-8000-000000000009"
        let hostID = "remote-ssh-codex-managed:TestHost"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('\(hostID)', '\(threadID)', 'Stale runtime', '/tmp/stale', 190, 190, 0);",
            into: databaseURL
        )
        let staleRuntime = FakeDesktopSnapshotFetcher(snapshot: .init(
            observedAt: Date(timeIntervalSince1970: 100),
            usedTokens: 90_000,
            contextWindow: 100_000,
            model: "gpt-5.6-sol",
            effort: "high",
            executionState: .working,
            isCompactingContext: true
        ))

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            desktopSnapshots: staleRuntime,
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchSessions()
        let session = try XCTUnwrap(sessions.first)

        XCTAssertEqual(session.executionState, .unknown)
        XCTAssertNil(session.activeSince)
        XCTAssertFalse(session.isCompactingContext)
        XCTAssertEqual(session.contextWindow, 0)
        XCTAssertEqual(session.usedTokens, 0)
        XCTAssertEqual(session.model, "gpt-5.6-sol")
    }

    func testUnknownFutureHostKindIsPreservedWithoutExposingItsRouteID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let hostID = "future-transport:private-routing-value"
        let threadID = "10000000-0000-4000-8000-00000000000b"
        try insert(
            "INSERT INTO local_thread_catalog_hosts VALUES "
                + "('\(hostID)', 'future-transport'); "
                + "INSERT INTO local_thread_catalog VALUES "
                + "('\(hostID)', '\(threadID)', 'Future host', '/tmp/future', 199, 199, 0);",
            into: databaseURL
        )

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchSessions()
        let session = try XCTUnwrap(sessions.first)

        XCTAssertEqual(session.hostKind, .unknown("future-transport"))
        XCTAssertEqual(session.hostName, "Remote")
        XCTAssertFalse(session.hostName?.contains("private-routing-value") ?? true)
        XCTAssertTrue(session.isRemote)
    }

    func testPersistedModelMetadataExpiresInsteadOfLivingForever() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let threadID = "10000000-0000-4000-8000-00000000000c"
        try insert(
            "INSERT INTO local_thread_catalog VALUES "
                + "('local', '\(threadID)', 'Old local task', '/tmp/old', 100, 100, 0);",
            into: databaseURL
        )
        let metadata = FakeThreadMetadataReader(values: [
            threadID: CodexThreadMetadata(
                threadID: threadID,
                title: "Old local task",
                rolloutURL: root.appending(path: "old.jsonl"),
                model: "gpt-old",
                effort: "high"
            )
        ])

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            threadMetadata: metadata,
            now: { Date(timeIntervalSince1970: 500) }
        ).fetchSessions()
        let session = try XCTUnwrap(sessions.first)

        XCTAssertNil(session.model)
        XCTAssertNil(session.effort)
        XCTAssertNil(session.modelObservedAt)
    }

    func testPendingApprovalMatchesTheExactHostIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "codex-dev.db")
        try makeCatalog(at: databaseURL)
        let threadID = "10000000-0000-4000-8000-00000000000a"
        let sshHost = "remote-ssh-codex-managed:TestHost"
        let pairedHost = "remote-control:private-environment"
        try insert(
            "INSERT INTO local_thread_catalog_hosts VALUES "
                + "('\(pairedHost)', 'remote-control'); "
                + "INSERT INTO local_thread_catalog VALUES "
                + "('\(sshHost)', '\(threadID)', 'SSH', '/tmp/ssh', 199, 199, 0), "
                + "('\(pairedHost)', '\(threadID)', 'Paired', '/tmp/paired', 198, 198, 0);",
            into: databaseURL
        )
        let store = ConversationApprovalStore(url: root.appending(path: "approvals.json"))
        try store.enqueue(ConversationApproval(
            threadID: threadID,
            hostID: sshHost,
            question: "Continue?",
            createdAt: Date(timeIntervalSince1970: 190),
            expiresAt: Date(timeIntervalSince1970: 220)
        ))

        let sessions = try await CodexSessionCatalogProvider(
            root: root,
            databaseURL: databaseURL,
            approvalStore: store,
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchSessions()
        let byHost = Dictionary(uniqueKeysWithValues: sessions.map { ($0.hostID, $0) })

        XCTAssertEqual(byHost[sshHost]?.executionState, .waiting)
        XCTAssertEqual(byHost[pairedHost]?.executionState, .unknown)
    }

    private func makeCatalog(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE local_thread_catalog_hosts (host_id TEXT PRIMARY KEY, host_kind TEXT NOT NULL);
        CREATE TABLE local_thread_catalog (
            host_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            display_title TEXT,
            cwd TEXT,
            source_recency_at REAL,
            source_updated_at REAL,
            missing_candidate INTEGER
        );
        INSERT INTO local_thread_catalog_hosts VALUES ('local', 'local');
        INSERT INTO local_thread_catalog_hosts VALUES ('remote-ssh-codex-managed:TestHost', 'ssh');
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func insert(_ sql: String, into url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func writeRollout(root: URL, threadID: String, lines: [String]) throws {
        let directory = root.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "rollout-test-\(threadID).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(
            to: file,
            atomically: true,
            encoding: .utf8
        )
    }

    private func taskEvent(timestamp: String, type: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"\#(type)"}}"#
    }

    private func tokenCount(timestamp: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1000},"last_token_usage":{"total_tokens":1000},"model_context_window":100000}}}"#
    }
}

private actor FakeDesktopSnapshotFetcher: DesktopThreadSnapshotFetching {
    private let snapshot: CodexDesktopThreadSnapshot
    private(set) var requests: [String] = []

    init(snapshot: CodexDesktopThreadSnapshot) { self.snapshot = snapshot }

    func fetchThreadSnapshot(
        threadID: String,
        hostID: String
    ) async throws -> CodexDesktopThreadSnapshot {
        requests.append("\(hostID)|\(threadID)")
        return CodexDesktopThreadSnapshot(
            identity: TaskIdentity(hostID: hostID, threadID: threadID),
            source: snapshot.source,
            observedAt: snapshot.observedAt,
            usedTokens: snapshot.usedTokens,
            contextWindow: snapshot.contextWindow,
            model: snapshot.model,
            effort: snapshot.effort,
            serviceTier: snapshot.serviceTier,
            executionState: snapshot.executionState,
            isCompactingContext: snapshot.isCompactingContext
        )
    }
}

private actor RecordingDesktopSnapshotCache: DesktopThreadSnapshotCaching {
    private let snapshot: CodexDesktopThreadSnapshot
    private(set) var maximumAges: [TimeInterval] = []

    init(snapshot: CodexDesktopThreadSnapshot) { self.snapshot = snapshot }

    func cachedThreadSnapshot(
        threadID: String,
        hostID: String
    ) async -> CodexDesktopThreadSnapshot? {
        snapshot
    }

    func fetchThreadSnapshot(
        threadID: String,
        hostID: String
    ) async throws -> CodexDesktopThreadSnapshot {
        snapshot
    }

    func fetchThreadSnapshot(
        threadID: String,
        hostID: String,
        maximumAge: TimeInterval
    ) async throws -> CodexDesktopThreadSnapshot {
        maximumAges.append(maximumAge)
        return snapshot
    }
}

private actor FakeAppThreadStatusFetcher: CodexAppThreadStatusFetching {
    private let statuses: [CodexAppThreadStatus]
    private let hostStatuses: [CodexRemoteHostStatus]
    private(set) var fetchCount = 0

    init(
        statuses: [CodexAppThreadStatus],
        hostStatuses: [CodexRemoteHostStatus] = []
    ) {
        self.statuses = statuses
        self.hostStatuses = hostStatuses
    }

    func fetchThreadStatuses() async throws -> [CodexAppThreadStatus] {
        fetchCount += 1
        return statuses
    }

    func fetchRemoteHostStatuses() async throws -> [CodexRemoteHostStatus] {
        hostStatuses
    }
}

private struct FakeThreadMetadataReader: ThreadMetadataReading, Sendable {
    let values: [String: CodexThreadMetadata]

    func metadata(for threadID: String) throws -> CodexThreadMetadata? {
        values[threadID]
    }
}
