import AppKit

@MainActor
protocol ApplicationMenuManaging: AnyObject {
    func start()
    func stop()
}

/// Gives the accessory application an explicit, discoverable lifecycle without
/// taking space from the Touch Bar itself.
@MainActor
final class ApplicationMenuController: NSObject, ApplicationMenuManaging, NSMenuDelegate, NSMenuItemValidation {
    private let statusBar: NSStatusBar
    private let onShow: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void
    private let sortMode: @MainActor () -> SessionSortMode
    private let onSortModeChange: @MainActor (SessionSortMode) -> Void
    private let version: ApplicationVersion
    private let updater: any ApplicationUpdating
    private var statusItem: NSStatusItem?

    init(
        statusBar: NSStatusBar = .system,
        onShow: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) },
        sortMode: @escaping @MainActor () -> SessionSortMode = { .runningFirst },
        onSortModeChange: @escaping @MainActor (SessionSortMode) -> Void = { _ in },
        version: ApplicationVersion = .current,
        updater: any ApplicationUpdating = NoopApplicationUpdater()
    ) {
        self.statusBar = statusBar
        self.onShow = onShow
        self.onQuit = onQuit
        self.sortMode = sortMode
        self.onSortModeChange = onSortModeChange
        self.version = version
        self.updater = updater
    }

    func start() {
        guard statusItem == nil else { return }
        updater.start()
        let item = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = StatusSymbol.makeImage()
            image.size = NSSize(width: 18, height: 18)
            button.image = image
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "RehireBar"
        }

        item.menu = Self.makeMenu(target: self)
        statusItem = item
    }

    static func makeMenu(target: ApplicationMenuController) -> NSMenu {
        let menu = NSMenu(title: "RehireBar")
        let versionItem = NSMenuItem(title: target.version.displayText, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(checkForUpdates), keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Show Touch Bar",
            action: #selector(showTouchBar),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        let orderItem = NSMenuItem(title: "Task order", action: nil, keyEquivalent: "")
        let orderMenu = NSMenu(title: "Task order")
        orderMenu.delegate = target
        for mode in SessionSortMode.allCases {
            let item = NSMenuItem(
                title: mode == .runningFirst ? "Running first" : "Waiting first",
                action: #selector(changeTaskOrder(_:)), keyEquivalent: ""
            )
            item.representedObject = mode.rawValue
            item.target = target
            item.state = target.sortMode() == mode ? .on : .off
            orderMenu.addItem(item)
        }
        orderItem.submenu = orderMenu
        menu.addItem(orderItem)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit RehireBar",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        for item in menu.items where !item.isSeparatorItem && item.submenu == nil {
            item.target = target
        }
        return menu
    }

    func stop() {
        guard let statusItem else { return }
        statusBar.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc private func showTouchBar() { onShow() }
    @objc private func quit() { onQuit() }
    @objc private func checkForUpdates() {
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) { return updater.canCheckForUpdates }
        return menuItem.action != nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            guard let value = item.representedObject as? String,
                  let mode = SessionSortMode(rawValue: value) else { continue }
            item.state = mode == sortMode() ? .on : .off
        }
    }

    @objc private func changeTaskOrder(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String,
              let mode = SessionSortMode(rawValue: value) else { return }
        onSortModeChange(mode)
        if let menu = item.menu { menuWillOpen(menu) }
    }
}

@MainActor
final class NoopApplicationMenuController: ApplicationMenuManaging {
    func start() {}
    func stop() {}
}
