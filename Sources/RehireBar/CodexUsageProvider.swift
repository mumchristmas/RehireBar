import Foundation

actor CodexUsageProvider: UsageFetching {
    private static let staleInterval: TimeInterval = 15 * 60
    private static let currentInterval: TimeInterval = 30

    private let primary: any UsageFetching
    private let fallback: any UsageFetching
    private let clock: @Sendable () -> Date
    private var cache: UsageSnapshot?

    init(
        primary: any UsageFetching,
        fallback: any UsageFetching,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.primary = primary
        self.fallback = fallback
        self.clock = clock
    }

    func fetch() async throws -> UsageSnapshot {
        do {
            return try accept(try await primary.fetch())
        } catch {
            do {
                return try accept(try await fallback.fetch())
            } catch {
                guard let cache, age(of: cache) <= Self.staleInterval else {
                    throw UsageError.unavailable
                }
                return UsageSnapshot(
                    primary: cache.primary,
                    secondary: cache.secondary,
                    observedAt: cache.observedAt,
                    isStale: true,
                    primaryAvailable: cache.primaryAvailable,
                    secondaryAvailable: cache.secondaryAvailable
                )
            }
        }
    }

    private func accept(_ snapshot: UsageSnapshot) throws -> UsageSnapshot {
        let snapshotAge = age(of: snapshot)
        guard snapshotAge <= Self.staleInterval else { throw UsageError.unavailable }
        cache = snapshot
        return UsageSnapshot(
            primary: snapshot.primary,
            secondary: snapshot.secondary,
            observedAt: snapshot.observedAt,
            isStale: snapshotAge > Self.currentInterval,
            primaryAvailable: snapshot.primaryAvailable,
            secondaryAvailable: snapshot.secondaryAvailable
        )
    }

    private func age(of snapshot: UsageSnapshot) -> TimeInterval {
        max(0, clock().timeIntervalSince(snapshot.observedAt))
    }
}
