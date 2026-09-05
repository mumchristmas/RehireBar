import Foundation
import XCTest
@testable import RehireBar

final class CurrentSessionProviderTests: XCTestCase {
    func testNewestSessionUsesLastTokenUsageAndSameFileMetadata() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([
            turnContext(timestamp: "2026-07-12T00:00:00Z", model: "gpt-old", effort: "low"),
            tokenCount(timestamp: "2026-07-12T00:00:01Z", used: 12_000, cumulative: 900_000, window: 200_000),
        ], to: root.appending(path: "sessions/old.jsonl"))
        try write([
            sessionMeta(threadID: "10000000-0000-4000-8000-000000000001"),
            turnContext(timestamp: "2026-07-12T00:01:00Z", model: "gpt-5.6-sol", effort: "medium"),
            tokenCount(timestamp: "2026-07-12T00:01:01Z", used: 98_321, cumulative: 20_000_000, window: 258_400),
        ], to: root.appending(path: "sessions/new.jsonl"))

        let snapshot = try await CurrentSessionProvider(
            root: root,
            now: { sessionTestDate("2026-07-12T00:01:30Z") }
        ).fetchSession()

        XCTAssertEqual(snapshot.usedTokens, 98_321)
        XCTAssertEqual(snapshot.contextWindow, 258_400)
        XCTAssertEqual(snapshot.model, "gpt-5.6-sol")
        XCTAssertEqual(snapshot.effort, "medium")
        XCTAssertNil(snapshot.serviceTier)
        XCTAssertEqual(snapshot.threadID, "10000000-0000-4000-8000-000000000001")
        XCTAssertTrue(snapshot.sessionID.hasSuffix("new.jsonl"))
    }

    func testMetadataDoesNotCrossSessionFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([
            turnContext(timestamp: "2026-07-12T00:00:00Z", model: "wrong-model", effort: "high"),
        ], to: root.appending(path: "sessions/metadata-only.jsonl"))
        try write([
            tokenCount(timestamp: "2026-07-12T00:01:00Z", used: 2_000, cumulative: 4_000, window: 100_000),
        ], to: root.appending(path: "sessions/tokens-only.jsonl"))

        let snapshot = try await CurrentSessionProvider(
            root: root,
            now: { sessionTestDate("2026-07-12T00:01:10Z") }
        ).fetchSession()

        XCTAssertNil(snapshot.model)
        XCTAssertNil(snapshot.effort)
    }

    func testThreadSettingsProvideModelWhenTurnContextIsMissing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([
            threadSettings(model: "gpt-5.6-sol", effort: "high", serviceTier: "priority"),
            tokenCount(timestamp: "2026-07-12T00:01:01Z", used: 13_000, cumulative: 20_000, window: 353_400),
        ], to: root.appending(path: "sessions/current.jsonl"))

        let snapshot = try await CurrentSessionProvider(
            root: root,
            now: { sessionTestDate("2026-07-12T00:01:30Z") }
        ).fetchSession()

        XCTAssertEqual(snapshot.model, "gpt-5.6-sol")
        XCTAssertEqual(snapshot.effort, "high")
        XCTAssertEqual(snapshot.serviceTier, "priority")
        XCTAssertTrue(snapshot.isFastMode)
    }

    func testThreadIDFallsBackToValidatedRolloutFilename() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let threadID = "10000000-0000-4000-8000-000000000001"
        try write([
            tokenCount(timestamp: "2026-07-12T00:01:00Z", used: 2_000, cumulative: 4_000, window: 100_000),
        ], to: root.appending(path: "sessions/rollout-2026-07-12T00-00-00-\(threadID).jsonl"))

        let snapshot = try await CurrentSessionProvider(
            root: root,
            now: { sessionTestDate("2026-07-12T00:01:10Z") }
        ).fetchSession()

        XCTAssertEqual(snapshot.threadID, threadID)
    }

    func testSessionOlderThanFifteenMinutesIsUnavailable() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([
            tokenCount(timestamp: "2026-07-12T00:00:00Z", used: 2_000, cumulative: 4_000, window: 100_000),
        ], to: root.appending(path: "sessions/old.jsonl"))

        do {
            _ = try await CurrentSessionProvider(
                root: root,
                now: { sessionTestDate("2026-07-12T00:15:01Z") }
            ).fetchSession()
            XCTFail("Expected stale session to be unavailable")
        } catch let error as UsageError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testMalformedLinesAreSkipped() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([
            "not json",
            tokenCount(timestamp: "2026-07-12T00:01:00Z", used: 3_000, cumulative: 4_000, window: 100_000),
        ], to: root.appending(path: "sessions/current.jsonl"))

        let snapshot = try await CurrentSessionProvider(
            root: root,
            now: { sessionTestDate("2026-07-12T00:01:10Z") }
        ).fetchSession()
        XCTAssertEqual(snapshot.usedTokens, 3_000)
    }

    func testPinnedThreadWinsOverNewerBackgroundThreadAndIncludesTitle() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pinnedID = "10000000-0000-4000-8000-000000000002"
        let backgroundID = "10000000-0000-4000-8000-00000000000f"
        let pinnedFile = root.appending(
            path: "sessions/rollout-2026-07-12T00-00-00-\(pinnedID).jsonl"
        )
        try write([
            sessionMeta(threadID: pinnedID),
            tokenCount(timestamp: "2026-07-12T00:00:00Z", used: 21_000, cumulative: 40_000, window: 353_400),
        ], to: pinnedFile)
        try write([
            sessionMeta(threadID: backgroundID),
            tokenCount(timestamp: "2026-07-12T00:29:00Z", used: 99_000, cumulative: 200_000, window: 353_400),
        ], to: root.appending(path: "sessions/rollout-2026-07-12T00-29-00-\(backgroundID).jsonl"))
        let selection = SelectedThreadState(initialThreadID: pinnedID)
        let metadata = StaticThreadMetadataReader(
            value: .init(
                threadID: pinnedID,
                title: "Touch Bar selected thread",
                rolloutURL: pinnedFile,
                model: "gpt-5.6-sol",
                effort: "high"
            )
        )

        let snapshot = try await CurrentSessionProvider(
            root: root,
            now: { sessionTestDate("2026-07-12T00:30:00Z") },
            selectedThread: selection,
            metadata: metadata
        ).fetchSession()

        XCTAssertEqual(snapshot.threadID, pinnedID)
        XCTAssertEqual(snapshot.title, "Touch Bar selected thread")
        XCTAssertEqual(snapshot.usedTokens, 21_000)
        XCTAssertEqual(snapshot.model, "gpt-5.6-sol")
        XCTAssertEqual(snapshot.effort, "high")
    }

    func testRuntimeEventsDistinguishWorkingWaitingAndIdle() throws {
        let started = Data(([
            taskEvent(timestamp: "2026-07-12T00:00:00Z", type: "task_started"),
        ].joined(separator: "\n") + "\n").utf8)
        XCTAssertEqual(CurrentSessionProvider.executionState(in: started), .working)
        XCTAssertEqual(
            CurrentSessionProvider.activeSince(in: started),
            sessionTestDate("2026-07-12T00:00:00Z")
        )

        let waiting = Data(([
            taskEvent(timestamp: "2026-07-12T00:00:00Z", type: "task_started"),
            attentionCall(callID: "call-1"),
        ].joined(separator: "\n") + "\n").utf8)
        XCTAssertEqual(CurrentSessionProvider.executionState(in: waiting), .waiting)

        let completed = Data(([
            taskEvent(timestamp: "2026-07-12T00:00:00Z", type: "task_started"),
            attentionCall(callID: "call-1"),
            attentionOutput(callID: "call-1"),
            taskEvent(timestamp: "2026-07-12T00:01:00Z", type: "task_complete"),
        ].joined(separator: "\n") + "\n").utf8)
        XCTAssertEqual(CurrentSessionProvider.executionState(in: completed), .idle)
        XCTAssertNil(CurrentSessionProvider.activeSince(in: completed))

        let resumedAfterAnswer = Data(([
            taskEvent(timestamp: "2026-07-12T00:00:00Z", type: "task_started"),
            attentionCall(callID: "call-1"),
            attentionOutput(callID: "call-1"),
        ].joined(separator: "\n") + "\n").utf8)
        XCTAssertEqual(CurrentSessionProvider.executionState(in: resumedAfterAnswer), .working)
        XCTAssertEqual(
            CurrentSessionProvider.activeSince(in: resumedAfterAnswer),
            sessionTestDate("2026-07-12T00:00:00Z")
        )

        let restarted = Data(([
            taskEvent(timestamp: "2026-07-12T00:00:00Z", type: "task_started"),
            taskEvent(timestamp: "2026-07-12T00:01:00Z", type: "task_complete"),
            taskEvent(timestamp: "2026-07-12T00:02:00Z", type: "task_started"),
        ].joined(separator: "\n") + "\n").utf8)
        XCTAssertEqual(CurrentSessionProvider.executionState(in: restarted), .working)
        XCTAssertEqual(
            CurrentSessionProvider.activeSince(in: restarted),
            sessionTestDate("2026-07-12T00:02:00Z")
        )
    }

    func testSelectedThreadSwitchChangesTheDisplayedModel() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = "10000000-0000-4000-8000-000000000002"
        let secondID = "10000000-0000-4000-8000-000000000003"
        try write([
            sessionMeta(threadID: firstID),
            turnContext(timestamp: "2026-07-12T00:01:00Z", model: "gpt-5.6-sol", effort: "high"),
            tokenCount(timestamp: "2026-07-12T00:01:01Z", used: 1, cumulative: 1, window: 100),
        ], to: root.appending(path: "sessions/rollout-first-\(firstID).jsonl"))
        try write([
            sessionMeta(threadID: secondID),
            turnContext(timestamp: "2026-07-12T00:02:00Z", model: "gpt-5.6-terra", effort: "low"),
            tokenCount(timestamp: "2026-07-12T00:02:01Z", used: 2, cumulative: 2, window: 100),
        ], to: root.appending(path: "sessions/rollout-second-\(secondID).jsonl"))
        let selection = SelectedThreadState(initialThreadID: firstID)
        let provider = CurrentSessionProvider(
            root: root,
            now: { sessionTestDate("2026-07-12T00:02:10Z") },
            selectedThread: selection
        )

        let first = try await provider.fetchSession()
        XCTAssertEqual(first.model, "gpt-5.6-sol")
        XCTAssertTrue(selection.update(threadID: secondID))
        let second = try await provider.fetchSession()
        XCTAssertEqual(second.model, "gpt-5.6-terra")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ lines: [String], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func turnContext(timestamp: String, model: String, effort: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"\#(model)","effort":"\#(effort)","collaboration_mode":{"settings":{"reasoning_effort":"\#(effort)"}}}}"#
    }

    private func sessionMeta(threadID: String) -> String {
        #"{"timestamp":"2026-07-12T00:00:59Z","type":"session_meta","payload":{"session_id":"\#(threadID)","id":"\#(threadID)"}}"#
    }

    private func threadSettings(model: String, effort: String, serviceTier: String? = nil) -> String {
        let tier = serviceTier.map { ",\"service_tier\":\"\($0)\"" } ?? ""
        return #"{"timestamp":"2026-07-12T00:01:00Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"\#(model)","reasoning_effort":"\#(effort)"\#(tier)}}}"#
    }

    private func tokenCount(timestamp: String, used: Int, cumulative: Int, window: Int) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(cumulative)},"last_token_usage":{"total_tokens":\#(used)},"model_context_window":\#(window)}}}"#
    }

    private func taskEvent(timestamp: String, type: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"\#(type)"}}"#
    }

    private func attentionCall(callID: String) -> String {
        #"{"timestamp":"2026-07-12T00:00:10Z","type":"response_item","payload":{"type":"custom_tool_call","name":"request_user_input","call_id":"\#(callID)"}}"#
    }

    private func attentionOutput(callID: String) -> String {
        #"{"timestamp":"2026-07-12T00:00:20Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"\#(callID)"}}"#
    }

}

private struct StaticThreadMetadataReader: ThreadMetadataReading {
    let value: CodexThreadMetadata?
    func metadata(for threadID: String) throws -> CodexThreadMetadata? {
        value?.threadID == threadID ? value : nil
    }
}

private func sessionTestDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
