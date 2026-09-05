import Foundation
import XCTest
@testable import RehireBar

final class ThreadMetadataCacheTests: XCTestCase {
    func testCatalogSourceVersionControlsMetadataInvalidation() async {
        let reader = CountingMetadataReader()
        let cache = ThreadMetadataCache(reader: reader)
        let firstVersion = Date(timeIntervalSince1970: 10)
        let identity = TaskIdentity(hostID: "local", threadID: reader.threadID)

        _ = await cache.metadata(for: identity, sourceVersion: firstVersion)
        _ = await cache.metadata(for: identity, sourceVersion: firstVersion)
        XCTAssertEqual(reader.count, 1)

        _ = await cache.metadata(
            for: identity,
            sourceVersion: firstVersion.addingTimeInterval(1)
        )
        XCTAssertEqual(reader.count, 2)
    }
}

private final class CountingMetadataReader: ThreadMetadataReading, @unchecked Sendable {
    let threadID = "10000000-0000-4000-8000-000000000001"
    private let lock = NSLock()
    private var readCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCount
    }

    func metadata(for threadID: String) throws -> CodexThreadMetadata? {
        lock.lock()
        readCount += 1
        lock.unlock()
        return CodexThreadMetadata(
            threadID: threadID,
            title: "Cached",
            rolloutURL: URL(filePath: "/tmp/cached.jsonl"),
            model: "gpt-5.6-sol",
            effort: "high"
        )
    }
}
