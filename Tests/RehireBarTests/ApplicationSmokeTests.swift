import XCTest
@testable import RehireBar

@MainActor
final class ApplicationSmokeTests: XCTestCase {
    func testProductionGraphStartsInactiveWithoutLoginRegistrationAndStopsHidden() {
        let activity = InactiveActivityMonitor()
        let presenter = SmokePresenter()
        let loginItem = LoginItemSpy()
        let applicationMenu = ApplicationMenuSpy()
        let statusCache = StatusCachePublisher(
            store: .init(
                snapshotURL: FileManager.default.temporaryDirectory
                    .appending(path: UUID().uuidString)
            )
        )

        let application = RehireBarApplication.makeProduction(
            loginRegistrationEnabled: false,
            activityMonitor: activity,
            presenter: presenter,
            loginItemManager: loginItem,
            statusCache: statusCache,
            applicationMenu: applicationMenu
        )

        application.start()

        XCTAssertEqual(activity.startCount, 1)
        XCTAssertEqual(loginItem.registrationCount, 0)
        XCTAssertEqual(applicationMenu.startCount, 1)
        XCTAssertEqual(presenter.showCount, 0)

        application.stop()

        XCTAssertEqual(activity.stopCount, 1)
        XCTAssertEqual(presenter.hideCount, 1)
        XCTAssertEqual(applicationMenu.stopCount, 1)
    }
}

@MainActor
private final class InactiveActivityMonitor: ActivityMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) {
        startCount += 1
        handler(false)
    }

    func stop() { stopCount += 1 }
}

@MainActor
private final class SmokePresenter: UsagePresenting {
    private(set) var showCount = 0
    private(set) var hideCount = 0

    func show(_ snapshot: UsageSnapshot) { showCount += 1 }
    func showUnavailable() { showCount += 1 }
    func hide() { hideCount += 1 }
}

@MainActor
private final class LoginItemSpy: LoginItemManaging {
    private(set) var registrationCount = 0

    func register() { registrationCount += 1 }
}

@MainActor
private final class ApplicationMenuSpy: ApplicationMenuManaging {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}
