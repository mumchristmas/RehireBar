import AppKit
import Foundation
import XCTest
@testable import RehireBar

@MainActor
final class ApprovalLifecycleRegressionTests: XCTestCase {
    func testReusedApprovalItemsUpdateQuestionActionAndSendingState() throws {
        let bridge = AuditBridge()
        let presenter = TouchBarPresenter(bridge: bridge, logger: { _ in })
        presenter.preparePersistentAccess()
        let bar = try XCTUnwrap(bridge.bar)
        let first = try ConversationApproval(threadID: UUID().uuidString, question: "First question")
        let second = try ConversationApproval(threadID: UUID().uuidString, question: "Second question")
        var selected: [String] = []
        presenter.showApproval(first) { _ in selected.append(first.id) }
        let label = try XCTUnwrap((bar.item(forIdentifier: .init("approval.question")) as? NSCustomTouchBarItem)?.view as? NSTextField)
        let button = try XCTUnwrap((bar.item(forIdentifier: .init("approval.approve")) as? NSCustomTouchBarItem)?.view as? NSButton)
        let originalTitle = button.title
        presenter.setApprovalSending(true, result: "Sending")
        presenter.showApproval(first) { _ in selected.append(first.id) }
        XCTAssertFalse(button.isEnabled, "Reloading the same request must not unlock an in-flight action")
        presenter.showApproval(second) { _ in selected.append(second.id) }
        XCTAssertEqual(label.stringValue, second.question)
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.title, originalTitle)
        button.performClick(nil)
        XCTAssertEqual(selected, [second.id])
    }

    func testSendingBeforeItemCreationAndAfterMetricsRestore() throws {
        let bridge = AuditBridge()
        let presenter = TouchBarPresenter(bridge: bridge, logger: { _ in })
        presenter.preparePersistentAccess()
        let bar = try XCTUnwrap(bridge.bar)
        let first = try ConversationApproval(threadID: UUID().uuidString, question: "First")
        presenter.showApproval(first) { _ in }
        presenter.setApprovalSending(true)
        let button = try XCTUnwrap((bar.item(forIdentifier: .init("approval.approve")) as? NSCustomTouchBarItem)?.view as? NSButton)
        XCTAssertFalse(button.isEnabled)
        presenter.restoreMetrics()
        presenter.showApproval(first) { _ in }
        let restored = try XCTUnwrap((bar.item(forIdentifier: .init("approval.approve")) as? NSCustomTouchBarItem)?.view as? NSButton)
        XCTAssertTrue(restored.isEnabled)
    }

    func testExpiredDisplayedRequestCannotReachSenderAndTimerRemovesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationApprovalStore(url: root.appending(path: "queue.json"))
        let clock = AuditClock()
        let request = try ConversationApproval(threadID: UUID().uuidString, question: "Continue?",
                                              createdAt: clock.date, expiresAt: clock.date.addingTimeInterval(1))
        try store.enqueue(request)
        let bridge = AuditBridge()
        let presenter = TouchBarPresenter(bridge: bridge, logger: { _ in })
        presenter.preparePersistentAccess()
        let updater = AuditReplyUpdater()
        let scheduler = AuditScheduler()
        let coordinator = ConversationApprovalCoordinator(store: store, presenter: presenter,
            sender: .init(updater: updater), now: { clock.date }, scheduler: scheduler)
        coordinator.start()
        defer { coordinator.stop() }
        let bar = try XCTUnwrap(bridge.bar)
        let button = try XCTUnwrap((bar.item(forIdentifier: .init("approval.approve")) as? NSCustomTouchBarItem)?.view as? NSButton)
        clock.date = request.expiresAt
        button.performClick(nil)
        for _ in 0..<10 { await Task.yield() }
        let sends = await updater.sends
        XCTAssertEqual(sends, 0)
        XCTAssertFalse(presenter.displayedItemIdentifiers.contains(.init("approval.question")))

        let next = try ConversationApproval(threadID: UUID().uuidString, question: "Next?",
                                           createdAt: clock.date, expiresAt: clock.date.addingTimeInterval(1))
        coordinator.stop()
        try store.enqueue(next)
        coordinator.start()
        clock.date = next.expiresAt
        scheduler.fireOnce()
        XCTAssertFalse(presenter.displayedItemIdentifiers.contains(.init("approval.question")))
    }
}

