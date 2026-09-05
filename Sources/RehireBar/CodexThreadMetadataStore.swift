import Foundation
import SQLite3

struct CodexThreadMetadata: Equatable, Sendable {
    let threadID: String
    let title: String
    let rolloutURL: URL
    let model: String?
    let effort: String?
}

protocol ThreadMetadataReading: Sendable {
    func metadata(for threadID: String) throws -> CodexThreadMetadata?
}

struct CodexThreadMetadataStore: ThreadMetadataReading, Sendable {
    private let databaseURL: URL
    private let catalogDatabaseURL: URL?

    init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/state_5.sqlite"),
        catalogDatabaseURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/sqlite/codex-dev.db")
    ) {
        self.databaseURL = databaseURL
        self.catalogDatabaseURL = catalogDatabaseURL
    }

    func metadata(for threadID: String) throws -> CodexThreadMetadata? {
        guard let identifier = UUID(uuidString: threadID) else { return nil }
        let normalized = identifier.uuidString.lowercased()
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { sqlite3_close(database) }

        let sql = "SELECT rollout_path, title, model, reasoning_effort FROM threads WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, normalized, -1, sqliteTransient) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let rolloutPath = text(in: statement, column: 0)
        else { return nil }

        let persistedTitle = text(in: statement, column: 1)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let catalogTitle = try? localCatalogTitle(for: normalized)
        return CodexThreadMetadata(
            threadID: normalized,
            title: catalogTitle ?? persistedTitle,
            rolloutURL: URL(filePath: rolloutPath),
            model: text(in: statement, column: 2),
            effort: text(in: statement, column: 3)
        )
    }

    private func localCatalogTitle(for threadID: String) throws -> String? {
        guard let catalogDatabaseURL else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            catalogDatabaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT display_title
        FROM local_thread_catalog
        WHERE host_id = 'local' AND thread_id = ?
          AND COALESCE(missing_candidate, 0) = 0
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, threadID, -1, sqliteTransient) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let title = text(in: statement, column: 0)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    private func text(in statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: value)
    }

    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
