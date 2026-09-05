import Foundation
import XCTest
@testable import RehireBar

@MainActor
final class StatusDiagnosticsPublisherTests: XCTestCase {
    func testDiagnosticsMirrorAllRenderedTasksAndKeepActivitySeparateFromSampling() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "status.json")
        let base = RecordingDiagnosticBase()
        let publisher = StatusDiagnosticsPublisher(base: base, outputURL: file)
        let tasks = ["recent", "older"].enumerated().map { index, id in
            CurrentSessionSnapshot(
                sessionID: id, threadID: id, usedTokens: 0, contextWindow: 0,
                model: nil, effort: nil, observedAt: Date(timeIntervalSince1970: 300),
                lastActivityAt: Date(timeIntervalSince1970: Double(200 - index * 100)),
                projectID: "project", executionState: .working
            )
        }
        let status = TouchBarStatusSnapshot(usage: nil, session: tasks.first, sessions: tasks)

        publisher.publish(status)

        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let records = try XCTUnwrap(document["tasks"] as? [[String: Any]])
        XCTAssertEqual(base.status, status)
        XCTAssertEqual(records.compactMap { $0["taskID"] as? String }, ["recent", "older"])
        XCTAssertEqual(records[0]["lastActivityAt"] as? String, "1970-01-01T00:03:20Z")
        XCTAssertEqual(records[0]["observedAt"] as? String, "1970-01-01T00:05:00Z")
        XCTAssertEqual(document["processID"] as? Int32, ProcessInfo.processInfo.processIdentifier)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
}

@MainActor
private final class RecordingDiagnosticBase: StatusPublishing {
    var status: TouchBarStatusSnapshot?
    func publish(_ status: TouchBarStatusSnapshot) { self.status = status }
}
