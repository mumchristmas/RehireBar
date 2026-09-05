import AppKit
import Foundation

@MainActor
final class CodexActivityMonitor: NSObject, ActivityMonitoring {
    static let defaultBundleIdentifier = "com.openai.codex"
    static let overrideEnvironmentKey = "REHIREBAR_BUNDLE_ID"

    let bundleIdentifier: String

    private let workspace: NSWorkspace
    private var handler: (@MainActor @Sendable (Bool) -> Void)?
    private var isObserving = false

    init(
        workspace: NSWorkspace = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let override = environment[Self.overrideEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundleIdentifier = override.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultBundleIdentifier
        self.workspace = workspace
        super.init()
    }

    func start(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.handler = handler

        if !isObserving {
            workspace.notificationCenter.addObserver(
                self,
                selector: #selector(applicationDidActivate(_:)),
                name: NSWorkspace.didActivateApplicationNotification,
                object: workspace
            )
            isObserving = true
        }

        handler(workspace.frontmostApplication?.bundleIdentifier == bundleIdentifier)
    }

    func stop() {
        handler = nil
        guard isObserving else { return }
        workspace.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: workspace
        )
        isObserving = false
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        handler?(application?.bundleIdentifier == bundleIdentifier)
    }
}
