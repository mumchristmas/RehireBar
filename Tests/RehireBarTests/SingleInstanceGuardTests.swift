import XCTest
@testable import RehireBar

@MainActor
final class SingleInstanceGuardTests: XCTestCase {
    func testRejectsSecondOwnerUntilFirstReleasesLock() {
        let identifier = "com.bigbom.RehireBar.tests.\(UUID().uuidString)"
        let first = SingleInstanceGuard(identifier: identifier)
        let second = SingleInstanceGuard(identifier: identifier)

        XCTAssertTrue(first.acquire())
        XCTAssertFalse(second.acquire())

        first.release()
        XCTAssertTrue(second.acquire())
        second.release()
    }
}
