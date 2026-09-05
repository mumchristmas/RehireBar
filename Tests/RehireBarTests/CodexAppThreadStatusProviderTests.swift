import Foundation
import XCTest
@testable import RehireBar

final class CodexAppThreadStatusProviderTests: XCTestCase {
    func testDecodesOnlyTurnBoundaryMetadata() throws {
        let firstID = "10000000-0000-4000-8000-000000000003"
        let secondID = "10000000-0000-4000-8000-000000000004"
        let log = """
        2026-09-02T16:38:56.298Z info [AppServerConnection] response_routed conversationId=\(firstID) errorCode=null method=turn/start
        2026-09-02T16:40:00.000Z info reasoning summary conversationId=\(firstID) text=private-content
        2026-09-02T16:40:30.000Z error Request failed conversationId=\(firstID) method=thread/unsubscribe
        2026-09-02T16:41:01.000Z info [electron-message-handler] [desktop-notifications] show turn-complete conversationId=\(firstID)
        2026-09-02T16:42:02.000Z info [AppServerConnection] response_routed conversationId=\(firstID) errorCode=null method=turn/start
        2026-09-02T16:43:03.000Z error [AppServerConnection] response_routed conversationId=\(secondID) errorCode=transport method=turn/start
        """

        let events = CodexDesktopLogStatusProvider.decodeEvents(from: Data(log.utf8))

        XCTAssertEqual(events.map(\.executionState), [.working, .idle, .working, .error])
        XCTAssertEqual(events.map(\.threadID), [firstID, firstID, firstID, secondID])
        XCTAssertTrue(events.allSatisfy { $0.hostID == nil })
        XCTAssertTrue(events.allSatisfy { $0.identity == nil })
        XCTAssertEqual(events[2].timestamp, try date("2026-09-02T16:42:02.000Z"))
    }

    func testReturnsLatestEventAndRunningStartTimePerThread() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = "10000000-0000-4000-8000-000000000003"
        let secondID = "10000000-0000-4000-8000-000000000004"
        let log = """
        2026-09-02T16:38:56.298Z info conversationId=\(firstID) errorCode=null method=turn/start
        2026-09-02T16:41:01.000Z info [desktop-notifications] show turn-complete conversationId=\(firstID)
        2026-09-02T16:42:02.000Z info conversationId=\(firstID) errorCode=null method=turn/start
        2026-09-02T16:42:03.250Z info conversationId=\(firstID) errorCode=null method=thread/name/set
        2026-09-02T16:43:03.000Z info conversationId=\(secondID) latestTurnStatus=completed
        """
        try Data(log.utf8).write(to: root.appending(path: "desktop.log"))
        let provider = CodexDesktopLogStatusProvider(logRoot: root, maximumFiles: 1)

