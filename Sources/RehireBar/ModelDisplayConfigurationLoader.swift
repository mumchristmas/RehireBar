import AgentStatusCore
import Foundation

/// Display preferences are independent of Agent status documents and never rewrite them.
struct ModelDisplayConfigurationLoader: Sendable {
    static let maximumBytes = 64 * 1024
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/RehireBar/model-display.json")

    static let bundledConfiguration: ModelDisplayConfiguration = {
        if let url = Bundle.main.url(forResource: "ModelDisplay", withExtension: "json") {
            return decode(url) ?? .passthrough
        }
        // SwiftPM development/test executables have no app bundle. Never compile
        // a personal source-path fallback into a release executable.
        guard Bundle.main.bundleURL.pathExtension != "app" else { return .passthrough }
        #if DEBUG
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #else
        let sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        #endif
        return decode(sourceRoot.appending(path: "Resources/ModelDisplay.json")) ?? .passthrough
    }()

    let overrideURL: URL?
    let fallback: ModelDisplayConfiguration

    init(
        overrideURL: URL? = Self.defaultURL,
        fallback: ModelDisplayConfiguration = Self.bundledConfiguration
    ) {
        self.overrideURL = overrideURL
        self.fallback = fallback
    }

    /// Read on a status refresh so local policy edits do not require recompilation.
    func load() -> ModelDisplayConfiguration {
        overrideURL.flatMap(Self.decode) ?? fallback
    }

    private static func decode(_ url: URL) -> ModelDisplayConfiguration? {
        guard let data = BoundedJSONFileReader.read(
            url, in: url.deletingLastPathComponent(), maximumBytes: maximumBytes
        ) else { return nil }
        return try? ModelDisplayConfiguration.decode(data)
    }
}
