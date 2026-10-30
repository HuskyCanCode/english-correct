import AppKit
import SwiftUI

/// Native window material with a material-only mask, keeping overlaid text and
/// controls crisp. The caller supplies the opaque accessibility fallback.
@MainActor
struct NativeBlurBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var cornerRadius: CGFloat = 0

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view, context: context)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view, context: context)
    }

    private func configure(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        let dark = colorScheme == .dark
        let increasedContrast = contrast == .increased
        let name: NSAppearance.Name = increasedContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua)
        view.appearance = NSAppearance(named: name)
        let radius = cornerRadius.isFinite ? max(0, cornerRadius) : 0
        view.maskImage = context.coordinator.mask(for: radius)
    }

    final class Coordinator {
        private var cachedRadius: CGFloat?
        private var cachedMask: NSImage?

        func mask(for radius: CGFloat) -> NSImage? {
            guard cachedRadius != radius else { return cachedMask }
            cachedRadius = radius
            guard radius > 0 else {
                cachedMask = nil
                return nil
            }

            // Leave a one-point center that AppKit stretches between fixed
            // rounded corners instead of allocating a full-window image.
            let side = radius * 2 + 1
            let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                return true
            }
            image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            image.resizingMode = .stretch
            cachedMask = image
            return image
        }
    }
}
