import Darwin
import Foundation

@MainActor
protocol DataChangeMonitoring: AnyObject {
    func start(_ handler: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

/// Converts status stores that already drive the Touch Bar into refresh signals.
/// The adaptive timer remains a safety net, but an appended rollout/log line or a
/// catalog WAL update no longer has to wait for the next polling deadline.
@MainActor
final class CodexDataChangeMonitor: DataChangeMonitoring {
    private let root: URL
    private let catalogDatabaseURL: URL
    private let metadataDatabaseURL: URL
    private let logRoot: URL
    private let agentStatusDirectory: URL
    private let debounceInterval: TimeInterval
    private let minimumEventInterval: TimeInterval
    private var handler: (@MainActor @Sendable () -> Void)?
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var rescanTimer: Timer?
    private var debounceTimer: Timer?
    private var lastEmissionAt = Date.distantPast
    private var pendingRebuild = false

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex"),
        catalogDatabaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/sqlite/codex-dev.db"),
        metadataDatabaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/state_5.sqlite"),
        logRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/com.openai.codex"),
        agentStatusDirectory: URL = AgentStatusDirectoryProvider.defaultDirectory,
        debounceInterval: TimeInterval = 0.15,
        minimumEventInterval: TimeInterval = 0.75
    ) {
        self.root = root
        self.catalogDatabaseURL = catalogDatabaseURL
        self.metadataDatabaseURL = metadataDatabaseURL
        self.logRoot = logRoot
        self.agentStatusDirectory = agentStatusDirectory
        self.debounceInterval = debounceInterval
        self.minimumEventInterval = minimumEventInterval
    }

    func start(_ handler: @escaping @MainActor @Sendable () -> Void) {
        stop()
        self.handler = handler
        rebuildSources()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rebuildSources() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rescanTimer = timer
    }

    func stop() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        pendingRebuild = false
        rescanTimer?.invalidate()
        rescanTimer = nil
        for source in sources.values { source.cancel() }
        sources.removeAll()
        handler = nil
    }

    static func watchedPaths(
        root: URL,
        catalogDatabaseURL: URL,
        metadataDatabaseURL: URL,
        logRoot: URL,
        agentStatusDirectory: URL = AgentStatusDirectoryProvider.defaultDirectory
    ) -> [URL] {
        var paths = [
            catalogDatabaseURL,
            URL(filePath: catalogDatabaseURL.path + "-wal"),
            metadataDatabaseURL,
            URL(filePath: metadataDatabaseURL.path + "-wal"),
            catalogDatabaseURL.deletingLastPathComponent(),
            root.appending(path: "sessions"),
            root.appending(path: "archived_sessions"),
            logRoot,
            agentStatusDirectory.deletingLastPathComponent(),
            agentStatusDirectory,
        ]
        paths.append(contentsOf: SessionLogUsageProvider.candidateFiles(root: root)
            .prefix(12).map(\.file))
        if let logs = try? CodexDesktopLogStatusProvider.recentLogFiles(in: logRoot, limit: 6) {
            paths.append(contentsOf: logs)
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func rebuildSources() {
        let desired = Set(Self.watchedPaths(
            root: root,
            catalogDatabaseURL: catalogDatabaseURL,
            metadataDatabaseURL: metadataDatabaseURL,
            logRoot: logRoot,
            agentStatusDirectory: agentStatusDirectory
        ).map { $0.standardizedFileURL.path })

        for path in sources.keys where !desired.contains(path) {
            sources.removeValue(forKey: path)?.cancel()
        }
        for path in desired where sources[path] == nil {
            let descriptor = Darwin.open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
                queue: .main
            )
            source.setEventHandler { [weak self, weak source] in
                Task { @MainActor in
                    self?.receiveEvent(requiresRebuild: source?.data.intersection([
                        .rename, .delete, .revoke
                    ]).isEmpty == false)
                }
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            sources[path] = source
            source.resume()
        }
    }

    private func receiveEvent(requiresRebuild: Bool) {
        pendingRebuild = pendingRebuild || requiresRebuild
        guard debounceTimer == nil else { return }
        let elapsed = Date().timeIntervalSince(lastEmissionAt)
        let delay = max(debounceInterval, minimumEventInterval - elapsed)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.debounceTimer = nil
                self.lastEmissionAt = .now
                self.handler?()
                if self.pendingRebuild { self.rebuildSources() }
                self.pendingRebuild = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        debounceTimer = timer
    }
}

@MainActor
final class NoopDataChangeMonitor: DataChangeMonitoring {
    func start(_ handler: @escaping @MainActor @Sendable () -> Void) {}
    func stop() {}
}
