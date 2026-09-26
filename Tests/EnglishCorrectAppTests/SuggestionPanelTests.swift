import AppKit
import SwiftUI
import XCTest
import EnglishCorrectCore
@testable import EnglishCorrect

final class SuggestionPanelTests: XCTestCase {
    @MainActor
    private static func withPanel(_ body: (AppModel, SuggestionPanel) throws -> Void) throws {
        _ = NSApplication.shared
        let suite = "EnglishCorrect.SuggestionPanelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, startMonitoring: false)
        model.externalApp = "Input Test"
        model.externalScope = "Selected text"
        model.externalCanApply = true
        let panel = SuggestionPanel(model: model, presentsWindows: false)
        defer { panel.hide() }
        try body(model, panel)
        XCTAssertFalse(panel.panel.isVisible, "Layout tests must never show a window")
    }

    @MainActor
    private static func scrollView(in panel: SuggestionPanel) throws -> NSScrollView {
        let host = try XCTUnwrap(panel.panel.contentView)
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        // This is the real AppKit scroll viewport and laid-out SwiftUI document,
        // not a second copy of the application's height calculation.
        return try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
    }

    @MainActor
    private static func assertViewportFitsWithFooter(_ viewport: NSScrollView, panel: SuggestionPanel,
                                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let host = try XCTUnwrap(panel.panel.contentView)
        let bounds = viewport.convert(viewport.bounds, to: host)
        XCTAssertTrue(host.bounds.insetBy(dx: -1, dy: -1).contains(bounds), file: file, line: line)
        // Enough rendered space must remain after the text viewport for the
        // summary and action row. Their text/buttons are checked in snapshots.
        let footerHeight = host.isFlipped ? host.bounds.maxY - bounds.maxY : bounds.minY - host.bounds.minY
        XCTAssertGreaterThan(footerHeight, 60, file: file, line: line)
    }

    @MainActor
    private static func snapshot(_ name: String, panel: SuggestionPanel) throws {
        guard let directory = ProcessInfo.processInfo.environment["ENGLISH_CORRECT_POPUP_SNAPSHOTS"] else { return }
        let host = try XCTUnwrap(panel.panel.contentView)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try data.write(to: destination.appendingPathComponent("popup-\(name).png"))
    }

    func testLoadingToShortCorrectionFitsSynchronously() async throws {
        try await MainActor.run {
            try Self.withPanel { model, panel in
                model.externalBusy = true
                model.externalStatus = "Checking selected text…"
                panel.show(near: nil)
                let loadingHeight = panel.panel.frame.height

                // Intentionally no run-loop turn between the published state
                // change and show: this was the clipped loading-to-result path.
                model.externalBusy = false
                model.externalStatus = ""
                model.externalCorrection = Correction(original: "I has this peo", corrected: "I have this photo.", explanation: "")
                panel.show(near: nil)

                let viewport = try Self.scrollView(in: panel)
                let text = try XCTUnwrap(viewport.documentView)
                XCTAssertGreaterThanOrEqual(viewport.contentView.bounds.height, 24)
                XCTAssertTrue(viewport.contentView.bounds.insetBy(dx: -1, dy: -1).contains(text.frame), "A short correction must be completely readable")
                XCTAssertGreaterThan(panel.panel.frame.height, loadingHeight)
                try Self.assertViewportFitsWithFooter(viewport, panel: panel)
                try Self.snapshot("short", panel: panel)
            }
        }
    }

    func testWrappedCorrectionIsFullyVisible() async throws {
        try await MainActor.run {
            try Self.withPanel { model, panel in
                model.externalCorrection = Correction(original: "Yesterday she go office. Then she meet her manager.", corrected: "Yesterday, she went to the office. Then she met her manager to discuss the report.", explanation: "")
                panel.show(near: nil)
                let viewport = try Self.scrollView(in: panel)
                let text = try XCTUnwrap(viewport.documentView)
                XCTAssertGreaterThan(text.frame.height, 24, "Fixture must wrap to more than one line")
                XCTAssertTrue(viewport.contentView.bounds.insetBy(dx: -1, dy: -1).contains(text.frame))
                try Self.assertViewportFitsWithFooter(viewport, panel: panel)
                try Self.snapshot("wrapped", panel: panel)
            }
        }
    }

