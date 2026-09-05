import Foundation

public struct StatusCacheSnapshot: Codable, Equatable, Sendable {
    public let primaryRemainingPercent: Int?
    public let secondaryRemainingPercent: Int?
    public let sessionUsedTokens: Int?
    public let sessionContextWindow: Int?
    public let model: String?
    public let effort: String?
    public let serviceTier: String?
    /// Kept for decoding snapshots written before source-specific timestamps existed.
    public let observedAt: Date?
    public let usageObservedAt: Date?
    public let sessionObservedAt: Date?
    public let sessionContextObservedAt: Date?
    public let sessionModelObservedAt: Date?
    public let primaryResetAt: Date?
    public let secondaryResetAt: Date?

    public init(
        primaryRemainingPercent: Int?,
        secondaryRemainingPercent: Int?,
        sessionUsedTokens: Int?,
        sessionContextWindow: Int?,
        model: String?,
        effort: String?,
        serviceTier: String? = nil,
        observedAt: Date?,
        usageObservedAt: Date? = nil,
        sessionObservedAt: Date? = nil,
        sessionContextObservedAt: Date? = nil,
        sessionModelObservedAt: Date? = nil,
        primaryResetAt: Date? = nil,
        secondaryResetAt: Date? = nil
    ) {
        self.primaryRemainingPercent = primaryRemainingPercent
        self.secondaryRemainingPercent = secondaryRemainingPercent
        self.sessionUsedTokens = sessionUsedTokens
        self.sessionContextWindow = sessionContextWindow
        self.model = model
        self.effort = effort
        self.serviceTier = serviceTier
        self.observedAt = observedAt
        self.usageObservedAt = usageObservedAt
        self.sessionObservedAt = sessionObservedAt
        self.sessionContextObservedAt = sessionContextObservedAt
        self.sessionModelObservedAt = sessionModelObservedAt
        self.primaryResetAt = primaryResetAt
        self.secondaryResetAt = secondaryResetAt
    }

    public static let unavailable = StatusCacheSnapshot(
        primaryRemainingPercent: nil,
        secondaryRemainingPercent: nil,
        sessionUsedTokens: nil,
        sessionContextWindow: nil,
        model: nil,
        effort: nil,
        observedAt: nil
    )

    public var hasDisplayValues: Bool {
        primaryRemainingPercent != nil || secondaryRemainingPercent != nil
            || sessionUsedTokens != nil || sessionContextWindow != nil
            || model != nil || effort != nil || serviceTier != nil
    }
}
