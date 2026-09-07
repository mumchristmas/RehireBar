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
    private let agentSettings: AgentMenuSettings
    private let agentEntries: @MainActor () async -> [AgentMenuEntry]
    private let onAgentSettingsChange: @MainActor () -> Void
    private var knownAgents: [String: AgentMenuEntry] = [
        "codex": .init(providerID: "codex", observedAt: nil)
    ]
    private var agentRefreshTask: Task<Void, Never>?
    private var statusItem: NSStatusItem?

    init(
        statusBar: NSStatusBar = .system,
        onShow: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) },
        sortMode: @escaping @MainActor () -> SessionSortMode = { .runningFirst },
        onSortModeChange: @escaping @MainActor (SessionSortMode) -> Void = { _ in },
        version: ApplicationVersion = .current,
        updater: any ApplicationUpdating = NoopApplicationUpdater(),
        agentSettings: AgentMenuSettings = AgentMenuSettings(),
        agentEntries: @escaping @MainActor () async -> [AgentMenuEntry] = {
            [.init(providerID: "codex", observedAt: nil)]
        },
        onAgentSettingsChange: @escaping @MainActor () -> Void = {}
    ) {
        self.statusBar = statusBar
        self.onShow = onShow
        self.onQuit = onQuit
        self.sortMode = sortMode
        self.onSortModeChange = onSortModeChange
        self.version = version
        self.updater = updater
        self.agentSettings = agentSettings
        self.agentEntries = agentEntries
        self.onAgentSettingsChange = onAgentSettingsChange
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
        menu.delegate = target
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
        let agentsItem = NSMenuItem(title: "Agents", action: nil, keyEquivalent: "")
        let agentsMenu = NSMenu(title: "Agents")
        agentsMenu.identifier = NSUserInterfaceItemIdentifier("agents")
        agentsMenu.delegate = target
        agentsItem.submenu = agentsMenu
        menu.addItem(agentsItem)
        target.updateAgentsMenu(agentsMenu)
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
        agentRefreshTask?.cancel()
        agentRefreshTask = nil
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
        let agentsMenu = menu.identifier?.rawValue == "agents" ? menu
            : menu.items.first { $0.submenu?.identifier?.rawValue == "agents" }?.submenu
        if let agentsMenu {
            updateAgentsMenu(agentsMenu)
            agentRefreshTask?.cancel()
            agentRefreshTask = Task { [weak self, weak agentsMenu] in
                guard let self else { return }
                let entries = await self.agentEntries()
                guard !Task.isCancelled, let agentsMenu else { return }
                self.receiveAgentEntries(entries)
                self.updateAgentsMenu(agentsMenu)
            }
        }
        if let id = menu.identifier?.rawValue, id.hasPrefix("agent:") {
            updateAgentSubmenu(menu, providerID: String(id.dropFirst(6)))
        }
        for item in menu.items where item.action == #selector(changeTaskOrder(_:)) {
            guard let value = item.representedObject as? String,
                  let mode = SessionSortMode(rawValue: value) else { continue }
            item.state = mode == sortMode() ? .on : .off
        }
    }

    func receiveAgentEntries(_ entries: [AgentMenuEntry]) {
        // Keep discovered providers visible when their file disappears, but discard
        // old evidence so a failed or missing source cannot look connected.
        for id in Set(knownAgents.keys).union(agentSettings.knownProviderIDs) {
            knownAgents[id] = .init(providerID: id, observedAt: nil)
        }
        for entry in entries {
            if let previous = knownAgents[entry.providerID]?.observedAt,
               let date = entry.observedAt, previous > date { continue }
            knownAgents[entry.providerID] = entry
        }
    }

    private func updateAgentsMenu(_ menu: NSMenu) {
        for id in agentSettings.knownProviderIDs where knownAgents[id] == nil {
            knownAgents[id] = .init(providerID: id, observedAt: nil)
        }
        let ids = knownAgents.keys.sorted {
            if ($0 == "codex") != ($1 == "codex") { return $0 == "codex" }
            return $0 < $1
        }
        for (index, id) in ids.enumerated() {
            let item: NSMenuItem
            if let existing = menu.items.first(where: { ($0.representedObject as? String) == id }) {
                item = existing
            } else {
                item = NSMenuItem(title: knownAgents[id]!.title, action: nil, keyEquivalent: "")
                item.representedObject = id
                let submenu = NSMenu(title: item.title)
                submenu.identifier = NSUserInterfaceItemIdentifier("agent:" + id)
                submenu.delegate = self
                item.submenu = submenu
                menu.insertItem(item, at: min(index, menu.items.count))
            }
            if let submenu = item.submenu { updateAgentSubmenu(submenu, providerID: id) }
        }
    }

    private func updateAgentSubmenu(_ menu: NSMenu, providerID: String) {
        guard let entry = knownAgents[providerID] else { return }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
            for option in AgentMenuSettings.Option.allCases {
                let item = NSMenuItem(title: option.title, action: #selector(toggleAgentOption(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [providerID, option.rawValue]
                menu.addItem(item)
            }
        }
        menu.items[0].title = entry.status(at: .now)
        menu.items[0].isEnabled = false
        for item in menu.items {
            guard let values = item.representedObject as? [String], values.count == 2,
                  let option = AgentMenuSettings.Option(rawValue: values[1]) else { continue }
            item.state = agentSettings.value(option, providerID: providerID) ? .on : .off
        }
    }

    @objc private func toggleAgentOption(_ item: NSMenuItem) {
        guard let values = item.representedObject as? [String], values.count == 2,
              let option = AgentMenuSettings.Option(rawValue: values[1]) else { return }
        agentSettings.toggle(option, providerID: values[0])
        onAgentSettingsChange()
        if let menu = item.menu { updateAgentSubmenu(menu, providerID: values[0]) }
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
