import Foundation

enum TouchBarRecoveryAction: Equatable {
    case none
    case refreshAndRepresent
    case resetCompositionAndRepresent
    case relaunchApplication
}

enum TouchBarRecoveryObservation: Equatable {
    case presentationSucceeded
    case presentationFailed
    case manualInteraction
    case recoveryFailed(TouchBarRecoveryAction)
    case relaunchRequested
}

struct TouchBarRecoveryController {
    static let healthInterval: TimeInterval = 15
    static let relaunchCooldown: TimeInterval = 300
    private var nextAction: TouchBarRecoveryAction = .none
    private var lastRelaunchAt: Date?

    mutating func observe(_ observation: TouchBarRecoveryObservation, at now: Date = Date()) {
        switch observation {
        case .presentationSucceeded: nextAction = .none
        case .presentationFailed, .manualInteraction: nextAction = .refreshAndRepresent
        case .recoveryFailed(.refreshAndRepresent): nextAction = .resetCompositionAndRepresent
        case .recoveryFailed(.resetCompositionAndRepresent): nextAction = .relaunchApplication
        case .recoveryFailed, .relaunchRequested:
            lastRelaunchAt = now
            nextAction = .none
        }
    }

    func evaluate(at now: Date = Date()) -> TouchBarRecoveryAction {
        if nextAction == .relaunchApplication,
           let lastRelaunchAt,
           now.timeIntervalSince(lastRelaunchAt) < Self.relaunchCooldown { return .none }
        return nextAction
    }
}