    func testPopupFitsInDarkModeAndWithReducedTransparency() async throws {
        try await MainActor.run {
            for reduced in [false, true] {
                try Self.withPanel { model, panel in
                    model.externalCorrection = Correction(original: "I has this peo", corrected: "I have this photo.", explanation: "")
                    panel.show(near: nil)
                    let host = try XCTUnwrap(panel.panel.contentView as? NSHostingView<AnyView>)
                    host.appearance = NSAppearance(named: .darkAqua)
                    host.rootView = AnyView(host.rootView
                        .environment(\.colorScheme, .dark)
                        .environment(\.glassOpaqueSurfaces, reduced))
                    host.layoutSubtreeIfNeeded()
                    let viewport = try Self.scrollView(in: panel)
                    let text = try XCTUnwrap(viewport.documentView)
                    XCTAssertTrue(viewport.contentView.bounds.insetBy(dx: -1, dy: -1).contains(text.frame))
                    try Self.assertViewportFitsWithFooter(viewport, panel: panel)
                    try Self.snapshot(reduced ? "dark-reduced-transparency" : "dark-glass", panel: panel)
                }
            }
        }
    }

    func testLongCorrectionHasBoundedViewportAndReachableLastLine() async throws {
        try await MainActor.run {
            try Self.withPanel { model, panel in
                let corrected = Array(repeating: "Yesterday, she went to the office and finished the report before meeting her manager.", count: 25).joined(separator: "\n\n")
                model.externalCorrection = Correction(original: "She go office.", corrected: corrected, explanation: "")
                panel.show(near: nil)
                let viewport = try Self.scrollView(in: panel)
                let text = try XCTUnwrap(viewport.documentView)
                XCTAssertLessThanOrEqual(viewport.contentView.bounds.height, 151)
                XCTAssertGreaterThan(viewport.contentView.bounds.height, 100)
                XCTAssertGreaterThan(text.frame.height, viewport.contentView.bounds.height * 2, "Long contents should scroll rather than be truncated")
                try Self.assertViewportFitsWithFooter(viewport, panel: panel)
                try Self.snapshot("long", panel: panel)
                viewport.contentView.scroll(to: NSPoint(x: 0, y: text.frame.maxY - viewport.contentView.bounds.height))
                viewport.reflectScrolledClipView(viewport.contentView)
                XCTAssertGreaterThan(viewport.contentView.bounds.minY, 0)
                XCTAssertEqual(viewport.contentView.bounds.maxY, text.frame.maxY, accuracy: 1, "The last line must be reachable by scrolling")
            }
        }
    }

    func testMultipleHighlightedChangesRemainFullyVisible() async throws {
        try await MainActor.run {
            try Self.withPanel { model, panel in
                model.externalCorrection = Correction(original: "She go to work and he have a car",
                                                      corrected: "She goes to work and he has a car.", explanation: "")
                panel.show(near: nil)
                let viewport = try Self.scrollView(in: panel)
                let text = try XCTUnwrap(viewport.documentView)
                XCTAssertTrue(viewport.contentView.bounds.insetBy(dx: -1, dy: -1).contains(text.frame))
                try Self.assertViewportFitsWithFooter(viewport, panel: panel)
                try Self.snapshot("multiple-edits", panel: panel)
            }
        }
    }

    func testDeletionOnlySuggestionRemainsFullyVisible() async throws {
        try await MainActor.run {
            try Self.withPanel { model, panel in
                model.externalCorrection = Correction(original: "Please please send the report today.",
                                                      corrected: "Please send the report today.", explanation: "")
                panel.show(near: nil)
                let viewport = try Self.scrollView(in: panel)
                let text = try XCTUnwrap(viewport.documentView)
                XCTAssertTrue(viewport.contentView.bounds.insetBy(dx: -1, dy: -1).contains(text.frame))
                try Self.assertViewportFitsWithFooter(viewport, panel: panel)
                try Self.snapshot("deletion-only", panel: panel)
            }
        }
    }

    func testPlacementStaysWithinSmallScreenAtEveryEdge() async {
        await MainActor.run {
            let screen = CGRect(x: -600, y: 75, width: 320, height: 180)
            for target in [CGRect(x: -590, y: 80, width: 20, height: 20), CGRect(x: -290, y: 235, width: 20, height: 20), CGRect(x: -900, y: -100, width: 20, height: 20)] {
                let result = SuggestionPanel.placement(near: target, in: screen, size: CGSize(width: 380, height: 440))
                XCTAssertTrue(screen.contains(result))
                XCTAssertEqual(result.size, screen.size)
            }
        }
    }
}
