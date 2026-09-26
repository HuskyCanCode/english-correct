import AppKit
import SwiftUI

@MainActor
final class SuggestionPanel {
    let panel: NSPanel
    private weak var model: AppModel?
    private let presentsWindows: Bool

    init(model: AppModel, presentsWindows: Bool = true) {
        self.model = model
        self.presentsWindows = presentsWindows
        panel = NonactivatingPanel(contentRect: NSRect(x: 0, y: 0, width: SuggestionMetrics.width, height: 280), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "English Correct suggestion"
        panel.setAccessibilityIdentifier("english-correct-suggestion-panel")
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show(near frame: CGRect?) {
        guard let model, let primaryScreen = NSScreen.screens.first else { return }
        // AX uses a top-left origin based on the primary display; AppKit uses bottom-left.
        let converted = frame.map { NSRect(x: $0.minX, y: primaryScreen.frame.height - $0.maxY, width: $0.width, height: $0.height) }
        let screen = NSScreen.screens.first { screen in converted.map { screen.frame.intersects($0) } ?? false } ?? NSScreen.main ?? primaryScreen
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let width = min(SuggestionMetrics.width, visible.width)
        let view = SuggestionView(
            presentation: SuggestionPresentation(model: model), width: width,
            dismiss: { [weak model] in model?.dismissExternal() },
            copy: { [weak model] in model?.copyExternal() },
            apply: { [weak model] in model?.applyExternal() },
            openSettings: { [weak model] in model?.openExternalSettings() }
        )
        // Measure a fresh, immutable presentation. Measuring the old observed
        // hosting view here could still return the preceding loading layout.
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.layoutSubtreeIfNeeded()
        let preferredHeight = max(160, ceil(hosting.fittingSize.height))
        let height = min(preferredHeight, visible.height)
        if preferredHeight > visible.height {
            // On a very short display the entire card can scroll, keeping every
            // line and action reachable instead of clipping the window's bottom.
            hosting.rootView = AnyView(ScrollView(.vertical) { view }.frame(width: width, height: height))
        }
        hosting.wantsLayer = true
        // Let the native glass draw its rim; clipping the hosting layer would
        // cut off the optical edge. The surface owns its rounded shape.
        hosting.layer?.masksToBounds = false
        panel.contentView = hosting
        panel.setFrame(Self.placement(near: converted, in: visible, size: NSSize(width: width, height: height)), display: true)
        hosting.layoutSubtreeIfNeeded()
        if presentsWindows { panel.orderFrontRegardless() }
    }

    static func placement(near frame: CGRect?, in visible: CGRect, size: CGSize) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        var x = (frame?.maxX ?? visible.maxX) - width
        var y = frame.map { $0.minY - height - 10 } ?? (visible.maxY - height)
        if y < visible.minY { y = frame.map { $0.maxY + 10 } ?? visible.maxY - height }
        x = min(max(x, visible.minX), visible.maxX - width)
        y = min(max(y, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func hide() { panel.orderOut(nil) }
}

private class NonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
