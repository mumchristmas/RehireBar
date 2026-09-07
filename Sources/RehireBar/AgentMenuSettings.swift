import Foundation

/// Preferences affect presentation only; collection and evidence expiry continue.
@MainActor
final class AgentMenuSettings {
    enum Option: String, CaseIterable {
        case showTasks, showRemoteTasks

        var title: String {
            switch self {
            case .showTasks: "Show tasks in Touch Bar"
            case .showRemoteTasks: "Show remote tasks"
            }
        }
    }

    static let preferenceKey = "agentPresentationSettings"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var knownProviderIDs: Set<String> {
        Set((defaults.dictionary(forKey: Self.preferenceKey) ?? [:]).keys)
    }

    func value(_ option: Option, providerID: String) -> Bool {
        let providers = defaults.dictionary(forKey: Self.preferenceKey) ?? [:]
        return (providers[providerID] as? [String: Bool])?[option.rawValue] ?? true
    }

    func toggle(_ option: Option, providerID: String) {
        var providers = defaults.dictionary(forKey: Self.preferenceKey) ?? [:]
        var values = providers[providerID] as? [String: Bool] ?? [:]
        values[option.rawValue] = !value(option, providerID: providerID)
        providers[providerID] = values
        defaults.set(providers, forKey: Self.preferenceKey)
    }

    func applying(to status: TouchBarStatusSnapshot) -> TouchBarStatusSnapshot {
        func visible(_ session: CurrentSessionSnapshot) -> Bool {
            value(.showTasks, providerID: session.providerID)
                && (!session.isRemote || value(.showRemoteTasks, providerID: session.providerID))
        }
        return .init(
            usage: status.usage,
            session: status.session.flatMap { visible($0) ? $0 : nil },
            sessions: status.includesSessions ? status.sessions.filter(visible) : nil
        )
    }
}

struct AgentMenuEntry: Sendable {
    let providerID: String
    let observedAt: Date?

    var title: String { providerID == "codex" ? "Codex" : providerID }

    enum Status: Equatable {
        case current, stale, unavailable, invalidTime

        var title: String {
            switch self {
            case .current: "Up to date"
            case .stale: "Stale"
            case .unavailable: "No data"
            case .invalidTime: "Invalid time"
            }
        }

        var detail: String {
            switch self {
            case .current: "Status received within the last 30 seconds."
            case .stale: "The last status is over 30 seconds old."
            case .unavailable: "No status evidence is available; the connection cannot be confirmed."
            case .invalidTime: "The source timestamp is more than five seconds in the future."
            }
        }
    }

    func status(at now: Date) -> Status {
        guard let observedAt else { return .unavailable }
        let age = now.timeIntervalSince(observedAt)
        guard age >= -5 else { return .invalidTime }
        return age <= SessionEvidenceFreshness.turnState ? .current : .stale
    }

    /// A catalog read alone is not a live connection. Use source state evidence.
    static func codex(sessions: [CurrentSessionSnapshot]) -> Self {
        .init(providerID: "codex", observedAt: sessions
            .filter { $0.providerID == "codex" && !$0.isPlaceholder }
            .compactMap(\.executionStateObservedAt).max())
    }
}
