import AppKit
import Dispatch

private func handleThreadSnapshotRequest(_ arguments: [String]) -> Bool {
    guard arguments.first == "thread-snapshot" else { return false }
    let values = Array(arguments.dropFirst())
    guard values.count == 2 else { exit(2) }
    Task.detached {
        do {
            let snapshot = try await CodexDesktopIPCClient().fetchThreadSnapshot(
                threadID: values[0],
                hostID: values[1]
            )
            print("used=\(snapshot.usedTokens.map(String.init) ?? "-") context=\(snapshot.contextWindow.map(String.init) ?? "-") model=\(snapshot.model ?? "-") effort=\(snapshot.effort ?? "-") state=\(snapshot.executionState.map { String(describing: $0) } ?? "-")")
            exit(0)
        } catch {
            fputs("thread-snapshot failed: \(error)\n", stderr)
            exit(2)
        }
    }
    dispatchMain()
}

private func handleApprovalRequest(_ arguments: [String]) -> Bool {
    guard arguments.first == "approval-request" else { return false }
    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    do {
        guard let threadID = value(after: "--thread-id"), let question = value(after: "--question") else {
            throw ConversationApproval.ValidationError.invalidQuestion
        }
        let approval = try ConversationApproval(threadID: threadID, hostID: value(after: "--host-id"), question: question)
        try ConversationApprovalStore().enqueue(approval)
        DistributedNotificationCenter.default().post(name: ConversationApprovalStore.changedNotification, object: nil)
        print(approval.id)
        return true
    } catch {
        fputs("approval-request failed: \(error)\n", stderr)
        exit(2)
    }
}

if handleApprovalRequest(Array(CommandLine.arguments.dropFirst())) { exit(0) }
if handleThreadSnapshotRequest(Array(CommandLine.arguments.dropFirst())) { exit(0) }
if CommandLine.arguments.dropFirst().first == "doctor" {
    exit(DoctorCommand.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var application: RehireBarApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstanceGuard.shared.acquire() else {
            NSLog("RehireBar is already running; exiting duplicate instance")
            NSApplication.shared.terminate(nil)
            return
        }
        try? FileManager.default.createDirectory(
            at: AgentStatusDirectoryProvider.defaultDirectory,
            withIntermediateDirectories: true
        )
        let arguments = CommandLine.arguments
        let statusOutputURL: URL?
        if let index = arguments.firstIndex(of: "--status-output"),
           arguments.indices.contains(index + 1) {
            statusOutputURL = URL(filePath: arguments[index + 1])
        } else {
            statusOutputURL = nil
        }
        let application = RehireBarApplication.makeProduction(statusOutputURL: statusOutputURL)
        self.application = application
        application.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        application?.stop()
    }
}

let app = NSApplication.shared
private let delegate = ApplicationDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// NSApplication keeps its delegate weakly. The explicit lifetime anchor prevents
// optimized release builds from dropping the coordinator after launch while the
// system-modal Touch Bar itself remains visible.
withExtendedLifetime(delegate) {
    app.run()
}
