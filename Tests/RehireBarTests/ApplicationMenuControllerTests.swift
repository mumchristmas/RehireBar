import AppKit
import XCTest
@testable import RehireBar

@MainActor
final class ApplicationMenuControllerTests: XCTestCase {
    func testMenuOffersExplicitShowAndQuitCommands() {
        var showCount = 0
        var quitCount = 0
        let controller = ApplicationMenuController(
            onShow: { showCount += 1 },
            onQuit: { quitCount += 1 }
        )

        let menu = ApplicationMenuController.makeMenu(target: controller)

        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Show Touch Bar", "Quit RehireBar"]
        )
        XCTAssertEqual(menu.items.last?.keyEquivalent, "q")
        XCTAssertTrue(menu.items.allSatisfy { $0.isSeparatorItem || $0.target === controller })
        for item in menu.items where !item.isSeparatorItem {
            NSApplication.shared.sendAction(item.action!, to: item.target, from: item)
        }
        XCTAssertEqual(showCount, 1)
        XCTAssertEqual(quitCount, 1)
    }
}
