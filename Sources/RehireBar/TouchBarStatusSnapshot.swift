import Foundation
import AgentStatusCore

struct TouchBarStatusSnapshot: Equatable, Sendable {
    let usage: UsageSnapshot?
    let session: CurrentSessionSnapshot?
    let sessions: [CurrentSessionSnapshot]
    /// An empty collection is a successful observation that can remove old cards.
    /// A quota-only update carries no task observation and preserves those cards.
    let includesSessions: Bool

    init(
        usage: UsageSnapshot?,
        session: CurrentSessionSnapshot?,
        sessions: [CurrentSessionSnapshot]? = nil
    ) {
        self.usage = usage
        self.session = session
        self.sessions = sessions ?? session.map { [$0] } ?? []
        self.includesSessions = session != nil || sessions != nil
    }

    init(cached snapshot: StatusCacheSnapshot, now: Date = .now) {
        let usageObservedAt = snapshot.usageObservedAt ?? snapshot.observedAt ?? .distantPast
        let sessionObservedAt = snapshot.sessionObservedAt ?? snapshot.observedAt ?? .distantPast
        let contextObservedAt = snapshot.sessionContextObservedAt ?? sessionObservedAt
        let modelObservedAt = snapshot.sessionModelObservedAt ?? sessionObservedAt
        let referenceDate = now
        let contextIsFresh = referenceDate.timeIntervalSince(contextObservedAt)
            <= SessionEvidenceFreshness.runtimeContext
        let modelIsFresh = referenceDate.timeIntervalSince(modelObservedAt)
            <= SessionEvidenceFreshness.runtimeModel
        let primary = snapshot.primaryRemainingPercent.flatMap { remaining in
            snapshot.primaryResetAt.map {
                RawRateWindow(usedPercent: Double(100 - remaining), windowMinutes: 300,
                              resetsAt: $0.timeIntervalSince1970)
            }
        }
        let secondary = snapshot.secondaryRemainingPercent.flatMap { remaining in
            snapshot.secondaryResetAt.map {
                RawRateWindow(usedPercent: Double(100 - remaining), windowMinutes: 10_080,
                              resetsAt: $0.timeIntervalSince1970)
            }
        }
        let hydrated = try? UsageSnapshot.from(
            primary: primary,
            secondary: secondary,
            observedAt: usageObservedAt
        )
        let usage = hydrated.map {
            UsageSnapshot(primary: $0.primary, secondary: $0.secondary, observedAt: $0.observedAt,
                          isStale: true, primaryAvailable: $0.primaryAvailable,
                          secondaryAvailable: $0.secondaryAvailable)
        }

        let session: CurrentSessionSnapshot?
        if (contextIsFresh && snapshot.sessionUsedTokens != nil
                && snapshot.sessionContextWindow != nil)
            || (modelIsFresh && (snapshot.model != nil || snapshot.effort != nil)) {
            session = .init(
                sessionID: "cached-status",
                threadID: nil,
                usedTokens: contextIsFresh ? (snapshot.sessionUsedTokens ?? 0) : 0,
                contextWindow: contextIsFresh ? (snapshot.sessionContextWindow ?? 0) : 0,
                model: modelIsFresh ? snapshot.model : nil,
                effort: modelIsFresh ? snapshot.effort : nil,
                serviceTier: modelIsFresh ? snapshot.serviceTier : nil,
                observedAt: sessionObservedAt,
                contextObservedAt: contextIsFresh ? contextObservedAt : nil,
                modelObservedAt: modelIsFresh ? modelObservedAt : nil,
                isPlaceholder: true
            )
        } else {
            session = nil
        }

        self.init(usage: usage, session: session)
    }

    func markingUsageStale() -> Self {
        guard let usage else { return self }
        return .init(
            usage: .init(
                primary: usage.primary,
                secondary: usage.secondary,
                observedAt: usage.observedAt,
                isStale: true,
                primaryAvailable: usage.primaryAvailable,
                secondaryAvailable: usage.secondaryAvailable
            ),
            session: session,
            sessions: includesSessions ? sessions : nil
        )
    }

    func orderingSessions(by mode: SessionSortMode) -> Self {
        .init(usage: usage, session: session,
              sessions: includesSessions ? SessionMonitoringOrder.sorted(sessions, mode: mode) : nil)
    }
}

protocol StatusFetching: Sendable {
    func fetchStatus() async throws -> TouchBarStatusSnapshot
}

private enum SessionSnapshotMerger {
    static func mergedSessions(
        current: CurrentSessionSnapshot?,
        collection: [CurrentSessionSnapshot]
    ) -> [CurrentSessionSnapshot] {
        SessionMonitoringOrder.sorted(reconcile(current: current, collection: collection))
    }

