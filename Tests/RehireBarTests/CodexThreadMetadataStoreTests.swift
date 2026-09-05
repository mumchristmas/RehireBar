import Foundation
import SQLite3
import XCTest
@testable import RehireBar

final class CodexThreadMetadataStoreTests: XCTestCase {
    func testReadsExactThreadMetadataFromStateDatabase() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, title TEXT NOT NULL, model TEXT, reasoning_effort TEXT);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        let id = "10000000-0000-4000-8000-000000000002"
        let rollout = "/tmp/rollout-\(id).jsonl"
        let insert = "INSERT INTO threads VALUES ('\(id)', '\(rollout)', 'Touch Bar selected thread', 'gpt-5.6-sol', 'high');"
        XCTAssertEqual(sqlite3_exec(database, insert, nil, nil, nil), SQLITE_OK)

        let metadata = try XCTUnwrap(
            try CodexThreadMetadataStore(
                databaseURL: databaseURL,
                catalogDatabaseURL: nil
            ).metadata(for: id)
        )

        XCTAssertEqual(metadata.threadID, id)
        XCTAssertEqual(metadata.title, "Touch Bar selected thread")
        XCTAssertEqual(metadata.rolloutURL.path, rollout)
        XCTAssertEqual(metadata.model, "gpt-5.6-sol")
        XCTAssertEqual(metadata.effort, "high")
    }

    func testCurrentCatalogTitleOverridesStalePersistedTitle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appending(path: "state.sqlite")
        let catalogURL = directory.appending(path: "catalog.sqlite")
        let id = "10000000-0000-4000-8000-000000000002"

        var state: OpaquePointer?
        XCTAssertEqual(sqlite3_open(stateURL.path, &state), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            state,
            "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, "
                + "title TEXT NOT NULL, model TEXT, reasoning_effort TEXT); "
                + "INSERT INTO threads VALUES ('\(id)', '/tmp/rollout.jsonl', "
                + "'Old title', 'gpt-5.6-sol', 'xhigh');",
            nil, nil, nil
        ), SQLITE_OK)
        sqlite3_close(state)

        var catalog: OpaquePointer?
        XCTAssertEqual(sqlite3_open(catalogURL.path, &catalog), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            catalog,
            "CREATE TABLE local_thread_catalog (host_id TEXT, thread_id TEXT, "
                + "display_title TEXT, missing_candidate INTEGER); "
                + "INSERT INTO local_thread_catalog VALUES ('local', '\(id)', "
                + "'Current app title', 0);",
            nil, nil, nil
        ), SQLITE_OK)
        sqlite3_close(catalog)

        let metadata = try XCTUnwrap(try CodexThreadMetadataStore(
            databaseURL: stateURL,
            catalogDatabaseURL: catalogURL
        ).metadata(for: id))

        XCTAssertEqual(metadata.title, "Current app title")
        XCTAssertEqual(metadata.model, "gpt-5.6-sol")
        XCTAssertEqual(metadata.effort, "xhigh")
    }
}
