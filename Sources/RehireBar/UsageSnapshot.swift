import Foundation

enum UsageError: Error, Equatable, Sendable {
    case unsupportedWindows
    case unavailable
}

struct RawRateWindow: Equatable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: TimeInterval
}

struct RateWindow: Equatable, Sendable {
    let label: String
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date

    init(label: String, usedPercent: Double, windowMinutes: Int, resetsAt: TimeInterval) {
        self.label = label
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = Date(timeIntervalSince1970: resetsAt)
    }

    var remainingPercent: Int {
        Int((100 - min(100, max(0, usedPercent))).rounded())
    }
}

struct UsageSnapshot: Equatable, Sendable {
    let primary: RateWindow
    let secondary: RateWindow
    let observedAt: Date
    let isStale: Bool
    let primaryAvailable: Bool
    let secondaryAvailable: Bool

    init(
        primary: RateWindow,
        secondary: RateWindow,
        observedAt: Date,
        isStale: Bool,
        primaryAvailable: Bool = true,
        secondaryAvailable: Bool = true
    ) {
        self.primary = primary
        self.secondary = secondary
        self.observedAt = observedAt
        self.isStale = isStale
        self.primaryAvailable = primaryAvailable
        self.secondaryAvailable = secondaryAvailable
    }

    static func from(
        primary: RawRateWindow?,
        secondary: RawRateWindow?,
        observedAt: Date
    ) throws -> Self {
        let windows = [primary, secondary].compactMap { $0 }
        let fiveHour = windows.last { $0.windowMinutes == 300 }
        let sevenDay = windows.last { $0.windowMinutes == 10_080 }
        guard fiveHour != nil || sevenDay != nil else {
            throw UsageError.unsupportedWindows
        }

        return .init(
            primary: fiveHour.map {
                .init(label: "5H", usedPercent: $0.usedPercent, windowMinutes: 300, resetsAt: $0.resetsAt)
            } ?? .init(
                label: "5H",
                usedPercent: 100,
                windowMinutes: 300,
                resetsAt: 0
            ),
            secondary: sevenDay.map {
                .init(label: "7D", usedPercent: $0.usedPercent, windowMinutes: 10_080, resetsAt: $0.resetsAt)
            } ?? .init(
                label: "7D",
                usedPercent: 100,
                windowMinutes: 10_080,
                resetsAt: 0
            ),
            observedAt: observedAt,
            isStale: false,
            primaryAvailable: fiveHour != nil,
            secondaryAvailable: sevenDay != nil
        )
    }
}
