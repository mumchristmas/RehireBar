import XCTest
@testable import RehireBar

final class UsageSnapshotTests: XCTestCase {
    func testRemainingIsInverseAndClamped() {
        XCTAssertEqual(RateWindow(label: "5H", usedPercent: 24, windowMinutes: 300, resetsAt: 1).remainingPercent, 76)
        XCTAssertEqual(RateWindow(label: "5H", usedPercent: 120, windowMinutes: 300, resetsAt: 1).remainingPercent, 0)
        XCTAssertEqual(RateWindow(label: "5H", usedPercent: -5, windowMinutes: 300, resetsAt: 1).remainingPercent, 100)
    }

    func testKnownWindowsMapToRequiredLabels() throws {
        let observedAt = Date(timeIntervalSince1970: 1_799_999_000)
        let snapshot = try UsageSnapshot.from(
            primary: .init(usedPercent: 24, windowMinutes: 300, resetsAt: 1_800_000_000),
            secondary: .init(usedPercent: 59, windowMinutes: 10_080, resetsAt: 1_800_086_400),
            observedAt: observedAt
        )
        XCTAssertEqual(snapshot.primary.label, "5H")
        XCTAssertEqual(snapshot.secondary.label, "7D")
        XCTAssertEqual(snapshot.primary.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(snapshot.secondary.resetsAt, Date(timeIntervalSince1970: 1_800_086_400))
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertFalse(snapshot.isStale)
    }

    func testUnsupportedWindowDoesNotHideSupportedSevenDayWindow() throws {
        let snapshot = try UsageSnapshot.from(
            primary: .init(usedPercent: 24, windowMinutes: 60, resetsAt: 1_800_000_000),
            secondary: .init(usedPercent: 59, windowMinutes: 10_080, resetsAt: 1_800_086_400),
            observedAt: Date(timeIntervalSince1970: 1_799_999_000)
        )
        XCTAssertFalse(snapshot.primaryAvailable)
        XCTAssertTrue(snapshot.secondaryAvailable)
        XCTAssertEqual(snapshot.secondary.remainingPercent, 41)
    }

    func testSevenDayOnlyMapsToSecondaryWithoutInventingPrimary() throws {
        let snapshot = try UsageSnapshot.from(
            primary: .init(usedPercent: 0, windowMinutes: 10_080, resetsAt: 1_800_086_400),
            secondary: nil,
            observedAt: Date(timeIntervalSince1970: 1_799_999_000)
        )
        XCTAssertFalse(snapshot.primaryAvailable)
        XCTAssertTrue(snapshot.secondaryAvailable)
        XCTAssertEqual(snapshot.secondary.remainingPercent, 100)
    }

    func testReversedWindowsMapByDuration() throws {
        let snapshot = try UsageSnapshot.from(
            primary: .init(usedPercent: 59, windowMinutes: 10_080, resetsAt: 2),
            secondary: .init(usedPercent: 24, windowMinutes: 300, resetsAt: 1),
            observedAt: .now
        )
        XCTAssertEqual(snapshot.primary.remainingPercent, 76)
        XCTAssertEqual(snapshot.secondary.remainingPercent, 41)
    }

    func testNoSupportedWindowIsRejected() {
        XCTAssertThrowsError(try UsageSnapshot.from(
            primary: .init(usedPercent: 1, windowMinutes: 60, resetsAt: 1),
            secondary: nil,
            observedAt: .now
        )) { XCTAssertEqual($0 as? UsageError, .unsupportedWindows) }
    }
}
