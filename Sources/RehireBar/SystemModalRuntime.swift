import AppKit
import Darwin
import ObjectiveC.runtime

@MainActor
protocol SystemModalRuntime: AnyObject {
    func addSystemTrayItem(_ item: NSTouchBarItem) -> Bool
    func setTrayPresence(_ visible: Bool, identifier: NSTouchBarItem.Identifier)
    func setCloseBoxVisible(_ visible: Bool)
    func present(_ touchBar: NSTouchBar, trayIdentifier: NSTouchBarItem.Identifier) -> Bool
    func dismiss(_ touchBar: NSTouchBar) -> Bool
}

@MainActor
final class PrivateSystemModalRuntime: SystemModalRuntime {
    private typealias PresentFunction = @convention(c) (
        AnyClass, Selector, NSTouchBar, NSTouchBarItem.Identifier?
    ) -> Void
    private typealias DismissFunction = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void
    private typealias AddTrayFunction = @convention(c) (AnyClass, Selector, NSTouchBarItem) -> Void
    private typealias PresenceFunction = @convention(c) (NSString, Bool) -> Void
    private typealias CloseBoxFunction = @convention(c) (Bool) -> Void

    private let presentSelector = NSSelectorFromString(
        SystemModalPresentationPlan.controlStripPreserving.selectorName
    )
    private let dismissSelector = NSSelectorFromString("dismissSystemModalTouchBar:")
    private let addTraySelector = NSSelectorFromString("addSystemTrayItem:")
    private let runtimeHandle = dlopen(nil, RTLD_NOW)

    func addSystemTrayItem(_ item: NSTouchBarItem) -> Bool {
        guard requiredAPIsAreAvailable,
              let method = class_getClassMethod(NSTouchBarItem.self, addTraySelector) else {
            return false
        }
        let function = unsafeBitCast(method_getImplementation(method), to: AddTrayFunction.self)
        function(NSTouchBarItem.self, addTraySelector, item)
        return true
    }

    func setTrayPresence(_ visible: Bool, identifier: NSTouchBarItem.Identifier) {
        guard let runtimeHandle,
              let symbol = dlsym(runtimeHandle, "DFRElementSetControlStripPresenceForIdentifier") else {
            return
        }
        let function = unsafeBitCast(symbol, to: PresenceFunction.self)
        function(identifier.rawValue as NSString, visible)
    }

    func setCloseBoxVisible(_ visible: Bool) {
        guard let runtimeHandle,
              let symbol = dlsym(runtimeHandle, "DFRSystemModalShowsCloseBoxWhenFrontMost") else {
            return
        }
        let function = unsafeBitCast(symbol, to: CloseBoxFunction.self)
        function(visible)
    }

    func present(_ touchBar: NSTouchBar, trayIdentifier: NSTouchBarItem.Identifier) -> Bool {
        guard let method = class_getClassMethod(NSTouchBar.self, presentSelector) else {
            return false
        }
        let function = unsafeBitCast(method_getImplementation(method), to: PresentFunction.self)
        function(NSTouchBar.self, presentSelector, touchBar, trayIdentifier)
        return true
    }

    func dismiss(_ touchBar: NSTouchBar) -> Bool {
        guard let method = class_getClassMethod(NSTouchBar.self, dismissSelector) else {
            return false
        }
        let function = unsafeBitCast(method_getImplementation(method), to: DismissFunction.self)
        function(NSTouchBar.self, dismissSelector, touchBar)
        return true
    }

    private var requiredAPIsAreAvailable: Bool {
        guard let runtimeHandle else { return false }
        return class_getClassMethod(NSTouchBar.self, presentSelector) != nil
            && class_getClassMethod(NSTouchBar.self, dismissSelector) != nil
            && class_getClassMethod(NSTouchBarItem.self, addTraySelector) != nil
            && dlsym(runtimeHandle, "DFRElementSetControlStripPresenceForIdentifier") != nil
            && dlsym(runtimeHandle, "DFRSystemModalShowsCloseBoxWhenFrontMost") != nil
    }
}

