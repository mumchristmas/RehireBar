import AgentStatusCore
import AppKit
import Darwin
import Foundation

struct DoctorFreshness: Encodable, Equatable {
    let state: String
    let ageSeconds: Int?
    let freshForSeconds: Int
    let usableForSeconds: Int

    init(hasValue: Bool, observedAt: Date?, now: Date, freshFor: Int, usableFor: Int) {
        freshForSeconds = freshFor
        usableForSeconds = usableFor
        guard hasValue else { state = "missing"; ageSeconds = nil; return }
        guard let observedAt else { state = "undated"; ageSeconds = nil; return }
        let age = now.timeIntervalSince(observedAt)
        guard age.isFinite, age >= -5, age < Double(Int.max) else {
            state = "invalid-timestamp"; ageSeconds = nil; return
        }
        ageSeconds = Int(max(0, age))
        state = age <= Double(freshFor) ? "fresh"
            : age <= Double(usableFor) ? "stale" : "expired"
    }
}

struct DoctorCacheSummary: Encodable {
    let status: String
    let quota: DoctorFreshness
    let context: DoctorFreshness
    let model: DoctorFreshness
    let runtimeState = "not-stored-in-cache"

    init(snapshot: StatusCacheSnapshot?, filePresent: Bool, now: Date) {
        status = snapshot != nil ? "readable" : filePresent ? "unreadable" : "missing"
        quota = .init(
            hasValue: snapshot?.primaryRemainingPercent != nil || snapshot?.secondaryRemainingPercent != nil,
            observedAt: snapshot?.usageObservedAt, now: now, freshFor: 30, usableFor: 900
        )
        context = .init(
            hasValue: snapshot?.sessionUsedTokens != nil && (snapshot?.sessionContextWindow ?? 0) > 0,
            observedAt: snapshot?.sessionContextObservedAt, now: now,
            freshFor: Int(SessionEvidenceFreshness.runtimeContext),
            usableFor: Int(SessionEvidenceFreshness.runtimeContext)
        )
        model = .init(
            hasValue: snapshot?.model != nil || snapshot?.effort != nil,
            observedAt: snapshot?.sessionModelObservedAt, now: now,
            freshFor: Int(SessionEvidenceFreshness.runtimeModel),
            usableFor: Int(SessionEvidenceFreshness.runtimeModel)
        )
    }
}

struct DoctorReport: Encodable {
    let schemaVersion = 1
    let collectedAt: Date
    let app: Application
    let host: Host
    let desktop: Application?
    let configuredDesktopBundleIdentifier: String
    let cli: CLI
    let sources: Sources
    let navigation: Navigation
    let cache: DoctorCacheSummary
    let taskOrder: String
    let runtimeProbe = "not-run"
    let approvalDelivery = "not-tested-explicit-agent-registration-required"

    struct Application: Encodable {
        let name: String?
        let bundleIdentifier: String?
        let version: String?
        let build: String?

        init(bundle: Bundle) {
            let metadata = ApplicationVersion(info: bundle.infoDictionary ?? [:])
            name = metadata.name
            bundleIdentifier = bundle.bundleIdentifier
            version = metadata.version
            build = metadata.build
        }
    }

    struct Host: Encodable {
        let macOS: String
        let processArchitecture: String
        let processTranslated: Bool?
        let hardwareModel: String?
        let meetsMinimumOS: Bool
        let touchBar: String
    }

    struct CLI: Encodable {
        let status: String
        let version: String?
    }

    struct Sources: Encodable {
        let desktopCatalogPresent: Bool
        let sessionDirectoryPresent: Bool
        let desktopLogDirectoryPresent: Bool
        let ipcSocket: String
        let agentPublisherDirectoryPresent: Bool
    }

    struct Navigation: Encodable {
        let status: String
        let handlerBundleIdentifier: String?
        let matchesConfiguredDesktop: Bool
        let taskOpening = "not-tested"
    }
}

