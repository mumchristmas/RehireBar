import XCTest
@testable import RehireBar

final class CodexTaskOpenerTests: XCTestCase {
    func testDeepLinkUsesTheCanonicalThreadRoute() throws {
        let url = try XCTUnwrap(
            CodexTaskDeepLink.url(threadID: "30000000-0000-4000-8000-000000000001")
        )

        XCTAssertEqual(
            url.absoluteString,
            "codex://threads/30000000-0000-4000-8000-000000000001"
        )
    }

    func testDeepLinkRejectsNonUUIDThreadIdentifiers() {
        XCTAssertNil(CodexTaskDeepLink.url(threadID: "../../settings"))
        XCTAssertNil(CodexTaskDeepLink.url(threadID: "thread-id"))
        XCTAssertNil(CodexTaskDeepLink.url(threadID: ""))
    }
}