@MainActor
final class SystemModalTouchBarBridge: TouchBarBridging {
    private let plan = SystemModalPresentationPlan.controlStripPreserving
    private let runtime: any SystemModalRuntime
    private var trayItem: NSTouchBarItem?
    private var retainedTouchBar: NSTouchBar?
    private var isPresented = false
    private var didOverrideCloseBox = false
    private lazy var restoreAction = RetainedTouchBarRestoreAction { [weak self] touchBar in
        _ = self?.restorePresentedTouchBar(touchBar)
    }

    var onRestore: (@MainActor @Sendable () -> Void)?

    init(runtime: any SystemModalRuntime = PrivateSystemModalRuntime()) {
        self.runtime = runtime
    }

    func preparePersistentAccess(_ touchBar: NSTouchBar) -> Bool {
        if retainedTouchBar === touchBar { return true }
        guard !isPresented,
              let identifier = plan.systemTrayIdentifier,
              setupControlStripTray() else {
            return false
        }

        retainedTouchBar = touchBar
        restoreAction.touchBar = touchBar
        runtime.setTrayPresence(true, identifier: identifier)
        return true
    }

    func activatePersistentAccess(_ touchBar: NSTouchBar) -> Bool {
        guard preparePersistentAccess(touchBar),
              let identifier = plan.systemTrayIdentifier else {
            return false
        }
        return presentRetainedTouchBar(touchBar, identifier: identifier)
    }

    func present(_ touchBar: NSTouchBar) -> Bool {
        if isPresented, retainedTouchBar === touchBar { return true }
        return activatePersistentAccess(touchBar)
    }

    func dismissOwnTouchBar() {
        guard let touchBar = retainedTouchBar,
              let identifier = plan.systemTrayIdentifier else {
            return
        }

        if isPresented {
            guard runtime.dismiss(touchBar) else { return }
        }
        releaseAllAccess(identifier: identifier)
    }

    func resetAndRepresent(_ touchBar: NSTouchBar) -> Bool {
        guard retainedTouchBar === touchBar,
              let identifier = plan.systemTrayIdentifier else { return false }
        if isPresented, !runtime.dismiss(touchBar) { return false }
        releaseAllAccess(identifier: identifier)
        return preparePersistentAccess(touchBar) && activatePersistentAccess(touchBar)
    }

    @discardableResult
    func restorePresentedTouchBar() -> Bool {
        guard let touchBar = retainedTouchBar else { return false }
        return restorePresentedTouchBar(touchBar)
    }

    private func restorePresentedTouchBar(_ touchBar: NSTouchBar) -> Bool {
        guard retainedTouchBar === touchBar else { return false }
        // Refresh even if both attempts fail, but never schedule another opening.
        let succeeded = presentOnUserRequest(touchBar)
        onRestore?()
        return succeeded
    }

    private func presentRetainedTouchBar(
        _ touchBar: NSTouchBar,
        identifier: NSTouchBarItem.Identifier
    ) -> Bool {
        beginModalOwnership()
        guard runtime.present(touchBar, trayIdentifier: identifier) else {
            isPresented = false
            endModalOwnership()
            return false
        }
        isPresented = true
        return true
    }

    private func beginModalOwnership() {
        guard !didOverrideCloseBox else { return }
        runtime.setCloseBoxVisible(false)
        didOverrideCloseBox = true
    }

    private func endModalOwnership() {
        guard didOverrideCloseBox else { return }
        runtime.setCloseBoxVisible(true)
        didOverrideCloseBox = false
    }

    private func releaseAllAccess(identifier: NSTouchBarItem.Identifier) {
        retainedTouchBar = nil
        isPresented = false
        restoreAction.touchBar = nil
        runtime.setTrayPresence(false, identifier: identifier)
        endModalOwnership()
    }

    private func setupControlStripTray() -> Bool {
        if trayItem != nil { return true }
        guard let identifier = plan.systemTrayIdentifier else { return false }

        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = StatusTrayButtonFactory().make(
            target: restoreAction,
            action: #selector(RetainedTouchBarRestoreAction.restore)
        )
        guard runtime.addSystemTrayItem(item) else { return false }
        trayItem = item
        return true
    }
}
