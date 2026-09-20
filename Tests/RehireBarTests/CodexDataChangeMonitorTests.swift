import Foundation
import XCTest
@testable import RehireBar

@MainActor
final class CodexDataChangeMonitorTests: XCTestCase {
    func testReplacementReattachesWatcherToTheNewFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "catalog.sqlite")
        try Data().write(to: file)
        let monitor = CodexDataChangeMonitor(root: root, catalogDatabaseURL: file,
            metadataDatabaseURL: root.appending(path: "metadata"), logRoot: root.appending(path: "logs"),
            agentStatusDirectory: root.appending(path: "agents"), debounceInterval: 0.01, minimumEventInterval: 0.01)
        var events = 0
        monitor.start { events += 1 }
        defer { monitor.stop() }
        func waitForEvent(after count: Int) async throws {
            for _ in 0..<200 {
                if events > count { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("The replacement file must still produce change events")
        }
        try Data("replacement".utf8).write(to: file, options: .atomic)
        try await waitForEvent(after: 0)
        // Let any coalesced directory event drain before testing the new inode.
        try await Task.sleep(for: .milliseconds(100))
        let before = events
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("append".utf8))
        try handle.close()
        try await waitForEvent(after: before)
    }

    func testWatchedPathsIncludeDatabasesWalRolloutAndDesktopLog() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let sessions = root.appending(path: "sessions")
        let archives = root.appending(path: "archived_sessions")
        let sqlite = root.appending(path: "sqlite")
        let logs = root.appending(path: "logs")
        let agents = root.appending(path: "Application Support/agents")
        for directory in [sessions, archives, sqlite, logs, agents] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = sqlite.appending(path: "codex-dev.db")
        let metadata = root.appending(path: "state_5.sqlite")
        let rollout = sessions.appending(path: "active.jsonl")
        let log = logs.appending(path: "desktop.log")
        for file in [catalog, metadata, rollout, log] { FileManager.default.createFile(atPath: file.path, contents: Data()) }

        let paths = Set(CodexDataChangeMonitor.watchedPaths(
            root: root,
            catalogDatabaseURL: catalog,
            metadataDatabaseURL: metadata,
            logRoot: logs,
            agentStatusDirectory: agents
        ).map(\.standardizedFileURL.path))

        XCTAssertTrue(paths.contains(catalog.path))
        XCTAssertTrue(paths.contains(catalog.path + "-wal"))
        XCTAssertTrue(paths.contains(metadata.path))
        XCTAssertTrue(paths.contains(metadata.path + "-wal"))
        XCTAssertTrue(paths.contains(rollout.path))
        XCTAssertTrue(paths.contains(log.path))
        XCTAssertTrue(paths.contains(agents.path))
    }
}
