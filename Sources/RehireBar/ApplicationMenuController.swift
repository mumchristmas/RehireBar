import AppKit

@MainActor
protocol ApplicationMenuManaging: AnyObject {
    func start()
    func stop()
}

/// Gives the accessory application an explicit, discoverable lifecycle without
/// taking space from the Touch Bar itself.
@MainActor
final class ApplicationMenuController: NSObject, ApplicationMenuManaging {
    private let statusBar: NSStatusBar
    private let onShow: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void
    private var statusItem: NSStatusItem?

    init(
        statusBar: NSStatusBar = .system,
        onShow: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.statusBar = statusBar
        self.onShow = onShow
        self.onQuit = onQuit
    }

    func start() {
        guard statusItem == nil else { return }
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
        menu.addItem(
            withTitle: "Show Touch Bar",
            action: #selector(showTouchBar),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit RehireBar",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        menu.items.forEach { $0.target = target }
        return menu
    }

    func stop() {
        guard let statusItem else { return }
        statusBar.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc private func showTouchBar() { onShow() }
    @objc private func quit() { onQuit() }
}

@MainActor
final class NoopApplicationMenuController: ApplicationMenuManaging {
    func start() {}
    func stop() {}
}
