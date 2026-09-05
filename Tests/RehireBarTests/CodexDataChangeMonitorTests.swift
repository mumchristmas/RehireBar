import Foundation
import XCTest
@testable import RehireBar

@MainActor
final class CodexDataChangeMonitorTests: XCTestCase {
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
