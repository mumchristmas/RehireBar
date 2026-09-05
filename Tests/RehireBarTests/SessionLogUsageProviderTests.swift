import Foundation
import XCTest
@testable import RehireBar

final class SessionLogUsageProviderTests: XCTestCase {
    func testNewestValidTokenCountAcrossAllowedRootsWins() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = root.appending(path: "sessions/2026/07/rollout.jsonl")
        let archived = root.appending(path: "archived_sessions/old.jsonl")
        try write([
            tokenCount(timestamp: "2026-07-10T10:00:00Z", primary: 11, secondary: 22),
            "not json",
        ], to: session)
        try write([
            tokenCount(timestamp: "2026-07-11T10:00:00.500Z", primary: 33, secondary: 44),
        ], to: archived)

        let snapshot = try await SessionLogUsageProvider(root: root).fetch()

        XCTAssertEqual(snapshot.primary.remainingPercent, 67)
        XCTAssertEqual(snapshot.secondary.remainingPercent, 56)
        XCTAssertEqual(snapshot.observedAt.timeIntervalSince1970, 1_783_764_000.5, accuracy: 0.001)
    }

    func testNeverReadsFilesOutsideSessionsAndArchivedSessions() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try write([tokenCount(timestamp: "2026-07-10T10:00:00Z", primary: 12, secondary: 23)],
                  to: root.appending(path: "sessions/rollout.jsonl"))
        try write([tokenCount(timestamp: "2026-07-12T10:00:00Z", primary: 99, secondary: 99)],
                  to: root.appending(path: "auth.json"))
        try write([tokenCount(timestamp: "2026-07-13T10:00:00Z", primary: 98, secondary: 98)],
                  to: root.appending(path: "archived_sessions/nested/ignored.jsonl"))

        let snapshot = try await SessionLogUsageProvider(root: root).fetch()

        XCTAssertEqual(snapshot.primary.remainingPercent, 88)
        XCTAssertEqual(snapshot.secondary.remainingPercent, 77)
    }

    func testReadsOnlyBoundedTailOfLargeFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "sessions/rollout.jsonl")
        let oversizedPrefix = String(repeating: "x", count: 300 * 1_024)
        try write([oversizedPrefix, tokenCount(timestamp: "2026-07-11T10:00:00Z", primary: 45, secondary: 54)], to: file)

        let snapshot = try await SessionLogUsageProvider(root: root).fetch()

        XCTAssertEqual(snapshot.primary.remainingPercent, 55)
    }

    func testNewestEventTimestampWinsDespiteConflictingFileModificationDates() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let olderEvent = root.appending(path: "sessions/recently-modified.jsonl")
        let newerEvent = root.appending(path: "sessions/oldly-modified.jsonl")
        try write([tokenCount(timestamp: "2026-07-10T10:00:00Z", primary: 91, secondary: 92)], to: olderEvent)
        try write([tokenCount(timestamp: "2026-07-12T10:00:00Z", primary: 31, secondary: 32)], to: newerEvent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)], ofItemAtPath: olderEvent.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: newerEvent.path)

        let snapshot = try await SessionLogUsageProvider(root: root).fetch()

        XCTAssertEqual(snapshot.primary.remainingPercent, 69)
        XCTAssertEqual(snapshot.secondary.remainingPercent, 68)
    }

    func testNewestPartiallySupportedWindowWinsGlobalTimestampSelection() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([
            tokenCount(timestamp: "2026-07-10T10:00:00Z", primary: 31, secondary: 32),
            tokenCount(
                timestamp: "2026-07-12T10:00:00Z",
                primary: 91,
                secondary: 92,
                primaryWindowMinutes: 60
            ),
        ], to: root.appending(path: "sessions/rollout.jsonl"))

        let snapshot = try await SessionLogUsageProvider(root: root).fetch()

        XCTAssertFalse(snapshot.primaryAvailable)
        XCTAssertEqual(snapshot.secondary.remainingPercent, 8)
    }

    func testNewerModelSpecificBucketCannotOverrideAccountQuota() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([
            tokenCount(
                timestamp: "2026-07-10T10:00:00Z",
                primary: 31,
                secondary: 32,
                limitID: "codex"
            ),
            tokenCount(
                timestamp: "2026-07-12T10:00:00Z",
                primary: 0,
                secondary: 0,
                limitID: "codex_bengalfox"
            ),
        ], to: root.appending(path: "sessions/rollout.jsonl"))

        let snapshot = try await SessionLogUsageProvider(root: root).fetch()

        XCTAssertEqual(snapshot.primary.remainingPercent, 69)
        XCTAssertEqual(snapshot.secondary.remainingPercent, 68)
    }

    func testCandidateReplacedBySymlinkAfterValidationIsNotOpened() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let safe = root.appending(path: "sessions/safe.jsonl")
        let raced = root.appending(path: "sessions/raced.jsonl")
        let secret = outside.appending(path: "auth.json")
        try write([tokenCount(timestamp: "2026-07-10T10:00:00Z", primary: 12, secondary: 23)], to: safe)
        try write([tokenCount(timestamp: "2026-07-11T10:00:00Z", primary: 31, secondary: 32)], to: raced)
        try write([tokenCount(timestamp: "2026-07-14T10:00:00Z", primary: 99, secondary: 99)], to: secret)

        let provider = SessionLogUsageProvider(root: root) { candidate in
            guard candidate.lastPathComponent == raced.lastPathComponent else { return }
            try? FileManager.default.removeItem(at: candidate)
            try? FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: secret)
        }
        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.primary.remainingPercent, 88)
        XCTAssertEqual(snapshot.secondary.remainingPercent, 77)
    }

    func testCandidateParentReplacedByOutsideSymlinkAfterValidationIsNotTraversed() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let safe = root.appending(path: "sessions/safe.jsonl")
        let parent = root.appending(path: "sessions/2026/07")
        let raced = parent.appending(path: "rollout.jsonl")
        let outsideFile = outside.appending(path: "rollout.jsonl")
        try write([tokenCount(timestamp: "2026-07-10T10:00:00Z", primary: 12, secondary: 23)], to: safe)
        try write([tokenCount(timestamp: "2026-07-11T10:00:00Z", primary: 31, secondary: 32)], to: raced)
        try write([tokenCount(timestamp: "2026-07-14T10:00:00Z", primary: 99, secondary: 99)], to: outsideFile)

        let provider = SessionLogUsageProvider(root: root) { candidate in
            guard candidate.lastPathComponent == raced.lastPathComponent else { return }
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        }
        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.primary.remainingPercent, 88)
        XCTAssertEqual(snapshot.secondary.remainingPercent, 77)
    }

    func testRejectsSymbolicLinkFilePointingOutsideAllowedRoots() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try write([tokenCount(timestamp: "2026-07-10T10:00:00Z", primary: 12, secondary: 23)],
                  to: root.appending(path: "sessions/real.jsonl"))
        let leaked = outside.appending(path: "auth.json")
        try write([tokenCount(timestamp: "2026-07-13T10:00:00Z", primary: 99, secondary: 99)], to: leaked)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "sessions/leak.jsonl"),
            withDestinationURL: leaked
        )

        let snapshot = try await SessionLogUsageProvider(root: root).fetch()

        XCTAssertEqual(snapshot.primary.remainingPercent, 88)
        XCTAssertEqual(snapshot.secondary.remainingPercent, 77)
    }

    func testRejectsSymbolicLinkDirectoryPointingOutsideAllowedRoots() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try write([tokenCount(timestamp: "2026-07-14T10:00:00Z", primary: 98, secondary: 98)],
                  to: outside.appending(path: "stolen.jsonl"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "sessions"),
            withDestinationURL: outside
        )

        do {
            _ = try await SessionLogUsageProvider(root: root).fetch()
            XCTFail("A symbolic-link sessions directory must not be traversed")
        } catch let error as UsageError {
            XCTAssertEqual(error, .unavailable)
        }
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

    private func tokenCount(
        timestamp: String,
        primary: Double,
        secondary: Double,
        primaryWindowMinutes: Int = 300,
        secondaryWindowMinutes: Int = 10_080,
        limitID: String? = nil
    ) -> String {
        let limit = limitID.map { #""limit_id":"\#($0)","# } ?? ""
        return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{\#(limit)"primary":{"used_percent":\#(primary),"window_minutes":\#(primaryWindowMinutes),"resets_at":1800000000},"secondary":{"used_percent":\#(secondary),"window_minutes":\#(secondaryWindowMinutes),"resets_at":1800086400}}}}"#
    }
}