@MainActor
enum DoctorCommand {
    static func collect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = .now
    ) -> DoctorReport {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let workspace = NSWorkspace.shared
        let desktopID = CodexActivityMonitor(environment: environment).bundleIdentifier
        let desktop = workspace.urlForApplication(withBundleIdentifier: desktopID).flatMap(Bundle.init(url:))
        let handler = workspace.urlForApplication(toOpen: URL(string: "codex://")!).flatMap(Bundle.init(url:))
        let executable = try? CodexAppServerClient.resolveExecutable(environment: environment)
        let version = executable.flatMap { CodexVersionProbe.read(executable: $0) }
        let cacheURL = StatusCachePaths.defaultURL()
        let cacheData = BoundedJSONFileReader.read(
            cacheURL, in: cacheURL.deletingLastPathComponent(), maximumBytes: 64 * 1_024
        )
        let cache = cacheData.flatMap { try? JSONDecoder().decode(StatusCacheSnapshot.self, from: $0) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var translated: Int32 = 0
        var translatedSize = MemoryLayout<Int32>.size
        let processTranslated = sysctlbyname("sysctl.proc_translated", &translated, &translatedSize, nil, 0) == 0
            ? translated == 1 : nil
        var modelSize = 0
        let hardwareModel: String?
        if sysctlbyname("hw.model", nil, &modelSize, nil, 0) == 0, modelSize > 0, modelSize < 256 {
            var model = [CChar](repeating: 0, count: modelSize)
            hardwareModel = sysctlbyname("hw.model", &model, &modelSize, nil, 0) == 0
                ? String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        } else {
            hardwareModel = nil
        }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        func directoryPresent(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let socketPresent = CodexDesktopIPCClient.routerSocketPaths().contains { path in
            var info = stat()
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
        }
        return DoctorReport(
            collectedAt: now, app: .init(bundle: .main),
            host: .init(macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                        processArchitecture: architecture, processTranslated: processTranslated,
                        hardwareModel: hardwareModel, meetsMinimumOS: os.majorVersion >= 15,
                        touchBar: SystemTouchBarGeometryReader.hardwareDetected ? "detected" : "not-detected"),
            desktop: desktop.map(DoctorReport.Application.init),
            configuredDesktopBundleIdentifier: desktopID,
            cli: .init(status: executable == nil ? "missing" : version == nil ? "version-unavailable" : "available",
                       version: version),
            sources: .init(
                desktopCatalogPresent: fileManager.fileExists(atPath: home.appending(path: ".codex/sqlite/codex-dev.db").path),
                sessionDirectoryPresent: directoryPresent(home.appending(path: ".codex/sessions")),
                desktopLogDirectoryPresent: directoryPresent(home.appending(path: "Library/Logs/com.openai.codex")),
                ipcSocket: socketPresent ? "present-unprobed" : "missing",
                agentPublisherDirectoryPresent: directoryPresent(AgentStatusDirectoryProvider.defaultDirectory)
            ),
            navigation: .init(status: handler == nil ? "unregistered" : "registered",
                              handlerBundleIdentifier: handler?.bundleIdentifier,
                              matchesConfiguredDesktop: handler?.bundleIdentifier == desktopID),
            cache: .init(snapshot: cache, filePresent: fileManager.fileExists(atPath: cacheURL.path), now: now),
            taskOrder: SessionSortMode(preference: UserDefaults.standard.string(forKey: SessionSortMode.preferenceKey)).rawValue
        )
    }

    static func run(arguments: [String]) -> Int32 {
        guard arguments.isEmpty || arguments == ["--json"] else {
            fputs("usage: RehireBar doctor [--json]\n", stderr)
            return 2
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let output = try encoder.encode(collect())
            FileHandle.standardOutput.write(output)
            FileHandle.standardOutput.write(Data([0x0A]))
            return 0
        } catch {
            fputs("Could not encode doctor report.\n", stderr)
            return 1
        }
    }
}
