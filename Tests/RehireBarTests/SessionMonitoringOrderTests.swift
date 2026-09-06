import Foundation
import XCTest
@testable import RehireBar

final class SessionMonitoringOrderTests: XCTestCase {
    func testWaitingFirstKeepsInputVisibleBesideThreeRunningTasks() {
        let running = (1...3).map { task("run-\($0)", state: .working, activity: 200) }
        let waiting = task("wait", state: .waiting, activity: 100)
        let failed = task("error", state: .error, activity: 50)
        let tasks = running + [waiting, failed]

        XCTAssertEqual(SessionMonitoringOrder.sorted(tasks).prefix(3).map(\.executionState),
                       [.working, .working, .working])
        let ordered = SessionMonitoringOrder.sorted(tasks, mode: .waitingFirst)
        XCTAssertEqual(ordered.map(\.threadID), ["wait", "error", "run-1", "run-2", "run-3"])
        XCTAssertEqual(Set(ordered.compactMap(\.identity)), Set(tasks.compactMap(\.identity)))
    }

    func testExpiredWaitingEvidenceDoesNotStayAtTheFront() {
        let waiting = task("wait", state: .waiting, activity: 100, observed: 100)
        let running = task("run", state: .working, activity: 200, observed: 200)
        let aged = [waiting, running].map { $0.expiringEvidence(at: Date(timeIntervalSince1970: 200)) }

        let ordered = SessionMonitoringOrder.sorted(aged, mode: .waitingFirst)

        XCTAssertEqual(ordered.map(\.threadID), ["run", "wait"])
        XCTAssertEqual(ordered.last?.executionState, .unknown)
    }

    func testUnknownOrMissingSortPreferencePreservesRunningFirst() {
        XCTAssertEqual(SessionSortMode(preference: nil), .runningFirst)
        XCTAssertEqual(SessionSortMode(preference: "unsupported"), .runningFirst)
        XCTAssertEqual(SessionSortMode(preference: "waiting-first"), .waitingFirst)
    }

    func testRecentActivityWinsOverIDAndFreshPollingTime() {
        let old = task("a-old", activity: 10, observed: 1_000)
        let recent = task("z-recent", activity: 200, observed: 201)

        XCTAssertEqual(SessionMonitoringOrder.sorted([old, recent]).map(\.threadID),
                       ["z-recent", "a-old"])
    }

    func testRunningTaskPrecedesOldErrorsAndRecentlyVisitedInactiveTasks() {
        let oldError = task("a-error", state: .error, activity: 20)
        let inactive = task("b-inactive", activity: 300, observed: 1_000)
        let running = task("z-running", state: .working, activity: 100)

        XCTAssertEqual(SessionMonitoringOrder.sorted([oldError, inactive, running]).map(\.threadID),
                       ["z-running", "a-error", "b-inactive"])
    }

    func testActiveProjectAndRecentProjectHavePriorityWithoutMergingTasks() {
        let running = task("run", state: .working, activity: 100, project: "active")
        let companion = task("companion", activity: 10, project: "active")
        let recent = task("recent", activity: 300, project: "recent")
        let olderInRecentProject = task("older", activity: 20, project: "recent")
        let middle = task("middle", activity: 200, project: "middle")

        let ordered = SessionMonitoringOrder.sorted([middle, companion, olderInRecentProject, recent, running])

        XCTAssertEqual(ordered.map(\.threadID), ["run", "companion", "recent", "older", "middle"])
        XCTAssertEqual(Set(ordered.compactMap(\.identity)).count, 5)
    }

    func testProjectRecencyIsScopedByProviderAndHostAndDoesNotUseDisplayName() {
        let old = task("old", activity: 10, project: "shared", host: "one")
        let recent = task("recent", activity: 300, project: "shared", host: "two")
        let other = task("other", activity: 200, project: "different", host: "one")
        let anotherProvider = task("provider", activity: 150, project: "shared",
                                   host: "two", provider: "other-provider")

        XCTAssertEqual(SessionMonitoringOrder.sorted([old, recent, other, anotherProvider]).map(\.threadID),
                       ["recent", "other", "provider", "old"])
    }

    func testMissingActivityStaysMissingAndEqualActivityUsesStableIdentity() {
        let unknown = task("a-unknown", activity: nil, observed: 1_000)
        let second = task("z-known", activity: 200)
        let first = task("b-known", activity: 200)

        let ordered = SessionMonitoringOrder.sorted([unknown, second, first])

        XCTAssertEqual(ordered.map(\.threadID), ["b-known", "z-known", "a-unknown"])
        XCTAssertNil(ordered.last?.lastActivityAt)
    }

    private func task(
        _ id: String, state: SessionExecutionState = .idle, activity: TimeInterval?,
        observed: TimeInterval = 200, project: String? = nil,
        host: String = "local", provider: String = "codex"
    ) -> CurrentSessionSnapshot {
        .init(
            sessionID: id, threadID: id, usedTokens: 0, contextWindow: 0,
            model: nil, effort: nil, observedAt: Date(timeIntervalSince1970: observed),
            lastActivityAt: activity.map { Date(timeIntervalSince1970: $0) },
            projectName: "Same display name", projectID: project,
            providerID: provider, hostID: host, executionState: state
        )
    }
}
