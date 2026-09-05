import XCTest
@testable import RehireBar

@MainActor
final class LoginItemManagerTests: XCTestCase {
    func testAcceptsSystemAndUserApplicationsFoldersOnly() {
        XCTAssertTrue(LoginItemManager.isInstalledApplication(
            URL(fileURLWithPath: "/Applications/RehireBar.app")
        ))
        XCTAssertTrue(LoginItemManager.isInstalledApplication(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/RehireBar.app")
        ))
        XCTAssertFalse(LoginItemManager.isInstalledApplication(
            URL(fileURLWithPath: "/tmp/dist/RehireBar.app")
        ))
        XCTAssertFalse(LoginItemManager.isInstalledApplication(
            URL(fileURLWithPath: "/Applications/RehireBar.build")
        ))
    }
}
