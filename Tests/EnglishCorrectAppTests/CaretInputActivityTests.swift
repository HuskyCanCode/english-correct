import CoreGraphics
import XCTest
@testable import EnglishCorrect

final class CaretInputActivityTests: XCTestCase {
    func testOnlyEventsBeforeAcceptanceAllowCaretRepair() {
        XCTAssertFalse(CaretInputActivity.hasInteraction(
            since: 100, now: 100.25, eventAges: [0.5, 1, 50, 100]
        ))
    }

    func testOneRecentEventStopsCaretRepairEvenAmongStaleEvents() {
        XCTAssertTrue(CaretInputActivity.hasInteraction(
            since: 100, now: 100.25, eventAges: [2, 50, 0.01, 100]
        ))
        XCTAssertTrue(CaretInputActivity.hasInteraction(
            since: 100, now: 100.25, eventAges: [0]
        ))
    }

    func testEventAtAcceptanceBoundaryConservativelyStopsRepair() {
        XCTAssertTrue(CaretInputActivity.hasInteraction(
            since: 100, now: 100.25, eventAges: [0.25]
        ))
        XCTAssertFalse(CaretInputActivity.hasInteraction(
            since: 100, now: 100.25, eventAges: [0.250_001]
        ))
    }

    func testInvalidClockOrEventSamplesConservativelyStopRepair() {
        for (uptime, now) in [(Double.nan, 100), (.infinity, 100), (-1, 100),
                              (100, .nan), (100, .infinity), (101, 100)] {
            XCTAssertTrue(CaretInputActivity.hasInteraction(
                since: uptime, now: now, eventAges: [50]
            ))
        }
        for ages in [[Double.nan], [-Double.infinity], [-0.1], []] {
            XCTAssertTrue(CaretInputActivity.hasInteraction(
                since: 100, now: 100.25, eventAges: ages
            ))
        }
    }

    func testInfinitelyOldEventDoesNotMaskOtherRecentActivity() {
        XCTAssertFalse(CaretInputActivity.hasInteraction(
            since: 100, now: 100.25, eventAges: [.infinity, 1, 50]
        ))
        XCTAssertFalse(CaretInputActivity.hasInteraction(
            since: 100, now: 100.25, eventAges: [.infinity]
        ))
        XCTAssertTrue(CaretInputActivity.hasInteraction(
            since: 100, now: 100.25, eventAges: [.infinity, 0.01]
        ))
        XCTAssertTrue(CaretInputActivity.hasInteraction(
            since: 100, now: 100.25, eventAges: [.infinity, 0]
        ))
    }

    func testNavigationAndRepeatedKeyPressAgesAreObservedWithoutEventCounters() {
        XCTAssertTrue(CaretInputActivity.observedEventTypes.contains(.keyDown))
        // An Arrow-key repeat can be recent even though its key-down counter
        // did not increment. The event age alone must cancel the repair.
        XCTAssertTrue(CaretInputActivity.hasInteraction(
            since: 100, now: 100.25, eventAges: [0.005]
        ))
    }

    func testAcceptanceReleasesAndOrdinaryPointerMovementAreNotObserved() {
        let observed = Set(CaretInputActivity.observedEventTypes.map(\.rawValue))
        let expected: [CGEventType] = [
            .keyDown,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel
        ]
        XCTAssertEqual(observed, Set(expected.map(\.rawValue)))
        let harmlessEvents: [CGEventType] = [.keyUp, .leftMouseUp, .rightMouseUp, .otherMouseUp, .mouseMoved]
        for harmless in harmlessEvents {
            XCTAssertFalse(observed.contains(harmless.rawValue))
        }
    }
}
