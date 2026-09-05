import Foundation
import XCTest
@testable import RehireBar

final class TouchBarRecoveryControllerTests: XCTestCase {
    func testFailedPresentationEscalatesWithoutSkippingSteps() {
        var controller = TouchBarRecoveryController()
        let now = Date(timeIntervalSince1970: 1_000)
        controller.observe(.presentationFailed, at: now)
        XCTAssertEqual(controller.evaluate(at: now), .refreshAndRepresent)
        controller.observe(.recoveryFailed(.refreshAndRepresent), at: now)
        XCTAssertEqual(controller.evaluate(at: now), .resetCompositionAndRepresent)
        controller.observe(.recoveryFailed(.resetCompositionAndRepresent), at: now)
        XCTAssertEqual(controller.evaluate(at: now), .relaunchApplication)
    }

    func testSuccessfulPresentationClearsRecovery() {
        var controller = TouchBarRecoveryController()
        controller.observe(.presentationFailed)
        controller.observe(.presentationSucceeded)
        XCTAssertEqual(controller.evaluate(), .none)
    }

    func testRelaunchRequestClearsPendingRecovery() {
        var controller = TouchBarRecoveryController()
        let now = Date(timeIntervalSince1970: 1_000)
        controller.observe(.presentationFailed, at: now)
        controller.observe(.relaunchRequested, at: now)
        XCTAssertEqual(controller.evaluate(at: now.addingTimeInterval(299)), .none)
    }
}
