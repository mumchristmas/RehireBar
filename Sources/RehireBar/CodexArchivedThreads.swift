import Foundation
import SQLite3

/// Archive evidence belongs to the local provider scope, never to remote UUIDs.
enum CodexArchivedThreads {
    static func read(root: URL) throws -> Set<String> {
        let archive = root.appending(path: "archived_sessions")
        var identifiers = Set(
            ((try? FileManager.default.contentsOfDirectory(
                at: archive, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.pathExtension == "jsonl" }
                .compactMap { CurrentSessionProvider.threadID(inRolloutFilename: $0) }
        )
        let url = root.appending(path: "state_5.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { return identifiers }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id FROM threads WHERE archived = 1", -1,
                                &statement, nil) == SQLITE_OK, let statement else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                identifiers.insert(String(cString: value).lowercased())
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
        return identifiers
    }
}
