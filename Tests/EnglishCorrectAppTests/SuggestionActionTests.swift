import AppKit
import SwiftUI
import XCTest
import EnglishCorrectCore
@testable import EnglishCorrect

final class SuggestionActionTests: XCTestCase {
    // Hidden NSHostingViews do not expose their SwiftUI buttons through public
    // Accessibility APIs on this runtime. This test covers non-key geometry;
    // button enabled states and invocation still require visible UI validation.
    func testActionFooterGeometryFitsInactiveNonKeyPanelForEditableAndCopyOnlyCorrections() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            for canApply in [true, false] {
                let suite = "EnglishCorrect.SuggestionActionTests.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let model = AppModel(defaults: defaults, startMonitoring: false)
                model.externalApp = "Input Test"
                model.externalScope = "Selected text"
                model.externalCanApply = canApply
                model.externalCorrection = Correction(original: "She go home.", corrected: "She goes home.", explanation: "Verb agreement.")
                let panel = SuggestionPanel(model: model, presentsWindows: false)
                defer { panel.hide() }
                panel.show(near: nil)
                let host = try XCTUnwrap(panel.panel.contentView as? NSHostingView<AnyView>)
                // Simulate an inactive parent without ever activating or showing
                // the panel. Suggestion actions use fixed, opaque colors.
                host.rootView = AnyView(host.rootView.environment(\.appearsActive, false))
                host.layoutSubtreeIfNeeded()

                XCTAssertFalse(panel.panel.isVisible)
                XCTAssertFalse(panel.panel.isKeyWindow)
                XCTAssertFalse(panel.panel.isMainWindow)
                XCTAssertFalse(panel.panel.canBecomeKey)
                XCTAssertFalse(panel.panel.canBecomeMain)

                let viewport = try XCTUnwrap(Self.descendants(host).compactMap { $0 as? NSScrollView }.first)
                let bounds = viewport.convert(viewport.bounds, to: host)
                XCTAssertTrue(host.bounds.insetBy(dx: -1, dy: -1).contains(bounds))
                let footerHeight = host.isFlipped ? host.bounds.maxY - bounds.maxY : bounds.minY - host.bounds.minY
                XCTAssertGreaterThan(footerHeight, 60, "The inactive panel must preserve room for its summary and enlarged action row")
                let document = try XCTUnwrap(viewport.documentView)
                XCTAssertTrue(viewport.contentView.bounds.insetBy(dx: -1, dy: -1).contains(document.frame))
                XCTAssertLessThanOrEqual(host.fittingSize.height, host.bounds.height + 1,
                                         "The action footer must fit the actual panel height")
                try Self.snapshot(canApply ? "editable" : "copy-only", host: host)
            }
        }
    }

    @MainActor
    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor
    private static func snapshot(_ state: String, host: NSView) throws {
        guard let directory = ProcessInfo.processInfo.environment["ENGLISH_CORRECT_POPUP_SNAPSHOTS"] else { return }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try data.write(to: destination.appendingPathComponent("popup-actions-\(state)-inactive-parent.png"))
    }
}
