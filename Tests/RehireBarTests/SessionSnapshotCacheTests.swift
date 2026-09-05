import Foundation
import XCTest
@testable import RehireBar

final class SessionSnapshotCacheTests: XCTestCase {
    func testUnchangedRolloutIsStableAndAppendUpdatesSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let sessions = root.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let threadID = "10000000-0000-4000-8000-000000000001"
        let file = sessions.appending(path: "rollout-cache-\(threadID).jsonl")
        let first = tokenCount(timestamp: "2026-07-12T00:01:01Z", used: 10)
        try (first + "\n").write(to: file, atomically: true, encoding: .utf8)
        let candidate = SafeSessionCandidate(file: file, allowedRoot: sessions)
        let cache = SessionSnapshotCache()

        let initial = await cache.snapshot(in: candidate)
        let unchanged = await cache.snapshot(in: candidate)
        let appendedLine = tokenCount(
            timestamp: "2026-07-12T00:01:02Z",
            used: 20
        ) + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendedLine.utf8))
        try handle.close()
        let updated = await cache.snapshot(in: candidate)

        XCTAssertEqual(initial?.usedTokens, 10)
        XCTAssertEqual(unchanged?.usedTokens, 10)
        XCTAssertEqual(updated?.usedTokens, 20)
    }

    func testAppendedCompletionUpdatesRuntimeWithoutLosingTokenState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let sessions = root.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let threadID = "10000000-0000-4000-8000-000000000001"
        let file = sessions.appending(path: "rollout-state-\(threadID).jsonl")
        let initialLines = [
            tokenCount(timestamp: "2026-07-12T00:01:01Z", used: 10),
            taskEvent(timestamp: "2026-07-12T00:01:02Z", type: "task_started"),
        ]
        try (initialLines.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let candidate = SafeSessionCandidate(file: file, allowedRoot: sessions)
        let cache = SessionSnapshotCache()

        let running = await cache.snapshot(in: candidate)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((taskEvent(
            timestamp: "2026-07-12T00:02:00Z",
            type: "task_complete"
        ) + "\n").utf8))
        try handle.close()
        let completed = await cache.snapshot(in: candidate)

        XCTAssertEqual(running?.executionState, .working)
        XCTAssertEqual(completed?.executionState, .idle)
        XCTAssertEqual(completed?.usedTokens, 10)
    }

    private func tokenCount(timestamp: String, used: Int) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":\#(used)},"model_context_window":100}}}"#
    }


    private func taskEvent(timestamp: String, type: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"\#(type)"}}"#
    }
}
