import AgentStatusCore
import Foundation
import XCTest
@testable import RehireBar

final class DoctorReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000)

    func testFreshnessDistinguishesDelayedUsableAndExpiredSourceData() {
        func status(age: TimeInterval) -> DoctorFreshness {
            .init(hasValue: true, observedAt: now.addingTimeInterval(-age), now: now,
                  freshFor: 30, usableFor: 900)
        }
        XCTAssertEqual(status(age: 30).state, "fresh")
        XCTAssertEqual(status(age: 31).state, "stale")
        XCTAssertEqual(status(age: 900).state, "stale")
        XCTAssertEqual(status(age: 901).state, "expired")
    }

    func testMissingUndatedAndFutureEvidenceCannotBeClaimedFresh() {
        let absent = DoctorFreshness(hasValue: false, observedAt: now, now: now, freshFor: 30, usableFor: 900)
        let undated = DoctorFreshness(hasValue: true, observedAt: nil, now: now, freshFor: 30, usableFor: 900)
        let future = DoctorFreshness(hasValue: true, observedAt: now.addingTimeInterval(60),
                                     now: now, freshFor: 30, usableFor: 900)
        XCTAssertEqual(absent.state, "missing")
        XCTAssertNil(absent.ageSeconds)
        XCTAssertEqual(undated.state, "undated")
        XCTAssertEqual(future.state, "invalid-timestamp")
        XCTAssertNil(future.ageSeconds)
    }

    func testNewCacheWriteCannotFreshenOlderOrUndatedFieldsAndSummaryOmitsPrivateValues() throws {
        let snapshot = StatusCacheSnapshot(
            primaryRemainingPercent: nil, secondaryRemainingPercent: 72,
            sessionUsedTokens: 12, sessionContextWindow: 100,
            model: "private-model-name", effort: "private-effort",
            observedAt: now, usageObservedAt: now.addingTimeInterval(-901),
            sessionContextObservedAt: now.addingTimeInterval(-61)
        )
        let report = DoctorCacheSummary(snapshot: snapshot, filePresent: true, now: now)
        XCTAssertEqual(report.quota.state, "expired")
        XCTAssertEqual(report.context.state, "expired")
        XCTAssertEqual(report.model.state, "undated")
        XCTAssertEqual(report.runtimeState, "not-stored-in-cache")
        let data = try JSONEncoder().encode(report)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("private-model-name"))
        XCTAssertFalse(json.contains("private-effort"))
        XCTAssertFalse(json.contains("sessionUsedTokens"))
    }

    func testUnreadableAndMissingCacheHaveDifferentDiagnostics() {
        XCTAssertEqual(DoctorCacheSummary(snapshot: nil, filePresent: true, now: now).status, "unreadable")
        XCTAssertEqual(DoctorCacheSummary(snapshot: nil, filePresent: false, now: now).status, "missing")
    }

    func testVersionProbeAcceptsVersionAndRejectsArbitraryOutput() throws {
        XCTAssertEqual(CodexVersionProbe.parse("codex-cli 0.153.4\n"), "0.153.4")
        XCTAssertEqual(CodexVersionProbe.parse("codex-cli 0.154.0-alpha.1\n"), "0.154.0-alpha.1")
        XCTAssertNil(CodexVersionProbe.parse("codex-cli /Users/private/token"))
        XCTAssertNil(CodexVersionProbe.parse("codex-cli 0.153.4\nsecret output"))
        try withExecutable("printf 'codex-cli 0.153.4\\n'\n") { executable in
            XCTAssertEqual(CodexVersionProbe.read(executable: executable), "0.153.4")
        }
    }

    func testVersionProbeTimesOutEvenWhenWrapperClosesStdout() throws {
        for command in ["exec /bin/sleep 5\n", "exec 1>&-\nexec /bin/sleep 5\n"] {
            try withExecutable(command) { executable in
                let start = ProcessInfo.processInfo.systemUptime
                XCTAssertNil(CodexVersionProbe.read(executable: executable, timeout: 0.05))
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
            }
        }
    }

    func testVersionProbeRejectsOversizedOrFailedResponses() throws {
        for command in ["/usr/bin/printf '%5000s' x\n", "printf 'codex-cli 0.153.4\\n'\nexit 1\n"] {
            try withExecutable(command) { executable in
                XCTAssertNil(CodexVersionProbe.read(executable: executable))
            }
        }
    }

    private func withExecutable(_ body: String, action: (URL) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data(("#!/bin/sh\n" + body).utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        defer { try? FileManager.default.removeItem(at: path) }
        try action(path)
    }
}
