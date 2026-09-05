import AgentStatusCore
import Foundation

@MainActor
protocol StatusPublishing: AnyObject {
    func publish(_ status: TouchBarStatusSnapshot)
}

@MainActor
final class StatusCachePublisher: StatusPublishing, StatusCacheLoading {
    private let store: StatusCacheStore
    private let clock: @MainActor @Sendable () -> Date
    private var lastPublished: StatusCacheSnapshot?

    init(
        store: StatusCacheStore = .init(),
        clock: @escaping @MainActor @Sendable () -> Date = { .now }
    ) {
        self.store = store
        self.clock = clock
    }

    func publish(_ status: TouchBarStatusSnapshot) {
        let snapshot = StatusCacheSnapshot(status: status, observedAt: clock())
        guard snapshot != lastPublished else { return }
        store.save(snapshot)
        lastPublished = snapshot
    }

    func loadStatusCache() -> StatusCacheSnapshot {
        let snapshot = store.load()
        lastPublished = snapshot
        return snapshot
    }
}

extension StatusCacheSnapshot {
    init(status: TouchBarStatusSnapshot, observedAt: Date = .now) {
        let sourceDates = [status.usage?.observedAt, status.session?.observedAt].compactMap { $0 }
        self.init(
            primaryRemainingPercent: status.usage.flatMap {
                $0.primaryAvailable ? $0.primary.remainingPercent : nil
            },
            secondaryRemainingPercent: status.usage.flatMap {
                $0.secondaryAvailable ? $0.secondary.remainingPercent : nil
            },
            sessionUsedTokens: status.session.flatMap {
                $0.contextWindow > 0 ? $0.usedTokens : nil
            },
            sessionContextWindow: status.session.flatMap {
                $0.contextWindow > 0 ? $0.contextWindow : nil
            },
            model: status.session?.model,
            effort: status.session?.effort,
            serviceTier: status.session?.serviceTier,
            observedAt: sourceDates.max() ?? observedAt,
            usageObservedAt: status.usage?.observedAt,
            sessionObservedAt: status.session?.observedAt,
            sessionContextObservedAt: status.session?.contextObservedAt,
            sessionModelObservedAt: status.session?.modelObservedAt,
            primaryResetAt: status.usage.flatMap {
                $0.primaryAvailable ? $0.primary.resetsAt : nil
            },
            secondaryResetAt: status.usage.flatMap {
                $0.secondaryAvailable ? $0.secondary.resetsAt : nil
            }
        )
    }
}
