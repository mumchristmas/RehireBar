import Foundation
import XCTest
@testable import RehireBar

final class ConversationApprovalStoreTests: XCTestCase {
    func testQueueIsOldestFirstIdempotentAndDropsExpiredRecords() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = ConversationApprovalStore(url: url)
        let thread = "10000000-0000-4000-8000-000000000002"
        let first = try ConversationApproval(id: "a", threadID: thread, question: "A", createdAt: .init(timeIntervalSince1970: 1), expiresAt: .init(timeIntervalSince1970: 100))
        let second = try ConversationApproval(id: "b", threadID: thread, question: "B", createdAt: .init(timeIntervalSince1970: 2), expiresAt: .init(timeIntervalSince1970: 100))
        try store.enqueue(second); try store.enqueue(first); try store.enqueue(first)
        XCTAssertEqual(try store.pending(at: .init(timeIntervalSince1970: 50)).map(\.id), ["a", "b"])
        XCTAssertTrue(try store.pending(at: .init(timeIntervalSince1970: 101)).isEmpty)
    }

    func testDeliveredApprovalDoesNotReappearAfterReload() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let thread = "10000000-0000-4000-8000-000000000002"
        let store = ConversationApprovalStore(url: url)
        let item = try ConversationApproval(threadID: thread, question: "อนุมัติไหม")
        try store.enqueue(item); try store.markDelivered(id: item.id)
        XCTAssertTrue(try ConversationApprovalStore(url: url).pending().isEmpty)
    }
}