final class ApprovalTransactionRegressionTests: XCTestCase {
    func testIndependentStoresPreserveConcurrentEnqueuesAndDelivery() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "queue.json")
        let initial = try ConversationApproval(id: "initial", threadID: UUID().uuidString, question: "Initial")
        try ConversationApprovalStore(url: url).enqueue(initial)
        let errors = AuditErrors()
        DispatchQueue.concurrentPerform(iterations: 31) { index in
            do {
                let store = ConversationApprovalStore(url: url)
                try store.enqueue(ConversationApproval(id: "request-\(index)", threadID: UUID().uuidString, question: "Question"))
                try store.markDelivered(id: initial.id)
            } catch { errors.record(error) }
        }
        XCTAssertTrue(errors.values.isEmpty)
        let pending = try ConversationApprovalStore(url: url).pending()
        XCTAssertEqual(Set(pending.map(\.id)), Set((0..<31).map { "request-\($0)" }))
    }

    func testDeliveryRevalidatesStoredDecisionAndExpiry() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationApprovalStore(url: root.appending(path: "queue.json"))
        let date = Date(timeIntervalSince1970: 100)
        let first = try ConversationApproval(id: "first", threadID: UUID().uuidString, question: "First",
                                           createdAt: date, expiresAt: date.addingTimeInterval(1))
        try store.enqueue(first)
        XCTAssertFalse(try store.beginDelivery(first, at: first.expiresAt))
        XCTAssertTrue(try store.beginDelivery(first, at: date))
        try store.markDelivered(id: first.id)
        XCTAssertFalse(try store.beginDelivery(first, at: date))
    }
}

@MainActor
final class QuotaFreshnessRegressionTests: XCTestCase {
    func testTaskRefreshCannotClearFailedQuotaStaleness() async throws {
        let usage = try UsageSnapshot.from(primary: .init(usedPercent: 10, windowMinutes: 300, resetsAt: 100), secondary: nil, observedAt: .now)
        let quota = AuditFetcher([.success(.init(usage: usage, session: nil)), .failure(UsageError.unavailable), .success(.init(usage: usage, session: nil))])
        let live = AuditFetcher(Array(repeating: .success(.init(usage: nil, session: nil, sessions: [])), count: 3))
        let presenter = AuditPresenter()
        let coordinator = AppCoordinator(activityMonitor: AuditActivity(), statusFetcher: quota,
            liveStatusFetcher: live, presenter: presenter, scheduler: AuditScheduler())
        coordinator.start()
        defer { coordinator.stop() }
        for _ in 0..<500 where presenter.status.usage == nil { await Task.yield() }
        XCTAssertEqual(presenter.status.usage?.isStale, false)
        presenter.onManualRefresh?()
        for _ in 0..<500 { await Task.yield() }
        XCTAssertEqual(presenter.status.usage?.isStale, true)
        presenter.onManualRefresh?()
        for _ in 0..<500 where presenter.status.usage?.isStale != false { await Task.yield() }
        XCTAssertEqual(presenter.status.usage?.isStale, false)
    }
}

private final class AuditErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    var values: [Error] { lock.withLock { errors } }
    func record(_ error: Error) { lock.withLock { errors.append(error) } }
}
@MainActor private final class AuditClock { var date = Date(timeIntervalSince1970: 100) }
private actor AuditReplyUpdater: ConversationReplyUpdating {
    var sends = 0
    func submitUserMessage(threadID: String, text: String) async throws -> Bool { sends += 1; return true }
}
@MainActor private final class AuditBridge: TouchBarBridging {
    var onRestore: (@MainActor @Sendable () -> Void)?
    var bar: NSTouchBar?
    func preparePersistentAccess(_ bar: NSTouchBar) -> Bool { self.bar = bar; return true }
    func activatePersistentAccess(_ bar: NSTouchBar) -> Bool { false }
    func present(_ bar: NSTouchBar) -> Bool { false }
    func dismissOwnTouchBar() {}
}
@MainActor private final class AuditActivity: ActivityMonitoring {
    func start(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) {}
    func stop() {}
}
@MainActor private final class AuditCancellation: RefreshCancellation {
    var cancelled = false
    func cancel() { cancelled = true }
}
@MainActor private final class AuditScheduler: RefreshScheduling {
    private var once: (@MainActor @Sendable () -> Void)?
    private var cancellation: AuditCancellation?
    func scheduleRepeating(every interval: TimeInterval, _ handler: @escaping @MainActor @Sendable () -> Void) -> any RefreshCancellation { AuditCancellation() }
    func scheduleOnce(after interval: TimeInterval, _ handler: @escaping @MainActor @Sendable () -> Void) -> any RefreshCancellation {
        once = handler
        let value = AuditCancellation(); cancellation = value; return value
    }
    func fireOnce() { if cancellation?.cancelled == false { once?() } }
}
private actor AuditFetcher: StatusFetching {
    private var results: [Result<TouchBarStatusSnapshot, Error>]
    init(_ results: [Result<TouchBarStatusSnapshot, Error>]) { self.results = results }
    func fetchStatus() async throws -> TouchBarStatusSnapshot {
        guard !results.isEmpty else { throw UsageError.unavailable }
        return try results.removeFirst().get()
    }
}
@MainActor private final class AuditPresenter: UsagePresenting, ManualRefreshBinding {
    var onManualRefresh: (@MainActor @Sendable () -> Void)?
    var status = TouchBarStatusSnapshot(usage: nil, session: nil)
    func show(_ snapshot: UsageSnapshot) {}
    func showStatus(_ snapshot: TouchBarStatusSnapshot) { status = snapshot }
    func showUnavailable() {}
    func hide() {}
    func markRenderedStatusStale() { status = status.markingUsageStale() }
}
