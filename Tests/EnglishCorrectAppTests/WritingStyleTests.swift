import XCTest
import EnglishCorrectCore
@testable import EnglishCorrect

@MainActor
final class WritingStyleTests: XCTestCase {
    func testCasualDefaultAndSavedStyleRestoreWithoutEnablingSuggestions() throws {
        let suite = "EnglishCorrect.WritingStyleTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertEqual(fresh.writingStyle, .casual)
        fresh.writingStyle = .formal
        let restored = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertEqual(restored.writingStyle, .formal)
        XCTAssertEqual(restored.configuration.style, .formal)
        XCTAssertFalse(restored.enabled)
        defaults.set("unknown-style", forKey: "writingStyle")
        let invalid = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertEqual(invalid.writingStyle, .casual)
    }

    func testPopupPresentationNamesBuiltInModelAndSelectedStyle() throws {
        let suite = "EnglishCorrect.WritingStyleTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("builtIn", forKey: "provider")
        defaults.set("fast", forKey: "model")
        defaults.set("slang", forKey: "writingStyle")
        let model = AppModel(defaults: defaults, startMonitoring: false)
        let presentation = SuggestionPresentation(model: model)
        XCTAssertEqual(presentation.modelLabel, "Fast · Qwen2.5 1.5B Instruct")
        XCTAssertEqual(presentation.writingStyle, .slang)
        defaults.set("lmStudio", forKey: "provider")
        defaults.set("custom-local-model:2", forKey: "model")
        let custom = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertEqual(custom.activeModelLabel, "custom-local-model:2")
    }
}
