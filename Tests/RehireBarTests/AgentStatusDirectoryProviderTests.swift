import AgentStatusCore
import Darwin
import Foundation
import XCTest
@testable import RehireBar

final class AgentStatusDirectoryProviderTests: XCTestCase {
    func testAcceptsFractionalISO8601Timestamps() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "agent.json")
        let now = Date(timeIntervalSince1970: 2_000)
        try write(document(providerID: "agent", observedAt: now, taskID: "task"), to: file)
        let json = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "00:33:20Z", with: "00:33:20.123Z")
        try Data(json.utf8).write(to: file)

        let sessions = try await AgentStatusDirectoryProvider(directory: directory, now: { now })
            .fetchSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.executionState, .working)
    }

    func testRejectsSymbolicLinkAndOversizedDocumentsWithoutHidingHealthyProvider() async throws {
        let directory = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let now = Date(timeIntervalSince1970: 2_000)
        let outsideFile = outside.appending(path: "private.json")
        try write(document(providerID: "outside", observedAt: now, taskID: "task"), to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: "link.json"), withDestinationURL: outsideFile
        )
        let largeFile = directory.appending(path: "oversized.json")
        try write(document(providerID: "oversized", observedAt: now, taskID: "task"), to: largeFile)
        var largeData = try Data(contentsOf: largeFile)
        largeData.append(Data(repeating: 0x20, count: 1_048_577))
        try largeData.write(to: largeFile)
        try write(document(providerID: "healthy", observedAt: now, taskID: "task"),
                  to: directory.appending(path: "healthy.json"))

        let sessions = try await AgentStatusDirectoryProvider(directory: directory, now: { now })
            .fetchSessions()

        XCTAssertEqual(sessions.map(\.providerID), ["healthy"])
    }

    func testRejectsSymbolicLinkProviderDirectory() async throws {
        let directory = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let now = Date(timeIntervalSince1970: 2_000)
        try write(document(providerID: "outside", observedAt: now, taskID: "task"),
                  to: outside.appending(path: "agent.json"))
        let link = directory.appending(path: "agents")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let sessions = try await AgentStatusDirectoryProvider(directory: link, now: { now })
            .fetchSessions()

        XCTAssertTrue(sessions.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testIgnoresNamedPipeInsteadOfWaitingForAWriter() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(mkfifo(directory.appending(path: "pipe.json").path, 0o600), 0)

        let sessions = try await AgentStatusDirectoryProvider(directory: directory).fetchSessions()

        XCTAssertTrue(sessions.isEmpty)
    }

    func testEmptyHealthyProviderIsSuccessfulEvenWhenAnotherProviderFails() async throws {
        let provider = CombinedSessionCollectionProvider(providers: [
            FailingSessionCollection(), FixedSessionCollection(sessions: []),
        ])
        let sessions = try await provider.fetchSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testLoadsMultipleProvidersAndKeepsTheirIdentitiesDistinct() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000)
        try write(
            document(providerID: "agent-a", observedAt: now, taskID: "same"),
            to: directory.appending(path: "a.json")
        )
        try write(
            document(providerID: "agent-b", observedAt: now, taskID: "same"),
            to: directory.appending(path: "b.json")
        )
        try Data("not-json".utf8).write(to: directory.appending(path: "broken.json"))

        let sessions = try await AgentStatusDirectoryProvider(
            directory: directory,
            now: { now }
        ).fetchSessions()

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.compactMap(\.identity)).count, 2)
        XCTAssertEqual(Set(sessions.map(\.providerID)), ["agent-a", "agent-b"])
    }

    func testStaleActiveClaimFailsClosedWithoutDiscardingMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let observedAt = Date(timeIntervalSince1970: 1_000)
        try write(
            document(providerID: "agent-a", observedAt: observedAt, taskID: "task"),
            to: directory.appending(path: "agent.json")
        )

        let sessions = try await AgentStatusDirectoryProvider(
            directory: directory,
            now: { observedAt.addingTimeInterval(31) }
        ).fetchSessions()

        XCTAssertEqual(sessions.first?.executionState, .unknown)
        XCTAssertEqual(sessions.first?.title, "Task task")
        XCTAssertEqual(sessions.first?.model, "future-model")
    }

    func testCombinedProviderIsolatesFailure() async throws {
        let healthy = CurrentSessionSnapshot(
            sessionID: "healthy",
            threadID: "task",
            title: "Healthy",
            usedTokens: 0,
            contextWindow: 0,
            model: nil,
            effort: nil,
            observedAt: .now,
            providerID: "agent",
            hostID: "scope"
        )
        let combined = CombinedSessionCollectionProvider(providers: [
            FailingSessionCollection(),
            FixedSessionCollection(sessions: [healthy]),
        ])

        let sessions = try await combined.fetchSessions()

        XCTAssertEqual(sessions, [healthy])
    }

    private func document(
        providerID: String,
        observedAt: Date,
        taskID: String
    ) -> AgentStatusDocument {
        AgentStatusDocument(
            providerID: providerID,
            observedAt: observedAt,
            tasks: [
                AgentTaskSnapshot(
                    identity: .init(scopeID: "scope", taskID: taskID),
                    title: "Task \(taskID)",
                    state: .working,
                    stateObservedAt: observedAt,
                    model: "future-model"
                ),
            ]
        )
    }

    private func write(_ document: AgentStatusDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}

private struct FailingSessionCollection: SessionCollectionFetching {
    func fetchSessions() async throws -> [CurrentSessionSnapshot] { throw UsageError.unavailable }
}

private struct FixedSessionCollection: SessionCollectionFetching {
    let sessions: [CurrentSessionSnapshot]
    func fetchSessions() async throws -> [CurrentSessionSnapshot] { sessions }
}
