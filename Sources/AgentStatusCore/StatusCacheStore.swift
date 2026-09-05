import Foundation

public final class StatusCacheStore {
    private let snapshotURL: URL

    public init(snapshotURL: URL = StatusCachePaths.defaultURL()) {
        self.snapshotURL = snapshotURL
    }

    public func save(_ snapshot: StatusCacheSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let directory = snapshotURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: snapshotURL, options: .atomic)
    }

    public func load() -> StatusCacheSnapshot {
        if let snapshot = decode(at: snapshotURL) { return snapshot }
        return .unavailable
    }

    private func decode(at url: URL) -> StatusCacheSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StatusCacheSnapshot.self, from: data)
    }
}

public enum StatusCachePaths {
    public static func defaultURL(
        applicationSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> URL {
        let root = applicationSupportDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return root.appending(path: "RehireBar/status-cache.json")
    }

}
