import AgentStatusCore
import Foundation

/// Loads the open Agent status contract from a directory of JSON documents.
/// Each document is isolated: a bad provider file cannot suppress healthy ones.
struct AgentStatusDirectoryProvider: SessionCollectionFetching, Sendable {
    static let maximumDocumentBytes = 1_048_576
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/RehireBar/agents")

    private let directories: [URL]
    private let now: @Sendable () -> Date

    init(
        directory: URL,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        directories = [directory]
        self.now = now
    }

    init(
        directories: [URL] = [Self.defaultDirectory],
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.directories = directories
        self.now = now
    }

    func fetchSessions() async throws -> [CurrentSessionSnapshot] {
        let directories = directories
        let referenceDate = now()
        return await Task.detached(priority: .utility) {
            let sessions = directories.flatMap { directory in
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                return files
                    .filter { $0.pathExtension.lowercased() == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .flatMap { Self.sessions(in: $0, directory: directory, now: referenceDate) }
            }
            return Self.latestSessions(sessions)
        }.value
    }

    private static func latestSessions(
        _ sessions: [CurrentSessionSnapshot]
    ) -> [CurrentSessionSnapshot] {
        var latest: [TaskIdentity: CurrentSessionSnapshot] = [:]
        for session in sessions {
            guard let identity = session.identity else { continue }
            if latest[identity].map({ $0.observedAt >= session.observedAt }) != true {
                latest[identity] = session
            }
        }
        return latest.values.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
            return ($0.providerID, $0.hostID, $0.threadID ?? "")
                < ($1.providerID, $1.hostID, $1.threadID ?? "")
        }
    }

    private static func sessions(in file: URL, directory: URL, now: Date) -> [CurrentSessionSnapshot] {
        guard let data = BoundedJSONFileReader.read(
            file, in: directory, maximumBytes: maximumDocumentBytes
        ),
              let document = try? decoder.decode(AgentStatusDocument.self, from: data),
              document.schemaVersion == AgentStatusDocument.currentSchemaVersion,
              let providerID = nonempty(document.providerID)
        else { return [] }

        return document.tasks.compactMap { task in
            guard let scopeID = nonempty(task.identity.scopeID),
                  let taskID = nonempty(task.identity.taskID),
                  let title = nonempty(task.title)
            else { return nil }

            let stateObservedAt = task.stateObservedAt ?? document.observedAt
            let state = stateForDisplay(task.state, observedAt: stateObservedAt, now: now)
            let contextObservedAt = task.contextObservedAt ?? document.observedAt
            let hasContext = (task.usedTokens ?? -1) >= 0
                && (task.contextWindow ?? 0) > 0
                && isFresh(
                    contextObservedAt,
                    now: now,
                    maximumAge: SessionEvidenceFreshness.persistedContext
                )
            let modelIsFresh = isFresh(
                document.observedAt,
                now: now,
                maximumAge: SessionEvidenceFreshness.runtimeModel
            )
            return CurrentSessionSnapshot(
                sessionID: "\(providerID)|\(scopeID)|\(taskID)",
                threadID: taskID,
                title: title,
                usedTokens: hasContext ? task.usedTokens! : 0,
                contextWindow: hasContext ? task.contextWindow! : 0,
                model: modelIsFresh ? nonempty(task.model) : nil,
                effort: modelIsFresh ? nonempty(task.effort) : nil,
                serviceTier: modelIsFresh ? nonempty(task.serviceTier) : nil,
                observedAt: document.observedAt,
                lastActivityAt: (task.lastActivityAt ?? task.activeSince).flatMap {
                    $0 <= now.addingTimeInterval(5) ? $0 : nil
                },
                contextObservedAt: hasContext ? contextObservedAt : nil,
                modelObservedAt: modelIsFresh && (task.model != nil || task.effort != nil)
                    ? document.observedAt : nil,
                activeSince: state == .working ? task.activeSince : nil,
                isCompactingContext: task.isCompactingContext && state == .working,
                projectName: nonempty(task.projectName),
                projectID: nonempty(task.projectID),
                hostName: task.location == .remote
                    ? (nonempty(task.locationLabel) ?? "Remote") : nil,
                providerID: providerID,
                hostID: scopeID,
                hostKind: task.location == .remote ? .unknown("agent-remote") : .local,
                openURL: task.openURL,
                executionStateObservedAt: stateObservedAt,
                executionState: state
            )
        }
    }

    /// Active claims fail closed when their provider stops publishing. Terminal
    /// states remain useful without a heartbeat and therefore do not expire.
    private static func stateForDisplay(
        _ state: AgentTaskState,
        observedAt: Date,
        now: Date
    ) -> SessionExecutionState {
        let mapped = SessionExecutionState(agentState: state)
        switch mapped {
        case .working, .syncing, .waiting:
            return isFresh(
                observedAt,
                now: now,
                maximumAge: SessionEvidenceFreshness.turnState
            )
                ? mapped : .unknown
        case .error, .idle, .unknown:
            return mapped
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func isFresh(_ observedAt: Date, now: Date, maximumAge: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= -5 && age <= maximumAge
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .compatibleISO8601
        return decoder
    }()
}

struct CombinedSessionCollectionProvider: SessionCollectionFetching, Sendable {
    let providers: [any SessionCollectionFetching]

    func fetchSessions() async throws -> [CurrentSessionSnapshot] {
        var sessions: [CurrentSessionSnapshot] = []
        var hasSuccessfulProvider = false
        for provider in providers {
            if let result = try? await provider.fetchSessions() {
                hasSuccessfulProvider = true
                sessions.append(contentsOf: result)
            }
        }
        guard hasSuccessfulProvider else { throw UsageError.unavailable }
        return sessions
    }
}

private extension SessionExecutionState {
    init(agentState: AgentTaskState) {
        self = switch agentState {
        case .working: .working
        case .syncing: .syncing
        case .waiting: .waiting
        case .error: .error
        case .idle: .idle
        case .unknown: .unknown
        }
    }
}
