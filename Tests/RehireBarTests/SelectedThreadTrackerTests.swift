import Foundation
import XCTest
@testable import RehireBar

@MainActor
final class SelectedThreadTrackerTests: XCTestCase {
    func testRouteParserExtractsLocalThreadUUID() {
        XCTAssertEqual(
            CodexThreadRouteParser.threadID(
                in: "app://codex/local/10000000-0000-4000-8000-000000000002?panel=chat"
            ),
            "10000000-0000-4000-8000-000000000002"
        )
    }

    func testRouteParserRejectsUnrelatedUUID() {
        XCTAssertNil(
            CodexThreadRouteParser.threadID(
                in: "approval/10000000-0000-4000-8000-000000000002"
            )
        )
    }

    func testRouteParserExtractsRemoteAndHotkeyThreadUUIDs() {
        let identifier = "10000000-0000-4000-8000-000000000002"

        XCTAssertEqual(
            CodexThreadRouteParser.threadID(in: "app://codex/remote/\(identifier)?hostId=cloud"),
            identifier
        )
        XCTAssertEqual(
            CodexThreadRouteParser.threadID(in: "/hotkey-window/thread/\(identifier)"),
            identifier
        )
    }

    func testDesktopLogDecoderFollowsOnlyFocusedPrimaryWindowActivity() {
        let first = "10000000-0000-4000-8000-000000000002"
        let ignored = "40000000-0000-4000-8000-000000000001"
        let second = "50000000-0000-4000-8000-000000000001"
        let text = """
        2026-09-02T18:40:00.000Z info thread_stream_view_activity_changed active=true conversationId=\(first) rendererWindowAppearance=primary rendererWindowFocused=true rendererWindowVisible=true
        2026-09-02T18:40:01.000Z info thread_stream_view_activity_changed active=true conversationId=\(ignored) rendererWindowAppearance=primary rendererWindowFocused=false rendererWindowVisible=true
        2026-09-02T18:40:02.000Z info thread_stream_view_activity_changed active=false conversationId=\(first) rendererWindowAppearance=primary rendererWindowFocused=true rendererWindowVisible=true
        2026-09-02T18:40:03.000Z info thread_stream_view_activity_changed active=true conversationId=\(second) rendererWindowAppearance=primary rendererWindowFocused=true rendererWindowVisible=true
        """

        XCTAssertEqual(CodexDesktopSelectedThreadLogDecoder.reduce(text), second)
    }

    func testDesktopLogReaderFollowsAppendedWindowSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CodexDesktopSelectedThreadReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "codex-desktop-session-t0-i1.log")
        let first = "10000000-0000-4000-8000-000000000002"
        let second = "40000000-0000-4000-8000-000000000001"
        try logLine(active: true, threadID: first).write(
            to: file,
            atomically: true,
            encoding: .utf8
        )
        let reader = CodexDesktopSelectedThreadReader(logRoot: root)

        XCTAssertEqual(reader.selectedThreadID(promptIfNeeded: false), first)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(logLine(active: false, threadID: first).utf8))
        try handle.write(contentsOf: Data(logLine(active: true, threadID: second).utf8))
        try handle.close()

        XCTAssertEqual(reader.selectedThreadID(promptIfNeeded: false), second)
    }

    func testPinnedStateChangesOnlyForAConfirmedNewThread() {
        let state = SelectedThreadState(initialThreadID: nil)

        XCTAssertTrue(state.update(threadID: "10000000-0000-4000-8000-000000000002"))
        XCTAssertFalse(state.update(threadID: "10000000-0000-4000-8000-000000000002"))
        XCTAssertEqual(state.threadID, "10000000-0000-4000-8000-000000000002")
    }

    func testProductionReaderPromptsOnlyTheFallbackWhenDesktopLogHasNoSelection() {
        let desktop = StubSelectedThreadReader(threadID: nil)
        let accessibility = StubSelectedThreadReader(
            threadID: "10000000-0000-4000-8000-000000000002"
        )
        let reader = ProductionSelectedThreadReader(
            desktopLog: desktop,
            accessibility: accessibility
        )

        let selected = reader.selectedThreadID(promptIfNeeded: true)

        XCTAssertEqual(selected, "10000000-0000-4000-8000-000000000002")
        XCTAssertEqual(desktop.promptValues, [false])
        XCTAssertEqual(accessibility.promptValues, [true])
    }

    func testTrackerPersistsConfirmedSelectionAndNotifiesOnce() {
        let suiteName = "SelectedThreadTrackerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = SelectedThreadState(initialThreadID: nil)
        let reader = StubSelectedThreadReader(
            threadID: "10000000-0000-4000-8000-000000000002"
        )
        let tracker = SelectedThreadTracker(state: state, reader: reader, defaults: defaults)
        var changeCount = 0
        tracker.start { changeCount += 1 }

        tracker.pollNow()
        tracker.pollNow()

        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(reader.promptValues, [true, false])
        XCTAssertEqual(
            defaults.string(forKey: SelectedThreadTracker.persistedThreadIDKey),
            "10000000-0000-4000-8000-000000000002"
        )
    }

    private func logLine(active: Bool, threadID: String) -> String {
        "2026-09-02T18:40:00.000Z info thread_stream_view_activity_changed "
            + "active=\(active) conversationId=\(threadID) rendererWindowAppearance=primary "
            + "rendererWindowFocused=true rendererWindowVisible=true\n"
    }
}

@MainActor
private final class StubSelectedThreadReader: SelectedThreadReading {
    let threadID: String?
    private(set) var promptValues: [Bool] = []

    init(threadID: String?) {
        self.threadID = threadID
    }

    func selectedThreadID(promptIfNeeded: Bool) -> String? {
        promptValues.append(promptIfNeeded)
        return threadID
    }
}
