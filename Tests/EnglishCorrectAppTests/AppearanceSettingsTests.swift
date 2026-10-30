import AppKit
import XCTest
@testable import EnglishCorrect

@MainActor
final class AppearanceSettingsTests: XCTestCase {
    func testFirstLaunchFollowsSystemWithoutWritingAnAppearanceOverride() async throws {
        try withDefaults { defaults in
            var applied: [NSAppearance.Name?] = []
            let controller = AppearanceController(defaults: defaults) { applied.append($0?.name) }

            XCTAssertEqual(controller.selection, .system)
            XCTAssertEqual(applied.count, 1)
            XCTAssertNil(applied[0], "Following System removes only the app override.")
            XCTAssertNil(defaults.object(forKey: AppearanceController.preferenceKey))
        }
    }

    func testSavedChoicesAreAppliedAtStartup() async throws {
        let choices: [(String, NSAppearance.Name?)] = [("system", nil), ("light", .aqua), ("dark", .darkAqua)]
        for (saved, expectedName) in choices {
            try withDefaults { defaults in
                defaults.set(saved, forKey: AppearanceController.preferenceKey)
                var applied: [NSAppearance.Name?] = []
                let controller = AppearanceController(defaults: defaults) { applied.append($0?.name) }

                XCTAssertEqual(controller.selection.rawValue, saved)
                XCTAssertEqual(applied.count, 1)
                XCTAssertEqual(applied[0], expectedName)
                XCTAssertEqual(defaults.string(forKey: AppearanceController.preferenceKey), saved)
            }
        }
    }

    func testChangingAppearancePersistsAndReturningToSystemClearsTheAppOverride() async throws {
        try withDefaults { defaults in
            var applied: [NSAppearance.Name?] = []
            let controller = AppearanceController(defaults: defaults) { applied.append($0?.name) }

            controller.select(.dark)
            XCTAssertEqual(controller.selection, .dark)
            XCTAssertEqual(defaults.string(forKey: AppearanceController.preferenceKey), "dark")
            controller.select(.light)
            XCTAssertEqual(controller.selection, .light)
            XCTAssertEqual(defaults.string(forKey: AppearanceController.preferenceKey), "light")
            controller.select(.system)
            XCTAssertEqual(controller.selection, .system)
            XCTAssertEqual(defaults.string(forKey: AppearanceController.preferenceKey), "system")
            XCTAssertEqual(applied, [nil, .darkAqua, .aqua, nil])

            var restoredName: NSAppearance.Name? = .aqua
            let restored = AppearanceController(defaults: defaults) { restoredName = $0?.name }
            XCTAssertEqual(restored.selection, .system)
            XCTAssertNil(restoredName)
        }
    }

    func testUnknownSavedChoiceFallsBackToSystemAndRepairsOnlyItsOwnPreference() async throws {
        try withDefaults { defaults in
            defaults.set("unsupported-appearance", forKey: AppearanceController.preferenceKey)
            defaults.set(true, forKey: "automaticSuggestionsEnabled")
            var applied: [NSAppearance.Name?] = []
            let controller = AppearanceController(defaults: defaults) { applied.append($0?.name) }

            XCTAssertEqual(controller.selection, .system)
            XCTAssertEqual(applied.count, 1)
            XCTAssertNil(applied[0])
            XCTAssertEqual(defaults.string(forKey: AppearanceController.preferenceKey), "system")
            XCTAssertTrue(defaults.bool(forKey: "automaticSuggestionsEnabled"))
        }
    }

    func testSelectingTheCurrentChoiceDoesNotReapplyAppearance() async throws {
        try withDefaults { defaults in
            var applications = 0
            let controller = AppearanceController(defaults: defaults) { _ in applications += 1 }
            controller.select(.system)
            controller.select(.dark)
            controller.select(.dark)

            XCTAssertEqual(applications, 2)
            XCTAssertEqual(defaults.string(forKey: AppearanceController.preferenceKey), "dark")
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "EnglishCorrect.AppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
