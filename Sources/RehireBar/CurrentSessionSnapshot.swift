import Foundation

enum SessionSortMode: String, CaseIterable, Sendable {
    case runningFirst = "running-first"
    case waitingFirst = "waiting-first"

    static let preferenceKey = "taskSortMode"

    init(preference: String?) {
        self = preference.flatMap(Self.init(rawValue:)) ?? .runningFirst
    }
}

enum SessionExecutionState: String, Equatable, Sendable {
    case working
    case syncing
    case waiting
    case error
    case idle
    case unknown

    func monitoringPriority(for mode: SessionSortMode) -> Int {
        if mode == .waitingFirst {
            switch self {
            case .waiting: return 0
            case .error: return 1
            case .working: return 2
            case .syncing: return 3
            case .idle, .unknown: return 4
            }
        }
        return switch self {
        case .working: 0
        case .waiting: 1
        case .error: 2
        case .syncing: 3
        case .idle, .unknown: 4
        }
    }

    var needsFrequentObservation: Bool {
        switch self {
        case .working, .syncing, .waiting: true
        case .error, .idle, .unknown: false
        }
    }
}

/// Monitoring order is independent of the foreground task and of polling times.
enum SessionMonitoringOrder {
    private struct ProjectKey: Hashable {
        let providerID: String
        let hostID: String
        let projectID: String
    }

    private struct ProjectActivity {
        var isActive = false
        var lastActivityAt: Date?
    }

    static func sorted(
        _ sessions: [CurrentSessionSnapshot], mode: SessionSortMode = .runningFirst
    ) -> [CurrentSessionSnapshot] {
        var projects: [ProjectKey: ProjectActivity] = [:]
        for session in sessions {
            guard let key = projectKey(for: session) else { continue }
            var activity = projects[key] ?? ProjectActivity()
            activity.isActive = activity.isActive || session.executionState.needsFrequentObservation
            activity.lastActivityAt = [activity.lastActivityAt, session.lastActivityAt]
                .compactMap { $0 }.max()
            projects[key] = activity
        }
        func activity(for session: CurrentSessionSnapshot) -> ProjectActivity {
            projectKey(for: session).flatMap { projects[$0] }
                ?? ProjectActivity(isActive: session.executionState.needsFrequentObservation,
                                   lastActivityAt: session.lastActivityAt)
        }
        return sessions.sorted { lhs, rhs in
            let leftPriority = lhs.executionState.monitoringPriority(for: mode)
            let rightPriority = rhs.executionState.monitoringPriority(for: mode)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            let leftProject = activity(for: lhs)
            let rightProject = activity(for: rhs)
            if leftProject.isActive != rightProject.isActive { return leftProject.isActive }
            if leftProject.lastActivityAt != rightProject.lastActivityAt {
                return (leftProject.lastActivityAt ?? .distantPast)
                    > (rightProject.lastActivityAt ?? .distantPast)
            }
            if lhs.lastActivityAt != rhs.lastActivityAt {
                return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
            }
            return (lhs.providerID, lhs.hostID, lhs.threadID ?? lhs.sessionID)
                < (rhs.providerID, rhs.hostID, rhs.threadID ?? rhs.sessionID)
        }
    }

    private static func projectKey(for session: CurrentSessionSnapshot) -> ProjectKey? {
        session.projectID.map {
            ProjectKey(providerID: session.providerID, hostID: session.hostID, projectID: $0)
        }
    }
}

enum SessionEvidenceFreshness {
    static let runtimeState: TimeInterval = 15
    static let turnState: TimeInterval = 30
    static let runtimeContext: TimeInterval = 60
    static let runtimeModel: TimeInterval = 300
    static let persistedContext: TimeInterval = 300
}

/// A task is scoped to the provider and runtime that own it. Task identifiers are
/// never used alone as cross-provider or cross-host keys.
struct TaskIdentity: Hashable, Sendable {
    let providerID: String
    let hostID: String
    let threadID: String

    init(providerID: String = "codex", hostID: String, threadID: String) {
        self.providerID = providerID
        self.hostID = hostID
        self.threadID = providerID == "codex" ? threadID.lowercased() : threadID
    }
}

enum CodexHostKind: Hashable, Sendable {
    case local
    case ssh
    case wsl
    case remoteControl
    case unknown(String)

    init(catalogValue: String) {
        switch catalogValue.lowercased() {
        case "local": self = .local
        case "ssh": self = .ssh
        case "wsl": self = .wsl
        case "remote-control": self = .remoteControl
        default: self = .unknown(catalogValue)
        }
    }

    var isRemote: Bool {
        if case .local = self { return false }
        return true
    }

    /// Route identifiers are data, not labels. In particular, a
    /// `remote-control:<environment-id>` must never reach the Touch Bar.
    func displayName(routeID: String, preferredName: String? = nil) -> String? {
        if let preferredName = preferredName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !preferredName.isEmpty {
            return preferredName
        }
        switch self {
        case .local: return nil
        case .ssh:
            let candidate = routeID.split(separator: ":").last.map(String.init)
            return candidate?.isEmpty == false ? candidate : "Remote"
        case .wsl: return "WSL"
        case .remoteControl, .unknown: return "Remote"
        }
    }
}

enum SanitizedDiagnostic {
    static func identifier(_ value: Any?) -> String {
        guard let value = value as? String, !value.isEmpty else { return "-" }
        return String(value.prefix(8))
    }

    static func errorCategory(_ value: Any?) -> String {
        guard let value else { return "-" }
        if let dictionary = value as? [String: Any],
           let code = dictionary["code"] as? String {
            let safe = code.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return safe.isEmpty ? "present" : String(safe.prefix(32))
        }
        return "present"
    }
}