    private static func reconcile(
        current: CurrentSessionSnapshot?,
        collection: [CurrentSessionSnapshot]
    ) -> [CurrentSessionSnapshot] {
        guard let current else { return collection }
        guard let identity = current.identity else { return [current] + collection }
        if let match = collection.first(where: { $0.identity == identity }) {
            return merging(current: current, match: match, collection: collection)
        }
        if current.isPlaceholder {
            let matches = collection.filter {
                $0.providerID == current.providerID && $0.threadID == current.threadID
            }
            // Focus tracking exposes only a thread UUID. Reconcile it to a host only
            // when the catalog makes that mapping unambiguous; never guess across
            // duplicate UUIDs on multiple hosts.
            if matches.count == 1, let match = matches.first {
                return [match] + collection.filter { $0.identity != match.identity }
            }
            if !matches.isEmpty { return collection }
        }
        return [current] + collection
    }

    private static func merging(
        current: CurrentSessionSnapshot,
        match: CurrentSessionSnapshot,
        collection: [CurrentSessionSnapshot]
    ) -> [CurrentSessionSnapshot] {
        let currentHasContext = current.contextWindow > 0 && current.usedTokens >= 0
            && (current.contextObservedAt ?? .distantPast) > (match.contextObservedAt ?? .distantPast)
        let currentHasModel = current.model != nil
            && (current.modelObservedAt ?? .distantPast) > (match.modelObservedAt ?? .distantPast)
        let merged = CurrentSessionSnapshot(
            sessionID: current.sessionID,
            threadID: current.threadID,
            title: match.title ?? current.title,
            usedTokens: currentHasContext ? current.usedTokens : match.usedTokens,
            contextWindow: currentHasContext ? current.contextWindow : match.contextWindow,
            model: currentHasModel ? current.model : match.model,
            effort: currentHasModel ? current.effort : match.effort,
            serviceTier: currentHasModel ? current.serviceTier : match.serviceTier,
            observedAt: max(current.observedAt, match.observedAt),
            lastActivityAt: [current.lastActivityAt, match.lastActivityAt].compactMap { $0 }.max(),
            contextObservedAt: currentHasContext
                ? current.contextObservedAt : match.contextObservedAt,
            modelObservedAt: currentHasModel
                ? current.modelObservedAt : match.modelObservedAt,
            activeSince: match.activeSince,
            isCompactingContext: match.isCompactingContext,
            projectName: match.projectName,
            projectID: match.projectID,
            hostName: match.hostName,
            providerID: match.providerID,
            hostID: match.hostID,
            hostKind: match.hostKind,
            openURL: match.openURL,
            isPlaceholder: false,
            executionStateObservedAt: match.executionStateObservedAt,
            executionState: match.executionState
        )
        return [merged] + collection.filter { $0.identity != match.identity }
    }
}

struct LiveSessionStatusProvider: StatusFetching, Sendable {
    private let session: any SessionFetching
    private let sessions: any SessionCollectionFetching
    private let now: @Sendable () -> Date

    init(
        session: any SessionFetching,
        sessions: any SessionCollectionFetching,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.session = session
        self.sessions = sessions
        self.now = now
    }

    func fetchStatus() async throws -> TouchBarStatusSnapshot {
        async let currentResult = result { try await session.fetchSession() }
        async let sessionsResult = result { try await sessions.fetchSessions() }
        let current = await currentResult.optionalValue?.expiringEvidence(at: now())
        let collectionResult = await sessionsResult
        let collection = SessionSnapshotMerger.mergedSessions(
            current: current,
            collection: collectionResult.optionalValue ?? []
        )
        guard current != nil || collectionResult.optionalValue != nil else { throw UsageError.unavailable }
        return TouchBarStatusSnapshot(
            usage: nil,
            session: collection.first ?? current,
            sessions: collection
        )
    }

    private func result<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> Result<Value, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
}

struct FocusedSessionStatusProvider: StatusFetching, Sendable {
    private let session: any SessionFetching
    private let now: @Sendable () -> Date

    init(session: any SessionFetching, now: @escaping @Sendable () -> Date = { .now }) {
        self.session = session
        self.now = now
    }

    func fetchStatus() async throws -> TouchBarStatusSnapshot {
        let focused = try await session.fetchSession().expiringEvidence(at: now())
        return TouchBarStatusSnapshot(usage: nil, session: focused)
    }
}

private extension Result {
    var optionalValue: Success? { try? get() }
}

struct UsageOnlyStatusProvider: StatusFetching, Sendable {
    let usage: any UsageFetching
    func fetchStatus() async throws -> TouchBarStatusSnapshot {
        TouchBarStatusSnapshot(usage: try await usage.fetch(), session: nil)
    }
}
