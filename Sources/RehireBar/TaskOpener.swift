import AppKit
import Foundation

@MainActor
protocol TaskOpening: AnyObject {
    @discardableResult
    func open(_ url: URL) -> Bool
}

enum CodexTaskDeepLink {
    static func url(threadID: String) -> URL? {
        guard let threadID = UUID(uuidString: threadID)?.uuidString.lowercased() else {
            return nil
        }
        return URL(string: "codex://threads/\(threadID)")
    }
}

@MainActor
final class WorkspaceTaskOpener: TaskOpening {
    @discardableResult
    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

@MainActor
final class UnavailableTaskOpener: TaskOpening {
    @discardableResult
    func open(_ url: URL) -> Bool { false }
}