struct CurrentSessionSnapshot: Equatable, Sendable {
    let sessionID: String
    let threadID: String?
    let title: String?
    let usedTokens: Int
    let contextWindow: Int
    let model: String?
    let effort: String?
    let serviceTier: String?
    let observedAt: Date
    /// Source-reported task activity, independent of heartbeat/observation time.
    let lastActivityAt: Date?
    let contextObservedAt: Date?
    let modelObservedAt: Date?
    let activeSince: Date?
    let isCompactingContext: Bool
    let projectName: String?
    /// Scoped project identity used only for ordering, never to merge tasks.
    let projectID: String?
    let hostName: String?
    let providerID: String
    let hostID: String
    let hostKind: CodexHostKind
    let openURL: URL?
    let isPlaceholder: Bool
    /// Timestamp of the event that established `executionState`.
    /// A nil value means the state was inferred or came from an undated snapshot.
    let executionStateObservedAt: Date?
    let executionState: SessionExecutionState

    init(
        sessionID: String,
        threadID: String? = nil,
        title: String? = nil,
        usedTokens: Int,
        contextWindow: Int,
        model: String?,
        effort: String?,
        serviceTier: String? = nil,
        observedAt: Date,
        lastActivityAt: Date? = nil,
        contextObservedAt: Date? = nil,
        modelObservedAt: Date? = nil,
        activeSince: Date? = nil,
        isCompactingContext: Bool = false,
        projectName: String? = nil,
        projectID: String? = nil,
        hostName: String? = nil,
        isRemote: Bool = false,
        providerID: String = "codex",
        hostID: String? = nil,
        hostKind: CodexHostKind? = nil,
        openURL: URL? = nil,
        isPlaceholder: Bool = false,
        executionStateObservedAt: Date? = nil,
        executionState: SessionExecutionState = .unknown
    ) {
        self.sessionID = sessionID
        self.threadID = threadID
        self.title = title
        self.usedTokens = usedTokens
        self.contextWindow = contextWindow
        self.model = model
        self.effort = effort
        self.serviceTier = serviceTier
        self.observedAt = observedAt
        self.lastActivityAt = lastActivityAt
        self.contextObservedAt = contextWindow > 0 && usedTokens >= 0
            ? (contextObservedAt ?? observedAt) : nil
        self.modelObservedAt = model != nil || effort != nil || serviceTier != nil
            ? (modelObservedAt ?? observedAt) : nil
        self.activeSince = activeSince
        self.isCompactingContext = isCompactingContext
        self.projectName = projectName
        self.projectID = projectID
        self.hostName = hostName
        self.providerID = providerID
        self.hostID = hostID ?? (isRemote ? "remote-unknown" : "local")
        self.hostKind = hostKind ?? (isRemote ? .unknown("remote") : .local)
        self.openURL = openURL
        self.isPlaceholder = isPlaceholder
        self.executionStateObservedAt = executionStateObservedAt
        self.executionState = executionState
    }

    var identity: TaskIdentity? {
        threadID.map { TaskIdentity(providerID: providerID, hostID: hostID, threadID: $0) }
    }

    var isRemote: Bool { hostKind.isRemote }

    var isFastMode: Bool {
        guard let serviceTier else { return false }
        return ["priority", "fast"].contains(serviceTier.lowercased())
    }

    /// The coordinator also ages retained facts when all collectors fail. Without
    /// this final boundary a disconnected source could leave its last RUN lit forever.
    func expiringEvidence(at now: Date) -> Self {
        func isFresh(_ date: Date?, maximumAge: TimeInterval) -> Bool {
            guard let date else { return false }
            let age = now.timeIntervalSince(date)
            return age >= -5 && age <= maximumAge
        }
        let activeState = [.working, .syncing, .waiting].contains(executionState)
        let stateExpired = activeState && !isFresh(
            executionStateObservedAt ?? observedAt, maximumAge: SessionEvidenceFreshness.turnState
        )
        let contextIsFresh = isFresh(contextObservedAt, maximumAge: SessionEvidenceFreshness.persistedContext)
        let modelIsFresh = isFresh(modelObservedAt, maximumAge: SessionEvidenceFreshness.runtimeModel)
        return .init(
            sessionID: sessionID, threadID: threadID, title: title,
            usedTokens: contextIsFresh ? usedTokens : 0,
            contextWindow: contextIsFresh ? contextWindow : 0,
            model: modelIsFresh ? model : nil, effort: modelIsFresh ? effort : nil,
            serviceTier: modelIsFresh ? serviceTier : nil, observedAt: observedAt,
            lastActivityAt: lastActivityAt,
            contextObservedAt: contextIsFresh ? contextObservedAt : nil,
            modelObservedAt: modelIsFresh ? modelObservedAt : nil,
            activeSince: stateExpired ? nil : activeSince,
            isCompactingContext: !stateExpired && isCompactingContext,
            projectName: projectName, projectID: projectID, hostName: hostName,
            providerID: providerID, hostID: hostID, hostKind: hostKind,
            openURL: openURL, isPlaceholder: isPlaceholder,
            executionStateObservedAt: executionStateObservedAt,
            executionState: stateExpired ? .unknown : executionState
        )
    }
}

protocol SessionFetching: Sendable {
    func fetchSession() async throws -> CurrentSessionSnapshot
}

protocol SessionCollectionFetching: Sendable {
    func fetchSessions() async throws -> [CurrentSessionSnapshot]
}
