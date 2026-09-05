import Foundation
import SQLite3
import XCTest
@testable import RehireBar

final class SessionMonitoringTests: XCTestCase {
    func testSwitchingToIdleTaskKeepsBothRunningTasksInTheSameProjectFirst() async throws {
        let first = snapshot(id: "task-a", state: .working, tokens: 100)
        let second = snapshot(id: "task-b", state: .working, tokens: 200)
        let idle = snapshot(id: "task-c", state: .idle, tokens: 300)
        let collection = MonitoringCollection(snapshots: [first, second, idle])

        let before = try await LiveSessionStatusProvider(
            session: MonitoringSession(snapshot: first), sessions: collection,
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchStatus()
        let after = try await LiveSessionStatusProvider(
            session: MonitoringSession(snapshot: idle), sessions: collection,
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchStatus()

        XCTAssertEqual(after.sessions.map(\.identity), before.sessions.map(\.identity))
        XCTAssertEqual(after.sessions.map(\.threadID), ["task-a", "task-b", "task-c"])
        XCTAssertEqual(after.sessions.map(\.executionState), [.working, .working, .idle])
        XCTAssertEqual(after.sessions.map(\.usedTokens), [100, 200, 300])
        XCTAssertEqual(after.session?.identity, first.identity)
    }

    func testFocusedRolloutCannotOverwriteNewerRuntimeModelContextOrCompaction() async throws {
        let focused = CurrentSessionSnapshot(
            sessionID: "rollout", threadID: "task-a", usedTokens: 100,
            contextWindow: 1_000, model: "old-model", effort: "low",
            observedAt: Date(timeIntervalSince1970: 190),
            activeSince: Date(timeIntervalSince1970: 180), isCompactingContext: true,
            executionState: .working
        )
        let live = snapshot(id: "task-a", state: .idle, tokens: 200)
        let status = try await LiveSessionStatusProvider(
            session: MonitoringSession(snapshot: focused),
            sessions: MonitoringCollection(snapshots: [live]),
            now: { Date(timeIntervalSince1970: 200) }
        ).fetchStatus()

        let task = try XCTUnwrap(status.sessions.first)
        XCTAssertEqual(task.usedTokens, live.usedTokens)
        XCTAssertEqual(task.model, live.model)
        XCTAssertEqual(task.effort, live.effort)
        XCTAssertEqual(task.executionState, .idle)
        XCTAssertNil(task.activeSince)
        XCTAssertFalse(task.isCompactingContext)
    }

    func testCatalogKeepsSameProjectTasksBeyondEightAndPollsOutsideFirstFour() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<12).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        let database = root.appending(path: "catalog.db")
        try makeCatalog(at: database, ids: ids)
        let focus = SelectedThreadState(initialThreadID: ids[0])
        let runtime = MonitoringRuntimeCache(workingIDs: Set(ids.suffix(2)))
        let provider = CodexSessionCatalogProvider(
            root: root, databaseURL: database, selectedThread: focus,
            desktopSnapshots: runtime, now: { Date(timeIntervalSince1970: 200) },
            minimumRuntimeReadInterval: 0
        )

        let initial = try await provider.fetchSessions()
        XCTAssertEqual(initial.count, ids.count)
        XCTAssertTrue(initial.allSatisfy { $0.projectName == "SameProject" })
        // Each refresh has a bounded IPC budget, but later rounds must reach
        // background tasks even when their catalog recency has not changed.
        for _ in 0..<6 {
            for _ in 0..<32 { await Task.yield() }
            _ = try await provider.fetchSessions()
        }
        let before = try await provider.fetchSessions()
        focus.update(threadID: ids[1])
        let after = try await provider.fetchSessions()
        let requests = await runtime.requestedIDs

        XCTAssertEqual(Set(requests), Set(ids))
        XCTAssertEqual(Set(after.filter { $0.executionState == .working }.compactMap(\.threadID)), Set(ids.suffix(2)))
        XCTAssertEqual(after.map(\.identity), before.map(\.identity))
        XCTAssertEqual(after.prefix(2).map(\.executionState), [.working, .working])
        XCTAssertEqual(after.count, ids.count)
    }

