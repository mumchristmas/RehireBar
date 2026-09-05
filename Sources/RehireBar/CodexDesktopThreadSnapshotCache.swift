import Foundation

actor CodexDesktopThreadSnapshotCache: DesktopThreadSnapshotCaching {
    private struct Entry: Sendable {
        let snapshot: CodexDesktopThreadSnapshot?
        let lastSuccessAt: Date?
        let lastFailureAt: Date?
        let consecutiveFailures: Int
        let source: Source
        let expiresAt: Date
    }

    private enum Source: Sendable { case desktopIPC }

    private let upstream: any DesktopThreadSnapshotFetching
    private let successLifetime: TimeInterval
    private let failureLifetime: TimeInterval
    private let maximumFailureLifetime: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [TaskIdentity: Entry] = [:]
    private var inFlight: [TaskIdentity: Task<CodexDesktopThreadSnapshot, Error>] = [:]

    init(
        upstream: any DesktopThreadSnapshotFetching = CodexDesktopIPCClient(),
        successLifetime: TimeInterval = 1,
        failureLifetime: TimeInterval = 30,
        maximumFailureLifetime: TimeInterval = 240,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.upstream = upstream
        self.successLifetime = successLifetime
        self.failureLifetime = failureLifetime
        self.maximumFailureLifetime = maximumFailureLifetime
        self.now = now
    }

    func fetchThreadSnapshot(
        threadID: String,
        hostID: String
    ) async throws -> CodexDesktopThreadSnapshot {
        try await fetchThreadSnapshot(
            threadID: threadID,
            hostID: hostID,
            maximumAge: successLifetime
        )
    }

    func fetchThreadSnapshot(
        threadID: String,
        hostID: String,
        maximumAge: TimeInterval
    ) async throws -> CodexDesktopThreadSnapshot {
        let key = TaskIdentity(hostID: hostID, threadID: threadID)
        let referenceDate = now()
        if let entry = entries[key], entry.expiresAt > referenceDate {
            guard let snapshot = entry.snapshot else { throw UsageError.unavailable }
            return snapshot
        }
        if let entry = entries[key],
           let snapshot = entry.snapshot,
           let lastSuccessAt = entry.lastSuccessAt,
           referenceDate.timeIntervalSince(lastSuccessAt) < maximumAge {
            return snapshot
        }
        if let task = inFlight[key] { return try await task.value }
        let task = Task {
            try await upstream.fetchThreadSnapshot(threadID: threadID, hostID: hostID)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let snapshot = try await task.value
            guard snapshot.identity == key else { throw UsageError.unavailable }
            entries[key] = Entry(
                snapshot: snapshot,
                lastSuccessAt: now(),
                lastFailureAt: nil,
                consecutiveFailures: 0,
                source: .desktopIPC,
                expiresAt: now().addingTimeInterval(successLifetime)
            )
            return snapshot
        } catch {
            // Keep the last successful value available while backing off from a
            // transient IPC failure. Dropping it makes card metadata flicker and
            // turns a stale-but-useful snapshot into missing information.
            let previousSnapshot = entries[key]?.snapshot
            let previousSuccessAt = entries[key]?.lastSuccessAt
            let consecutiveFailures = min((entries[key]?.consecutiveFailures ?? 0) + 1, 8)
            let backoff = min(
                maximumFailureLifetime,
                failureLifetime * pow(2, Double(consecutiveFailures - 1))
            )
            let failureAt = max(now(), referenceDate)
            entries[key] = Entry(
                snapshot: previousSnapshot,
                lastSuccessAt: previousSuccessAt,
                lastFailureAt: failureAt,
                consecutiveFailures: consecutiveFailures,
                source: .desktopIPC,
                expiresAt: failureAt.addingTimeInterval(backoff)
            )
            throw error
        }
    }

    func cachedThreadSnapshot(
        threadID: String,
        hostID: String
    ) async -> CodexDesktopThreadSnapshot? {
        entries[TaskIdentity(hostID: hostID, threadID: threadID)]?.snapshot
    }
}
