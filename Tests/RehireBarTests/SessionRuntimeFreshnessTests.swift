import Foundation
import XCTest
@testable import RehireBar

final class SessionRuntimeFreshnessTests: XCTestCase {
    func testProgressKeepsLongRunningTurnFreshWithoutResettingItsStart() throws {
        let snapshot = try read(events: [event("task_started", at: "00:01:40"), token(at: "00:03:10")])
        XCTAssertEqual(snapshot.executionState, .working)
        XCTAssertEqual(snapshot.executionStateObservedAt, Date(timeIntervalSince1970: 190))
        XCTAssertEqual(snapshot.activeSince, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(snapshot.expiringEvidence(at: Date(timeIntervalSince1970: 200)).executionState, .working)
    }

    func testFinalUsageDoesNotReviveCompletedTurn() throws {
        let snapshot = try read(events: [event("task_started", at: "00:01:40"),
                                        event("task_complete", at: "00:03:00"), token(at: "00:03:10")])
        XCTAssertEqual(snapshot.executionState, .idle)
        XCTAssertEqual(snapshot.executionStateObservedAt, Date(timeIntervalSince1970: 180))
        XCTAssertNil(snapshot.activeSince)
    }

    func testUsageUpdateDoesNotClearAWaitingState() throws {
        let snapshot = try read(events: [event("task_started", at: "00:01:40"),
                                        event("request_user_input", at: "00:02:40"), token(at: "00:03:10")])
        XCTAssertEqual(snapshot.executionState, .waiting)
        XCTAssertEqual(snapshot.executionStateObservedAt, Date(timeIntervalSince1970: 160))
    }

    private func read(events: [String]) throws -> CurrentSessionSnapshot {
        var accumulator = SessionSnapshotAccumulator()
        accumulator.consume(Data((events.joined(separator: "\n") + "\n").utf8))
        let root = FileManager.default.temporaryDirectory
        return try XCTUnwrap(accumulator.snapshot(in: SafeSessionCandidate(
            file: root.appending(path: "rollout-00000000-0000-4000-8000-000000000001.jsonl"),
            allowedRoot: root
        )))
    }

    private func event(_ type: String, at time: String) -> String {
        #"{"timestamp":"1970-01-01T\#(time)Z","type":"event_msg","payload":{"type":"\#(type)"}}"#
    }

    private func token(at time: String) -> String {
        #"{"timestamp":"1970-01-01T\#(time)Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100},"model_context_window":1000}}}"#
    }
}