    func testFocusingAnOldTaskCannotReviveAnExpiredRunningClaim() async throws {
        let oldTask = snapshot(id: "old-task", state: .working, tokens: 100)
        let status = try await LiveSessionStatusProvider(
            session: MonitoringSession(snapshot: oldTask),
            sessions: MonitoringCollection(snapshots: []),
            now: { Date(timeIntervalSince1970: 600) }
        ).fetchStatus()

        XCTAssertEqual(status.session?.executionState, .unknown)
        XCTAssertNil(status.session?.activeSince)
        XCTAssertEqual(status.session?.contextWindow, 0)
        XCTAssertNil(status.session?.model)
    }

    func testBurstOfFileRefreshesDoesNotFloodRuntimeDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<8).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        let database = root.appending(path: "catalog.db")
        try makeCatalog(at: database, ids: ids)
        let runtime = MonitoringRuntimeCache(workingIDs: [])
        let provider = CodexSessionCatalogProvider(
            root: root, databaseURL: database, desktopSnapshots: runtime,
            now: { Date(timeIntervalSince1970: 200) }
        )

        for _ in 0..<20 {
            _ = try await provider.fetchSessions()
            await Task.yield()
        }

        let requests = await runtime.requestedIDs
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(Set(requests).count, 4)
    }

    func testOlderIdleRuntimeCannotReplaceNewerTaskStart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "00000000-0000-4000-8000-000000000001"
        let database = root.appending(path: "catalog.db")
        try makeCatalog(at: database, ids: [id])
        let provider = CodexSessionCatalogProvider(
            root: root, databaseURL: database,
            desktopSnapshots: OlderIdleRuntime(),
            appThreadStatuses: MonitoringThreadStatuses(id: id),
            now: { Date(timeIntervalSince1970: 200) }
        )

        let tasks = try await provider.fetchSessions()
        let task = try XCTUnwrap(tasks.first)

        XCTAssertEqual(task.executionState, .working)
        XCTAssertEqual(task.executionStateObservedAt, Date(timeIntervalSince1970: 199))
    }

    func testCatalogProjectIdentityAndActivitySurviveMetadataAndRuntimeRefreshes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = ["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"]
        let databaseURL = root.appending(path: "catalog.db")
        try makeCatalog(at: databaseURL, ids: ids)
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        let update = """
        ALTER TABLE local_thread_catalog ADD COLUMN project_id TEXT;
        UPDATE local_thread_catalog SET project_id = 'logical-project';
        UPDATE local_thread_catalog SET source_recency_at = 10, source_updated_at = 199
            WHERE thread_id = '\(ids[0])';
        UPDATE local_thread_catalog SET source_recency_at = 180, source_updated_at = 181,
            cwd = '/tmp/SiblingWorktree' WHERE thread_id = '\(ids[1])';
        """
        XCTAssertEqual(sqlite3_exec(database, update, nil, nil, nil), SQLITE_OK)
        let runtime = MonitoringRuntimeCache(workingIDs: [])
        for id in ids { _ = try await runtime.fetchThreadSnapshot(threadID: id, hostID: "local") }
        let provider = CodexSessionCatalogProvider(
            root: root, databaseURL: databaseURL, desktopSnapshots: runtime,
            now: { Date(timeIntervalSince1970: 200) }
        )

        let tasks = try await provider.fetchSessions()

        XCTAssertEqual(tasks.map(\.threadID), [ids[1], ids[0]])
        XCTAssertEqual(tasks.map(\.projectID), ["logical-project", "logical-project"])
        XCTAssertEqual(tasks.map(\.lastActivityAt), [Date(timeIntervalSince1970: 180), Date(timeIntervalSince1970: 10)])
        XCTAssertTrue(tasks.allSatisfy { $0.observedAt == Date(timeIntervalSince1970: 200) })
    }

    private func snapshot(id: String, state: SessionExecutionState, tokens: Int) -> CurrentSessionSnapshot {
        CurrentSessionSnapshot(
            sessionID: id, threadID: id, title: id, usedTokens: tokens,
            contextWindow: 1_000, model: "current-model", effort: "high",
            observedAt: Date(timeIntervalSince1970: 200),
            activeSince: state == .working ? Date(timeIntervalSince1970: 190) : nil,
            projectName: "SameProject",
            executionStateObservedAt: Date(timeIntervalSince1970: 200), executionState: state
        )
    }

    private func makeCatalog(at url: URL, ids: [String]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        let rows = ids.enumerated().map { index, id in
            "('local', '\(id)', 'Task \(index)', '/tmp/SameProject', \(190 - index), \(190 - index), 0)"
        }.joined(separator: ",")
        let sql = """
        CREATE TABLE local_thread_catalog_hosts (host_id TEXT PRIMARY KEY, host_kind TEXT NOT NULL);
        CREATE TABLE local_thread_catalog (
            host_id TEXT, thread_id TEXT, display_title TEXT, cwd TEXT,
            source_recency_at REAL, source_updated_at REAL, missing_candidate INTEGER
        );
        INSERT INTO local_thread_catalog_hosts VALUES ('local', 'local');
        INSERT INTO local_thread_catalog VALUES \(rows);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private struct MonitoringSession: SessionFetching {
    let snapshot: CurrentSessionSnapshot
    func fetchSession() async throws -> CurrentSessionSnapshot { snapshot }
}

private struct MonitoringCollection: SessionCollectionFetching {
    let snapshots: [CurrentSessionSnapshot]
    func fetchSessions() async throws -> [CurrentSessionSnapshot] { snapshots }
}

private actor MonitoringRuntimeCache: DesktopThreadSnapshotCaching {
    let workingIDs: Set<String>
    private var snapshots: [TaskIdentity: CodexDesktopThreadSnapshot] = [:]
    private(set) var requestedIDs: [String] = []

    init(workingIDs: Set<String>) { self.workingIDs = workingIDs }

    func cachedThreadSnapshot(threadID: String, hostID: String) async -> CodexDesktopThreadSnapshot? {
        snapshots[TaskIdentity(hostID: hostID, threadID: threadID)]
    }

    func fetchThreadSnapshot(threadID: String, hostID: String) async throws -> CodexDesktopThreadSnapshot {
        let identity = TaskIdentity(hostID: hostID, threadID: threadID)
        requestedIDs.append(threadID)
        let snapshot = CodexDesktopThreadSnapshot(
            identity: identity, observedAt: Date(timeIntervalSince1970: 200),
            usedTokens: nil, contextWindow: nil, model: nil, effort: nil,
            executionState: workingIDs.contains(threadID) ? .working : .idle
        )
        snapshots[identity] = snapshot
        return snapshot
    }

    func fetchThreadSnapshot(
        threadID: String, hostID: String, maximumAge: TimeInterval
    ) async throws -> CodexDesktopThreadSnapshot {
        try await fetchThreadSnapshot(threadID: threadID, hostID: hostID)
    }
}

private struct OlderIdleRuntime: DesktopThreadSnapshotFetching {
    func fetchThreadSnapshot(threadID: String, hostID: String) async throws -> CodexDesktopThreadSnapshot {
        .init(
            identity: TaskIdentity(hostID: hostID, threadID: threadID),
            observedAt: Date(timeIntervalSince1970: 198), usedTokens: nil,
            contextWindow: nil, model: nil, effort: nil, executionState: .idle
        )
    }
}

private struct MonitoringThreadStatuses: CodexAppThreadStatusFetching {
    let id: String
    func fetchThreadStatuses() async throws -> [CodexAppThreadStatus] {
        [.init(
            threadID: id, executionState: .working,
            updatedAt: Date(timeIntervalSince1970: 199),
            activeSince: Date(timeIntervalSince1970: 190)
        )]
    }
}
