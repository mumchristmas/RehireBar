import Foundation

/// Optional local test output. Mirrors the coordinator's complete rendered order;
/// the normal app does not write this file unless explicitly launched with a path.
@MainActor
final class StatusDiagnosticsPublisher: StatusPublishing {
    private let base: any StatusPublishing
    private let outputURL: URL

    init(base: any StatusPublishing, outputURL: URL) {
        self.base = base
        self.outputURL = outputURL
    }

    func publish(_ status: TouchBarStatusSnapshot) {
        base.publish(status)
        let document = Document(
            processID: ProcessInfo.processInfo.processIdentifier,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            writtenAt: .now,
            tasks: status.sessions.map(TaskRecord.init)
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: outputURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        } catch {
            NSLog("Could not write monitoring test snapshot [%@]", String(describing: type(of: error)))
        }
    }

    private struct Document: Encodable {
        let processID: Int32
        let version: String?
        let build: String?
        let writtenAt: Date
        let tasks: [TaskRecord]
    }

    private struct TaskRecord: Encodable {
        let providerID: String
        let scopeID: String
        let taskID: String?
        let title: String?
        let projectID: String?
        let projectName: String?
        let state: String
        let lastActivityAt: Date?
        let stateObservedAt: Date?
        let observedAt: Date

        init(_ snapshot: CurrentSessionSnapshot) {
            providerID = snapshot.providerID
            scopeID = snapshot.hostID
            taskID = snapshot.threadID
            title = snapshot.title
            projectID = snapshot.projectID
            projectName = snapshot.projectName
            state = snapshot.executionState.rawValue
            lastActivityAt = snapshot.lastActivityAt
            stateObservedAt = snapshot.executionStateObservedAt
            observedAt = snapshot.observedAt
        }
    }
}
