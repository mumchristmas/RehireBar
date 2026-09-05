import AppKit

@MainActor
protocol WakeMonitoring: AnyObject {
    func start(_ handler: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

@MainActor
final class WorkspaceWakeMonitor: WakeMonitoring {
    private var observer: NSObjectProtocol?

    func start(_ handler: @escaping @MainActor @Sendable () -> Void) {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in Task { @MainActor in handler() } }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }
}

@MainActor
final class NoopWakeMonitor: WakeMonitoring {
    func start(_ handler: @escaping @MainActor @Sendable () -> Void) {}
    func stop() {}
}