        let statuses = try await provider.fetchThreadStatuses()
        let byID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.threadID, $0) })

        XCTAssertEqual(byID[firstID]?.executionState, .working)
        XCTAssertEqual(byID[firstID]?.activeSince, try date("2026-09-02T16:42:02.000Z"))
        XCTAssertEqual(byID[secondID]?.executionState, .idle)
        XCTAssertNil(byID[secondID]?.activeSince)
    }

    func testRepeatedReadHandlesAppendAndTruncation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let threadID = "10000000-0000-4000-8000-000000000003"
        let file = root.appending(path: "desktop.log")
        let started = "2026-09-02T16:38:56.298Z info conversationId=\(threadID) errorCode=null method=turn/start"
        try Data(started.utf8).write(to: file)
        let provider = CodexDesktopLogStatusProvider(logRoot: root, maximumFiles: 1)

        let first = try await provider.fetchThreadStatuses()
        let unchanged = try await provider.fetchThreadStatuses()
        let completed = "\n2026-09-02T16:41:01.000Z info [desktop-notifications] show turn-complete conversationId=\(threadID)"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(completed.utf8))
        try handle.close()
        let second = try await provider.fetchThreadStatuses()

        XCTAssertEqual(first.first?.executionState, .working)
        XCTAssertEqual(unchanged.first?.executionState, .working)
        XCTAssertEqual(second.first?.executionState, .idle)

        let restarted = "2026-09-02T17:00:00.000Z info conversationId=\(threadID) errorCode=null method=turn/start"
        try Data(restarted.utf8).write(to: file, options: .atomic)
        let afterTruncation = try await provider.fetchThreadStatuses()
        XCTAssertEqual(afterTruncation.first?.executionState, .working)
    }

    func testRemoteHostStaysSynchronizingUntilDesktopRecoveryCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = "remote-ssh-codex-managed:TestHost"
        let file = root.appending(path: "desktop.log")
        let disconnected = """
        2026-09-03T04:10:16.002Z info [AppServerConnection] app_server_connection.state_changed cause=transport_closed hostId=\(hostID) next=error previous=connected
        2026-09-03T04:10:17.421Z info [AppServerConnection] app_server_connection.state_changed cause=start_process hostId=\(hostID) next=connecting previous=error
        2026-09-03T04:10:54.997Z info [AppServerConnection] app_server_connection.state_changed cause=post_initialize_connection_state hostId=\(hostID) next=connected previous=connecting
        """
        try Data(disconnected.utf8).write(to: file)
        let provider = CodexDesktopLogStatusProvider(logRoot: root, maximumFiles: 1)

        let duringRecovery = try await provider.fetchRemoteHostStatuses()
        XCTAssertEqual(duringRecovery, [.init(
            hostID: hostID,
            isSynchronizing: true,
            updatedAt: try date("2026-09-03T04:10:54.997Z")
        )])

        let completed = "\n2026-09-03T04:10:55.132Z info [electron-message-handler] websocket_reconnect_recovery_done hostId=\(hostID) refreshRecentConversationsFailed=false\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(completed.utf8))
        try handle.close()

        let afterRecovery = try await provider.fetchRemoteHostStatuses()
        XCTAssertEqual(afterRecovery, [.init(
            hostID: hostID,
            isSynchronizing: false,
            updatedAt: try date("2026-09-03T04:10:55.132Z")
        )])
    }

    func testThreadEventsWithSameIDRemainIsolatedByHost() throws {
        let threadID = "10000000-0000-4000-8000-000000000003"
        let log = """
        2026-09-03T04:10:16.002Z info hostId=local conversationId=\(threadID) errorCode=null method=turn/start
        2026-09-03T04:10:17.002Z info hostId=remote-control:paired conversationId=\(threadID) latestTurnStatus=completed
        """

        let events = CodexDesktopLogStatusProvider.decodeEvents(from: Data(log.utf8))
        let byIdentity = Dictionary(uniqueKeysWithValues: events.map { ($0.identity, $0) })

        XCTAssertEqual(
            byIdentity[TaskIdentity(hostID: "local", threadID: threadID)]?.executionState,
            .working
        )
        XCTAssertEqual(
            byIdentity[
                TaskIdentity(hostID: "remote-control:paired", threadID: threadID)
            ]?.executionState,
            .idle
        )
    }

    func testReadsOnlyNewestDesktopProcessGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldID = "10000000-0000-4000-8000-000000000003"
        let currentID = "10000000-0000-4000-8000-000000000004"
        let old = root.appending(path:
            "codex-desktop-11111111-1111-1111-1111-111111111111-100-t0-i1-000000-0.log"
        )
        let current = root.appending(path:
            "codex-desktop-22222222-2222-2222-2222-222222222222-200-t0-i1-000000-0.log"
        )
        try Data(
            "2026-09-02T16:38:56.298Z info conversationId=\(oldID) errorCode=null method=turn/start\n".utf8
        ).write(to: old)
        try Data(
            "2026-09-02T16:40:00.000Z info conversationId=\(currentID) latestTurnStatus=completed\n".utf8
        ).write(to: current)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: current.path
        )

        let statuses = try await CodexDesktopLogStatusProvider(
            logRoot: root,
            maximumFiles: 6
        ).fetchThreadStatuses()

        XCTAssertEqual(statuses.map(\.threadID), [currentID])
        XCTAssertEqual(statuses.first?.executionState, .idle)
    }

    func testRemoteControlHostOfflineRecoveryLifecycleUsesSyncUntilSuccessfulRecovery() throws {
        let hostID = "remote-control:environment-private"
        let log = """
        2026-09-03T04:10:16.002Z info app_server_connection.state_changed hostId=\(hostID) next=offline previous=connected
        2026-09-03T04:10:17.002Z info app_server_connection.state_changed hostId=\(hostID) next=connecting previous=offline
        2026-09-03T04:10:18.002Z info app_server_connection.state_changed hostId=\(hostID) next=connected previous=connecting
        2026-09-03T04:10:19.002Z info websocket_reconnect_recovery_done hostId=\(hostID) refreshRecentConversationsFailed=true
        2026-09-03T04:10:20.002Z info websocket_reconnect_recovery_done hostId=\(hostID) refreshRecentConversationsFailed=false
        """

        let events = CodexDesktopLogStatusProvider.decodeHostEvents(from: Data(log.utf8))

        XCTAssertEqual(events.map(\.isSynchronizing), [true, true, true, true, false])
        XCTAssertEqual(
            events.map(\.stage),
            [.offline, .connecting, .recovering, .recovering, .ready]
        )
        XCTAssertTrue(events.allSatisfy { $0.hostID == hostID })
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value))
    }
}
