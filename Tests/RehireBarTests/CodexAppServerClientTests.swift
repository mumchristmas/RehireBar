import Foundation
import XCTest
@testable import RehireBar

final class CodexAppServerClientTests: XCTestCase {
    func testExecutableOverrideWinsWithEmptyPATH() throws {
        let executable = try temporaryExecutable()
        XCTAssertEqual(try CodexAppServerClient.resolveExecutable(
            environment: ["REHIREBAR_CODEX_PATH": executable.path, "PATH": ""],
            homeDirectory: URL(fileURLWithPath: "/missing"),
            knownCandidates: []
        ), executable)
    }

    func testKnownCandidateWorksWithMinimalPATH() throws {
        let executable = try temporaryExecutable()
        XCTAssertEqual(try CodexAppServerClient.resolveExecutable(
            environment: ["PATH": "/usr/bin"],
            homeDirectory: URL(fileURLWithPath: "/missing"),
            knownCandidates: [executable]
        ), executable)
    }

    func testKnownSymlinkCandidateResolvesToRegularExecutable() throws {
        let executable = try temporaryExecutable()
        let link = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: executable)
        }

        XCTAssertEqual(try CodexAppServerClient.resolveExecutable(
            environment: ["PATH": ""],
            homeDirectory: URL(fileURLWithPath: "/missing"),
            knownCandidates: [link]
        ), executable.resolvingSymlinksInPath().standardizedFileURL)
    }

    func testRejectsNonExecutableOverride() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: file)
        XCTAssertThrowsError(try CodexAppServerClient.resolveExecutable(
            environment: ["REHIREBAR_CODEX_PATH": file.path],
            homeDirectory: URL(fileURLWithPath: "/missing"), knownCandidates: []
        ))
    }

    func testRejectsRelativeExecutableOverride() throws {
        let relativePath = "rehirebar-relative-\(UUID().uuidString)"
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: relativePath)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: executable) }

        XCTAssertThrowsError(try CodexAppServerClient.resolveExecutable(
            environment: ["REHIREBAR_CODEX_PATH": relativePath],
            homeDirectory: URL(fileURLWithPath: "/missing"), knownCandidates: []
        )) { error in
            XCTAssertEqual(error as? CodexAppServerError, .unavailable)
        }
    }

    func testDecodesAccountRateLimitsResponse() throws {
        let line = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":24,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":59,"windowDurationMins":10080,"resetsAt":1800086400}}}}"#

        let snapshot = try CodexAppServerClient.decodeRateLimits(
            Data(line.utf8),
            observedAt: Date(timeIntervalSince1970: 1_799_999_000)
        )

        XCTAssertEqual(snapshot.primary.remainingPercent, 76)
        XCTAssertEqual(snapshot.secondary.remainingPercent, 41)
    }

    func testDecodesSevenDayOnlyResponseWithNullSecondary() throws {
        let line = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1800086400},"secondary":null}}}"#
        let snapshot = try CodexAppServerClient.decodeRateLimits(Data(line.utf8), observedAt: .now)
        XCTAssertFalse(snapshot.primaryAvailable)
        XCTAssertTrue(snapshot.secondaryAvailable)
        XCTAssertEqual(snapshot.secondary.remainingPercent, 100)
    }

    func testRejectsJSONRPCError() {
        let line = #"{"id":2,"error":{"code":-1,"message":"failed"}}"#

        XCTAssertThrowsError(
            try CodexAppServerClient.decodeRateLimits(Data(line.utf8), observedAt: .now)
        )
    }

    func testDecodesLegacyWindowMinutes() throws {
        let line = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":1,"windowMinutes":300,"resetsAt":1800000000},"secondary":{"usedPercent":2,"windowMinutes":10080,"resetsAt":1800086400}}}}"#

        let snapshot = try CodexAppServerClient.decodeRateLimits(Data(line.utf8), observedAt: .now)

        XCTAssertEqual(snapshot.primary.windowMinutes, 300)
        XCTAssertEqual(snapshot.secondary.windowMinutes, 10_080)
    }

    func testRejectsResponseWithUnexpectedID() {
        let line = #"{"id":99,"result":{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1800086400}}}}"#

        XCTAssertThrowsError(
            try CodexAppServerClient.decodeRateLimits(Data(line.utf8), observedAt: .now)
        ) { error in
            XCTAssertEqual(error as? CodexAppServerError, .invalidResponse)
        }
    }

    func testUsesExactJSONRPCMessages() {
        XCTAssertEqual(
            String(decoding: CodexAppServerClient.initializeRequest, as: UTF8.self),
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"rehirebar","version":"development"}}}"# + "\n"
        )
        XCTAssertEqual(
            String(decoding: CodexAppServerClient.initializedNotification, as: UTF8.self),
            #"{"method":"initialized","params":{}}"# + "\n"
        )
        XCTAssertEqual(
            String(decoding: CodexAppServerClient.rateLimitsRequest, as: UTF8.self),
            #"{"id":2,"method":"account/rateLimits/read","params":{}}"# + "\n"
        )
    }

    func testInitializationRequiresSuccessResult() {
        XCTAssertThrowsError(
            try CodexAppServerClient.validateInitialization(Data(#"{"id":1}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? CodexAppServerError, .invalidResponse)
        }
    }

    func testInitializationAcceptsSuccessResult() throws {
        try CodexAppServerClient.validateInitialization(Data(#"{"id":1,"result":{}}"#.utf8))
    }

    func testReadTimeoutUsesInjectedMonotonicDeadlineWithoutSleeping() {
        var capturedTimeout: Int32?

        XCTAssertThrowsError(
            try CodexAppServerClient.readResponse(
                id: 1,
                from: -1,
                timeoutSeconds: 5,
                monotonicNanoseconds: { 10_000_000_000 },
                poll: { _, timeout in
                    capturedTimeout = timeout
                    return 0
                },
                readByte: { _ in nil }
            )
        ) { error in
            XCTAssertEqual(error as? CodexAppServerError, .timedOut)
        }
        XCTAssertEqual(capturedTimeout, 5_000)
    }


    func testRejectsOversizedNDJSONLine() {
        var bytes = Array(repeating: UInt8(ascii: "x"), count: CodexAppServerClient.maximumResponseLineBytes + 1)
        bytes.append(0x0A)
        var index = 0
        XCTAssertThrowsError(try CodexAppServerClient.readResponse(
            id: 1, from: -1, timeoutSeconds: 5,
            monotonicNanoseconds: { 0 }, poll: { _, _ in 1 },
            readByte: { _ in defer { index += 1 }; return bytes[index] }
        )) { XCTAssertEqual($0 as? CodexAppServerError, .invalidResponse) }
    }

    func testCancellationTerminatesAndReapsSubprocess() async {
        let runner = FakeBlockingRunner()
        let task = Task { try await CodexAppServerClient(runnerFactory: { runner }).fetch() }
        await runner.waitUntilRunning()
        task.cancel()
        _ = try? await task.value
        XCTAssertEqual(runner.terminateCount, 1)
        XCTAssertEqual(runner.reapCount, 1)
        XCTAssertFalse(runner.isRunning)
    }

    private func temporaryExecutable() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

private final class FakeBlockingRunner: AppServerRunning, @unchecked Sendable {
    private let condition = NSCondition()
    private(set) var isRunning = false
    private(set) var terminateCount = 0
    private(set) var reapCount = 0

    func run() throws -> UsageSnapshot {
        condition.lock(); isRunning = true; condition.broadcast()
        while isRunning { condition.wait() }
        condition.unlock()
        throw CancellationError()
    }

    func cancelAndWait() {
        condition.lock(); terminateCount += 1; isRunning = false; reapCount += 1
        condition.broadcast(); condition.unlock()
    }

    func waitUntilRunning() async {
        while true {
            let running = condition.withLock { isRunning }
            if running { return }
            await Task.yield()
        }
    }
}
