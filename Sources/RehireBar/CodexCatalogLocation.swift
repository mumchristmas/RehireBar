import Darwin
import Foundation

/// Desktop can leave its old development catalog behind after migrating.
struct CodexCatalogLocation: Sendable {
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    let candidates: [URL]

    init(root: URL = Self.defaultRoot, override: URL? = nil) {
        let directory = root.appending(path: "sqlite", directoryHint: .isDirectory)
        candidates = override.map { [$0] } ?? [
            directory.appending(path: "codex.db"),
            directory.appending(path: "codex-dev.db"),
        ]
    }

    var existingURL: URL? {
        candidates.first { url in
            var info = stat()
            return Darwin.lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        }
    }
}
