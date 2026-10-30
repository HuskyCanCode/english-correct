import XCTest
@testable import EnglishCorrect

@MainActor
final class AutomaticSuggestionTimingTests: XCTestCase {
    func testDefaultAndSavedTimingRestoreWithoutEnablingSuggestions() throws {
        let name = "EnglishCorrect.TimingTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertEqual(first.automaticSuggestionDelay, 1.2)
        first.automaticSuggestionDelay = 4.6
        XCTAssertEqual(defaults.double(forKey: "automaticSuggestionDelay"), 4.6)
        let second = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertEqual(second.automaticSuggestionDelay, 4.6)
        XCTAssertFalse(second.enabled)
        XCTAssertEqual(second.setupAIState, .unchecked)
    }

    func testInvalidValuesStayWithinSafeTimingRange() throws {
        let name = "EnglishCorrect.TimingTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let app = AppModel(defaults: defaults, startMonitoring: false)
        for (input, expected) in [(Double.nan, 1.2), (.infinity, 1.2), (-4, 0.3), (999, 10), (2.34, 2.3)] {
            app.automaticSuggestionDelay = input
            XCTAssertEqual(app.automaticSuggestionDelay, expected)
            XCTAssertFalse(app.enabled)
        }
        defaults.set(-999, forKey: "automaticSuggestionDelay")
        let restored = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertEqual(restored.automaticSuggestionDelay, 0.3)
    }
}
