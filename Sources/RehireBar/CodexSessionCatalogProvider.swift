import Darwin
import Foundation
import SQLite3

/// Reads Codex Desktop's cross-host thread index and enriches visible local and remote tasks
/// with the minimal runtime snapshot already held by Codex Desktop.
struct CodexSessionCatalogProvider: SessionCollectionFetching, Sendable {
    private static let maximumRuntimeSnapshots = 4

    private let root: URL
    private let selectedThread: SelectedThreadState?
    private let approvalStore: ConversationApprovalStore?
    private let now: @Sendable () -> Date
    private let maximumCatalogRows: Int
    private let desktopSnapshots: (any DesktopThreadSnapshotFetching)?
    private let appThreadStatuses: (any CodexAppThreadStatusFetching)?
    private let threadMetadata: (any ThreadMetadataReading)?
    private let threadMetadataCache: (any ThreadMetadataCaching)?
    private let rolloutSnapshots: any SessionSnapshotCaching
    private let catalogRows: CatalogRowCache
    private let runtimeSchedule: CatalogRuntimeSchedule

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex"),
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/sqlite/codex-dev.db"),
        selectedThread: SelectedThreadState? = nil,
        approvalStore: ConversationApprovalStore? = nil,
        desktopSnapshots: (any DesktopThreadSnapshotFetching)? = nil,
        appThreadStatuses: (any CodexAppThreadStatusFetching)? = nil,
        threadMetadata: (any ThreadMetadataReading)? = nil,
        threadMetadataCache: (any ThreadMetadataCaching)? = nil,
        rolloutSnapshots: any SessionSnapshotCaching = SessionSnapshotCache(),
        now: @escaping @Sendable () -> Date = { .now },
        maximumCatalogRows: Int = 256,
        minimumRuntimeReadInterval: TimeInterval = 2.5
    ) {
        self.root = root
        self.selectedThread = selectedThread
        self.approvalStore = approvalStore
        self.desktopSnapshots = desktopSnapshots
        self.appThreadStatuses = appThreadStatuses
        self.threadMetadata = threadMetadata
        self.threadMetadataCache = threadMetadataCache
            ?? threadMetadata.map { ThreadMetadataCache(reader: $0) }
        self.rolloutSnapshots = rolloutSnapshots
        self.catalogRows = CatalogRowCache(databaseURL: databaseURL)
        self.now = now
        self.maximumCatalogRows = max(1, maximumCatalogRows)
        self.runtimeSchedule = CatalogRuntimeSchedule(minimumInterval: minimumRuntimeReadInterval)
    }

    func fetchSessions() async throws -> [CurrentSessionSnapshot] {
        let root = root
        let selectedThreadID = selectedThread?.threadID
        let approvalStore = approvalStore
        let threadMetadata = threadMetadata
        let threadMetadataCache = threadMetadataCache
        let rolloutSnapshots = rolloutSnapshots
        let now = now
        let rows = try await catalogRows.rows(limit: maximumCatalogRows)
        guard !rows.isEmpty else { throw UsageError.unavailable }
        let rolloutCandidates = await Task.detached(priority: .utility) {
            let localIDs = Set(rows.lazy.filter { $0.hostKind == .local }.map(\.threadID))
            return SessionLogUsageProvider.candidateFiles(root: root).filter { candidate in
                CurrentSessionProvider.threadID(inRolloutFilename: candidate.file)
                    .map(localIDs.contains) == true
            }
        }.value
        var localPairs: [(TaskIdentity, CurrentSessionSnapshot)] = []
        for candidate in rolloutCandidates {
            try Task.checkCancellation()
            if let snapshot = await rolloutSnapshots.snapshot(in: candidate),
               let threadID = snapshot.threadID {
                localPairs.append((TaskIdentity(hostID: "local", threadID: threadID), snapshot))
            }
        }
        let localSnapshots = Dictionary(
            localPairs,
            uniquingKeysWith: { first, second in
                first.observedAt >= second.observedAt ? first : second
            }
        )

        var metadataByIdentity: [TaskIdentity: CodexThreadMetadata] = [:]
        for row in rows where row.hostKind == .local {
            let metadata: CodexThreadMetadata?
            if let threadMetadataCache {
                metadata = await threadMetadataCache.metadata(
                    for: row.identity,
                    sourceVersion: max(row.sourceRecencyAt, row.sourceUpdatedAt)
                )
            } else {
                metadata = await Task.detached(priority: .utility) {
                    try? threadMetadata?.metadata(for: row.threadID)
                }.value ?? nil
            }
            metadataByIdentity[row.identity] = metadata
        }
        let baseSessions = await Task.detached {
            let referenceDate = now()
            let waitingIdentities = Set(
                (try? approvalStore?.pending(at: referenceDate))?.map {
                    TaskIdentity(hostID: $0.hostID ?? "local", threadID: $0.threadID)
                } ?? []
            )
            return rows.map { row in
                let local = localSnapshots[row.identity]
                let metadata = metadataByIdentity[row.identity]
                let lastActivity = max(local?.observedAt ?? .distantPast, row.recency)
                let localStateIsFresh = local?.executionStateObservedAt.map {
                    referenceDate.timeIntervalSince($0) <= SessionEvidenceFreshness.turnState
                } ?? false
                let state: SessionExecutionState
                if waitingIdentities.contains(row.identity) {
                    state = .waiting
                } else if row.hostKind.isRemote {
                    state = .unknown
                } else {
                    state = Self.safePersistedState(local, stateIsFresh: localStateIsFresh)
                }
                let hasFreshLocalContext = local.map {
                    referenceDate.timeIntervalSince($0.observedAt)
                        <= SessionEvidenceFreshness.persistedContext
                } ?? false
                let localModelAt = local?.modelObservedAt ?? local?.observedAt
                let localModelIsFresh = localModelAt.map {
                    referenceDate.timeIntervalSince($0) <= SessionEvidenceFreshness.runtimeModel
                } ?? false
                let metadataModelIsFresh = metadata != nil
                    && referenceDate.timeIntervalSince(row.sourceUpdatedAt)
                        <= SessionEvidenceFreshness.runtimeModel
                let useLocalModel = localModelIsFresh && local?.model != nil
                let model = useLocalModel
                    ? local?.model : (metadataModelIsFresh ? metadata?.model : nil)
                let effort = useLocalModel
                    ? local?.effort : (metadataModelIsFresh ? metadata?.effort : nil)
                let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return CatalogSession(
                    row: row,
                    snapshot: CurrentSessionSnapshot(
                        sessionID: local?.sessionID ?? row.threadID,
                        threadID: row.threadID,
                        title: title.isEmpty ? nil : title,
                        usedTokens: hasFreshLocalContext ? (local?.usedTokens ?? 0) : 0,
                        contextWindow: hasFreshLocalContext ? (local?.contextWindow ?? 0) : 0,
                        model: model,
                        effort: effort,
                        serviceTier: localModelIsFresh ? local?.serviceTier : nil,
                        observedAt: lastActivity,
                        lastActivityAt: [
                            local?.lastActivityAt,
                            row.sourceRecencyAt.timeIntervalSince1970 > 0
                                && row.sourceRecencyAt <= referenceDate.addingTimeInterval(5)
                                ? row.sourceRecencyAt : nil,
                        ].compactMap { $0 }.max(),
                        contextObservedAt: hasFreshLocalContext
                            ? local?.contextObservedAt : nil,
                        modelObservedAt: useLocalModel
                            ? localModelAt
                            : (metadataModelIsFresh ? row.sourceUpdatedAt : nil),
                        activeSince: local?.activeSince,
                        isCompactingContext: local?.isCompactingContext ?? false,
                        projectName: Self.projectName(from: row.cwd),
                        projectID: row.projectID ?? row.cwd,
                        hostName: row.hostKind.displayName(routeID: row.hostID),
                        hostID: row.hostID,
                        hostKind: row.hostKind,
                        executionStateObservedAt: state == .idle && !localStateIsFresh
                            ? nil : local?.executionStateObservedAt,
                        executionState: state
                    )
                )
            }
        }.value

        let liveStatuses: [CodexAppThreadStatus]
        let remoteHostStatuses: [CodexRemoteHostStatus]
        if let appThreadStatuses {
            liveStatuses = (try? await appThreadStatuses.fetchThreadStatuses()) ?? []
            remoteHostStatuses = (try? await appThreadStatuses.fetchRemoteHostStatuses()) ?? []
        } else {
            liveStatuses = []
            remoteHostStatuses = []
        }
        let rowsByThreadID = Dictionary(grouping: baseSessions, by: { $0.row.threadID })
        let resolvedLiveStatuses = liveStatuses.compactMap { status -> (TaskIdentity, CodexAppThreadStatus)? in
            if let identity = status.identity { return (identity, status) }
            guard let matches = rowsByThreadID[status.threadID], matches.count == 1,
                  let match = matches.first
            else { return nil }
            return (match.row.identity, status)
        }
        let liveByKey = Dictionary(
            resolvedLiveStatuses,
            uniquingKeysWith: { first, second in
                first.updatedAt >= second.updatedAt ? first : second
            }
        )
        let latestHostStatus = Dictionary(
            remoteHostStatuses.map { ($0.hostID, $0) },
            uniquingKeysWith: { first, second in
                first.updatedAt >= second.updatedAt ? first : second
            }
        )
        let statusMerged = baseSessions.map { session in
            guard let status = liveByKey[session.row.identity] else { return session }
            if session.snapshot.executionState == .waiting {
                return session
            }
            // Local rollout events are the primary source of truth. Desktop logs can
            // omit turn-complete notifications, so an older log event must never
            // resurrect a task that the append-only rollout already completed.
            if session.row.hostKind == .local,
               let localEventAt = session.snapshot.executionStateObservedAt,
               localEventAt >= status.updatedAt {
                return session
            }
            // A host reconnect/recovery boundary invalidates every older task
            // transition from that host. This prevents a pre-disconnect RUN from
            // returning after Desktop finishes synchronization.
            if session.row.hostKind.isRemote,
               let hostStatus = latestHostStatus[session.row.hostID],
               hostStatus.updatedAt > status.updatedAt {
                return session
            }
            if Self.requiresFreshTurnEvidence(status.executionState),
               now().timeIntervalSince(status.updatedAt) > SessionEvidenceFreshness.turnState {
                return session
            }
            return CatalogSession(
                row: session.row,
                snapshot: Self.merging(status: status, into: session.snapshot)
            )
        }
        guard let desktopSnapshots else {
            return SessionMonitoringOrder.sorted(Self.applyingHostConnectionState(
                to: statusMerged,
                hostStatuses: remoteHostStatuses
            ))
        }
        // Read cached evidence for the whole collection. The viewport size is
        // never a limit on which tasks can be monitored or enriched.
        var runtimeByIndex: [Int: CodexDesktopThreadSnapshot] = [:]
        var knownActive = Set<TaskIdentity>()
        if let cache = desktopSnapshots as? any DesktopThreadSnapshotCaching {
            for (index, session) in statusMerged.enumerated() {
                if let snapshot = await cache.cachedThreadSnapshot(
                    threadID: session.row.threadID,
                    hostID: session.row.hostID
                ), snapshot.identity == session.row.identity {
                    runtimeByIndex[index] = snapshot
                    if snapshot.executionState?.needsFrequentObservation == true {
                        knownActive.insert(session.row.identity)
                    }
                }
            }
        }
        let candidates = await runtimeSchedule.candidates(
            in: statusMerged, knownActive: knownActive, selectedThreadID: selectedThreadID,
            now: now(),
            limit: Self.maximumRuntimeSnapshots
        )
        if let cache = desktopSnapshots as? any DesktopThreadSnapshotCaching {
            for (_, session) in candidates {
                let isHighValueRuntime = knownActive.contains(session.row.identity)
                    || session.snapshot.executionState.needsFrequentObservation
                    || session.snapshot.isCompactingContext
                // Refresh idle snapshots before the 15-second state deadline.
                // Using the deadline itself caused a 12-second idle cadence plus
                // catalog latency to cross the boundary before refresh began.
                let maximumAge: TimeInterval = isHighValueRuntime ? 4 : 5
                Task(priority: .utility) {
                    _ = try? await cache.fetchThreadSnapshot(
                        threadID: session.row.threadID,
                        hostID: session.row.hostID,
                        maximumAge: maximumAge
                    )
                }
            }
        } else {
            runtimeByIndex = await Self.fetchRuntimeSnapshots(
                candidates: candidates,
                upstream: desktopSnapshots,
                budget: 0.8
            )
        }
        let runtimeMerged = statusMerged.enumerated().map { index, session in
            guard let runtime = runtimeByIndex[index], runtime.identity == session.row.identity
            else { return session }
            return CatalogSession(
                row: session.row,
                snapshot: Self.merging(runtime: runtime, into: session.snapshot, now: now())
            )
        }
        return SessionMonitoringOrder.sorted(Self.applyingHostConnectionState(
            to: runtimeMerged,
            hostStatuses: remoteHostStatuses
        ))
    }

    private static func fetchRuntimeSnapshots(
        candidates: [(offset: Int, element: CatalogSession)],
        upstream: any DesktopThreadSnapshotFetching,
        budget: TimeInterval
    ) async -> [Int: CodexDesktopThreadSnapshot] {
        guard !candidates.isEmpty else { return [:] }
        enum Event: Sendable {
            case snapshot(Int, CodexDesktopThreadSnapshot?)
            case deadline
        }
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let tasks = candidates.map { index, session in
            Task(priority: .utility) {
                let snapshot = try? await upstream.fetchThreadSnapshot(
                    threadID: session.row.threadID,
                    hostID: session.row.hostID
                )
                continuation.yield(.snapshot(index, snapshot))
            }
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(budget))
            if !Task.isCancelled { continuation.yield(.deadline) }
        }
        var received = 0
        var result: [Int: CodexDesktopThreadSnapshot] = [:]
        for await event in stream {
            switch event {
            case .snapshot(let index, let snapshot):
                received += 1
                if let snapshot { result[index] = snapshot }
                if received == candidates.count { continuation.finish() }
            case .deadline:
                continuation.finish()
            }
        }
        deadline.cancel()
        for task in tasks { task.cancel() }
        return result
    }

    private static func merging(
        status: CodexAppThreadStatus,
        into snapshot: CurrentSessionSnapshot
    ) -> CurrentSessionSnapshot {
        CurrentSessionSnapshot(
            sessionID: snapshot.sessionID,
            threadID: snapshot.threadID,
            title: snapshot.title,
            usedTokens: snapshot.usedTokens,
            contextWindow: snapshot.contextWindow,
            model: snapshot.model,
            effort: snapshot.effort,
            serviceTier: snapshot.serviceTier,
            observedAt: max(snapshot.observedAt, status.updatedAt),
            lastActivityAt: [snapshot.lastActivityAt, status.activeSince].compactMap { $0 }.max(),
            contextObservedAt: snapshot.contextObservedAt,
            modelObservedAt: snapshot.modelObservedAt,
            activeSince: status.executionState == .working ? status.activeSince : nil,
            isCompactingContext: snapshot.isCompactingContext,
            projectName: snapshot.projectName,
            projectID: snapshot.projectID,
            hostName: snapshot.hostName,
            providerID: snapshot.providerID,
            hostID: snapshot.hostID,
            hostKind: snapshot.hostKind,
            openURL: snapshot.openURL,
            executionStateObservedAt: status.updatedAt,
            executionState: status.executionState
        )
    }

    private static func safePersistedState(
        _ snapshot: CurrentSessionSnapshot?,
        stateIsFresh: Bool
    ) -> SessionExecutionState {
        guard let state = snapshot?.executionState else { return .unknown }
        if requiresFreshTurnEvidence(state), !stateIsFresh { return .unknown }
        return state
    }

    private static func requiresFreshTurnEvidence(_ state: SessionExecutionState) -> Bool {
        switch state {
        case .working, .waiting, .error: true
        case .syncing, .idle, .unknown: false
        }
    }

    private static func merging(
        runtime: CodexDesktopThreadSnapshot,
        into snapshot: CurrentSessionSnapshot,
        now: Date
    ) -> CurrentSessionSnapshot {
        let runtimeAge = max(0, now.timeIntervalSince(runtime.observedAt))
        let hasContext = runtimeAge <= SessionEvidenceFreshness.runtimeContext
            && (runtime.contextWindow ?? 0) > 0 && (runtime.usedTokens ?? -1) >= 0
        let hasModel = runtimeAge <= SessionEvidenceFreshness.runtimeModel
        let runtimeCanSupplyState = snapshot.executionState != .waiting
            && runtime.executionState != nil
            && runtimeAge <= SessionEvidenceFreshness.runtimeState
            && runtime.observedAt >= (snapshot.executionStateObservedAt ?? .distantPast)
        let executionState = runtimeCanSupplyState
            ? runtime.executionState ?? snapshot.executionState
            : snapshot.executionState
        return CurrentSessionSnapshot(
            sessionID: snapshot.sessionID,
            threadID: snapshot.threadID,
            title: snapshot.title,
            usedTokens: hasContext ? runtime.usedTokens! : snapshot.usedTokens,
            contextWindow: hasContext ? runtime.contextWindow! : snapshot.contextWindow,
            model: hasModel ? (runtime.model ?? snapshot.model) : snapshot.model,
            effort: hasModel ? (runtime.effort ?? snapshot.effort) : snapshot.effort,
            serviceTier: hasModel ? (runtime.serviceTier ?? snapshot.serviceTier)
                : snapshot.serviceTier,
            observedAt: max(snapshot.observedAt, runtime.observedAt),
            lastActivityAt: snapshot.lastActivityAt,
            contextObservedAt: hasContext
                ? runtime.observedAt : snapshot.contextObservedAt,
            modelObservedAt: hasModel && (
                runtime.model != nil || runtime.effort != nil || runtime.serviceTier != nil
            ) ? runtime.observedAt : snapshot.modelObservedAt,
            activeSince: executionState == .working
                ? (snapshot.activeSince ?? runtime.observedAt) : nil,
            isCompactingContext: runtimeCanSupplyState
                ? (runtime.isCompactingContext ?? false) : snapshot.isCompactingContext,
            projectName: snapshot.projectName,
            projectID: snapshot.projectID,
            hostName: snapshot.hostName,
            providerID: snapshot.providerID,
            hostID: snapshot.hostID,
            hostKind: snapshot.hostKind,
            openURL: snapshot.openURL,
            executionStateObservedAt: runtimeCanSupplyState
                ? runtime.observedAt : snapshot.executionStateObservedAt,
            executionState: executionState
        )
    }

    private static func applyingHostConnectionState(
        to sessions: [CatalogSession],
        hostStatuses: [CodexRemoteHostStatus]
    ) -> [CurrentSessionSnapshot] {
        let synchronizingHosts = Dictionary(
            hostStatuses.lazy.filter(\.isSynchronizing).map { ($0.hostID, $0) },
            uniquingKeysWith: { first, second in
                first.updatedAt >= second.updatedAt ? first : second
            }
        )
        return sessions.map { session in
            guard session.row.hostKind.isRemote,
                  let hostStatus = synchronizingHosts[session.row.hostID]
            else { return session.snapshot }
            return markingRemoteSync(session.snapshot, observedAt: hostStatus.updatedAt)
        }
    }

    private static func markingRemoteSync(
        _ snapshot: CurrentSessionSnapshot,
        observedAt: Date
    ) -> CurrentSessionSnapshot {
        CurrentSessionSnapshot(
            sessionID: snapshot.sessionID,
            threadID: snapshot.threadID,
            title: snapshot.title,
            usedTokens: snapshot.usedTokens,
            contextWindow: snapshot.contextWindow,
            model: snapshot.model,
            effort: snapshot.effort,
            serviceTier: snapshot.serviceTier,
            observedAt: snapshot.observedAt,
            lastActivityAt: snapshot.lastActivityAt,
            contextObservedAt: snapshot.contextObservedAt,
            modelObservedAt: snapshot.modelObservedAt,
            activeSince: nil,
            isCompactingContext: false,
            projectName: snapshot.projectName,
            projectID: snapshot.projectID,
            hostName: snapshot.hostName,
            providerID: snapshot.providerID,
            hostID: snapshot.hostID,
            hostKind: snapshot.hostKind,
            openURL: snapshot.openURL,
            executionStateObservedAt: observedAt,
            executionState: .syncing
        )
    }

    fileprivate static func readRows(from databaseURL: URL, limit: Int) throws -> [CatalogRow] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { sqlite3_close(database) }

        let projectColumn = hasProjectIDColumn(in: database) ? "c.project_id" : "NULL"
        let sql = """
        SELECT c.thread_id, c.display_title, c.cwd,
               COALESCE(c.source_recency_at, 0),
               COALESCE(c.source_updated_at, 0),
               h.host_id, h.host_kind, \(projectColumn)
        FROM local_thread_catalog AS c
        JOIN local_thread_catalog_hosts AS h ON h.host_id = c.host_id
        WHERE COALESCE(c.missing_candidate, 0) = 0
        ORDER BY MAX(COALESCE(c.source_recency_at, 0), COALESCE(c.source_updated_at, 0)) DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int(statement, 1, Int32(limit)) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var rows: [CatalogRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let threadID = text(in: statement, column: 0),
                  let hostID = text(in: statement, column: 5),
                  let hostKind = text(in: statement, column: 6)
            else { continue }
            let sourceRecencyAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let sourceUpdatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            rows.append(CatalogRow(
                threadID: threadID.lowercased(),
                title: text(in: statement, column: 1) ?? "",
                cwd: text(in: statement, column: 2),
                projectID: text(in: statement, column: 7).flatMap {
                    let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : value
                },
                recency: max(sourceRecencyAt, sourceUpdatedAt),
                sourceRecencyAt: sourceRecencyAt,
                sourceUpdatedAt: sourceUpdatedAt,
                hostID: hostID,
                hostKind: CodexHostKind(catalogValue: hostKind)
            ))
        }
        return rows
    }

    private static func text(in statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: value)
    }

    private static func hasProjectIDColumn(in database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(local_thread_catalog)", -1,
                               &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(in: statement, column: 1) == "project_id" { return true }
        }
        return false
    }

    private static func projectName(from cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(filePath: cwd).lastPathComponent
        return name.isEmpty ? nil : name
    }

}

private struct CatalogRow: Sendable {
    let threadID: String
    let title: String
    let cwd: String?
    let projectID: String?
    let recency: Date
    let sourceRecencyAt: Date
    let sourceUpdatedAt: Date
    let hostID: String
    let hostKind: CodexHostKind

    var identity: TaskIdentity { TaskIdentity(hostID: hostID, threadID: threadID) }
    var isRemote: Bool { hostKind.isRemote }
}

private struct CatalogSession: Sendable {
    let row: CatalogRow
    let snapshot: CurrentSessionSnapshot
}

/// Give active tasks frequent observations while reserving discovery capacity.
/// A task outside the first screen must not be permanently excluded from IPC.
private actor CatalogRuntimeSchedule {
    private let minimumInterval: TimeInterval
    private var lastBatchAt: Date?
    private var generation: UInt64 = 0
    private var lastRequested: [TaskIdentity: UInt64] = [:]

    init(minimumInterval: TimeInterval) { self.minimumInterval = max(0, minimumInterval) }

    func candidates(
        in sessions: [CatalogSession],
        knownActive: Set<TaskIdentity>,
        selectedThreadID: String?,
        now: Date,
        limit: Int
    ) -> [(offset: Int, element: CatalogSession)] {
        if let lastBatchAt {
            let elapsed = now.timeIntervalSince(lastBatchAt)
            if elapsed >= 0 && elapsed < minimumInterval { return [] }
        }
        lastBatchAt = now
        let identities = Set(sessions.map { $0.row.identity })
        lastRequested = lastRequested.filter { identities.contains($0.key) }
        let selectedMatches = sessions.filter { $0.row.threadID == selectedThreadID }
        let selectedIdentity = selectedMatches.count == 1 ? selectedMatches.first?.row.identity : nil
        let ordered = sessions.enumerated().sorted { lhs, rhs in
            let lhsAttempt = lastRequested[lhs.element.row.identity] ?? 0
            let rhsAttempt = lastRequested[rhs.element.row.identity] ?? 0
            if lhsAttempt != rhsAttempt { return lhsAttempt < rhsAttempt }
            if lhs.element.row.recency != rhs.element.row.recency {
                return lhs.element.row.recency > rhs.element.row.recency
            }
            return lhs.offset < rhs.offset
        }
        let highValue = ordered.filter {
            knownActive.contains($0.element.row.identity)
                || $0.element.snapshot.executionState.needsFrequentObservation
                || $0.element.row.identity == selectedIdentity
        }
        var selected = Array(highValue.prefix(max(0, limit - 1)))
        let selectedIDs = Set(selected.map { $0.element.row.identity })
        selected += ordered.filter { !selectedIDs.contains($0.element.row.identity) }
            .prefix(max(0, limit - selected.count))
        generation += 1
        for candidate in selected { lastRequested[candidate.element.row.identity] = generation }
        return selected
    }
}

private actor CatalogRowCache {
    private struct FileSignature: Equatable, Sendable {
        let inode: UInt64
        let size: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private struct StoreSignature: Equatable, Sendable {
        let database: FileSignature?
        let writeAheadLog: FileSignature?
    }

    private let databaseURL: URL
    private var cachedSignature: StoreSignature?
    private var cachedLimit = 0
    private var cachedRows: [CatalogRow] = []

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func rows(limit: Int) async throws -> [CatalogRow] {
        let signature = Self.signature(of: databaseURL)
        if signature == cachedSignature, cachedLimit >= limit {
            return Array(cachedRows.prefix(limit))
        }
        let databaseURL = databaseURL
        let loaded: [CatalogRow]
        do {
            loaded = try await Task.detached(priority: .utility) {
                try CodexSessionCatalogProvider.readRows(from: databaseURL, limit: limit)
            }.value
        } catch {
            guard !cachedRows.isEmpty else { throw error }
            return Array(cachedRows.prefix(limit))
        }
        // Codex updates the catalog and its host table independently. A reader can
        // briefly observe no joined rows even though the task history still exists.
        // Keep the last non-empty row set, but do not accept the new signature so
        // the next refresh retries instead of pinning the empty observation.
        guard !loaded.isEmpty else {
            return Array(cachedRows.prefix(limit))
        }
        cachedSignature = signature
        cachedLimit = limit
        cachedRows = loaded
        return loaded
    }

    private static func signature(of databaseURL: URL) -> StoreSignature {
        StoreSignature(
            database: fileSignature(at: databaseURL.path),
            writeAheadLog: fileSignature(at: databaseURL.path + "-wal")
        )
    }

    private static func fileSignature(at path: String) -> FileSignature? {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return FileSignature(
            inode: UInt64(info.st_ino),
            size: UInt64(max(0, info.st_size)),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }
}
