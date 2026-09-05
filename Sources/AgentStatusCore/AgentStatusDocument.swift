import Foundation

/// Versioned status document written by an Agent integration.
///
/// Each provider owns one JSON file and may publish any number of tasks. The app
/// treats providers independently, so one malformed or unavailable provider does
/// not hide tasks from another provider.
public struct AgentStatusDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let providerID: String
    public let observedAt: Date
    public let tasks: [AgentTaskSnapshot]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        providerID: String,
        observedAt: Date,
        tasks: [AgentTaskSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.observedAt = observedAt
        self.tasks = tasks
    }
}

/// Stable task identity inside one Agent provider.
///
/// `scopeID` identifies the machine, workspace, team, or other namespace that
/// owns a task. Together, provider + scope + task remain collision-free in a
/// multi-Agent installation.
public struct AgentTaskIdentity: Codable, Hashable, Sendable {
    public let scopeID: String
    public let taskID: String

    public init(scopeID: String, taskID: String) {
        self.scopeID = scopeID
        self.taskID = taskID
    }
}

public enum AgentTaskState: String, Codable, Equatable, Sendable {
    case working
    case syncing
    case waiting
    case error
    case idle
    case unknown
}

public enum AgentTaskLocation: String, Codable, Equatable, Sendable {
    case local
    case remote
}

/// Presentation-neutral task data shared by all Agent integrations.
///
/// Optional fields must remain absent when the provider cannot establish them.
/// The Touch Bar decides how to lay out the available facts.
public struct AgentTaskSnapshot: Codable, Equatable, Sendable {
    public let identity: AgentTaskIdentity
    public let title: String
    public let projectName: String?
    public let projectID: String?
    public let location: AgentTaskLocation
    public let locationLabel: String?
    public let state: AgentTaskState
    public let stateObservedAt: Date?
    public let activeSince: Date?
    public let lastActivityAt: Date?
    public let model: String?
    public let effort: String?
    public let serviceTier: String?
    public let usedTokens: Int?
    public let contextWindow: Int?
    public let contextObservedAt: Date?
    public let isCompactingContext: Bool
    public let openURL: URL?

    public init(
        identity: AgentTaskIdentity,
        title: String,
        projectName: String? = nil,
        projectID: String? = nil,
        location: AgentTaskLocation = .local,
        locationLabel: String? = nil,
        state: AgentTaskState,
        stateObservedAt: Date? = nil,
        activeSince: Date? = nil,
        lastActivityAt: Date? = nil,
        model: String? = nil,
        effort: String? = nil,
        serviceTier: String? = nil,
        usedTokens: Int? = nil,
        contextWindow: Int? = nil,
        contextObservedAt: Date? = nil,
        isCompactingContext: Bool = false,
        openURL: URL? = nil
    ) {
        self.identity = identity
        self.title = title
        self.projectName = projectName
        self.projectID = projectID
        self.location = location
        self.locationLabel = locationLabel
        self.state = state
        self.stateObservedAt = stateObservedAt
        self.activeSince = activeSince
        self.lastActivityAt = lastActivityAt
        self.model = model
        self.effort = effort
        self.serviceTier = serviceTier
        self.usedTokens = usedTokens
        self.contextWindow = contextWindow
        self.contextObservedAt = contextObservedAt
        self.isCompactingContext = isCompactingContext
        self.openURL = openURL
    }
}
