import AppKit
import SwiftUI

enum GlassTheme {
    // Darker/lighter companions keep small text readable while the reference
    // colors supply the glass tint, borders, and changed-word highlights.
    static let accent = adaptive("Accent", light: 0x245D94, dark: 0xADBBDA)
    static let controlAccent = adaptive("ControlAccent", light: 0xDCEAF6, dark: 0x3D52A0)
    static let windowBackground = adaptive("Window", light: 0xF7FAFD, dark: 0x121B35)
    static let sidebar = adaptive("Sidebar", light: 0xEEF4FA, dark: 0x1E294A)
    static let surface = adaptive("Surface", light: 0xFFFFFF, dark: 0x1E294A)
    static let tintedSurface = adaptive("TintedSurface", light: 0xE8F1FA, dark: 0x263460)
    static let glassTint = adaptive("GlassTint", light: 0xB9D9EA, dark: 0x7091E6)
    static let border = adaptive("Border", light: 0xB0C6DC, dark: 0x8697C4)

    static let primary = adaptive("PrimaryText", light: 0x22384A, dark: 0xEDE8F5)
    static let secondary = adaptive("SecondaryText", light: 0x516574, dark: 0xADBBDA)
    static let accentForeground = adaptive("AccentText", light: 0x22384A, dark: 0x121B35)
    static let prominentActionSurface = adaptive("ProminentActionSurface", light: 0xDCEAF6, dark: 0xADBBDA)
    static let actionSurface = adaptive("ActionSurface", light: 0xDCEAF6, dark: 0x1E294A)
    static let disabledActionSurface = adaptive("DisabledActionSurface", light: 0xEEF4FA, dark: 0x263460)
    static let changeHighlight = adaptive("ChangeHighlight", light: 0xDCEAF6, dark: 0x3D52A0)

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: "EnglishCorrect\(name)") { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        })
    }
}

private struct GlassOpaqueSurfacesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Can make a preview or embedded surface more opaque, but can never disable
    /// the user's system Reduce Transparency preference.
    var glassOpaqueSurfaces: Bool {
        get { self[GlassOpaqueSurfacesKey.self] }
        set { self[GlassOpaqueSurfacesKey.self] = newValue }
    }
}

/// Shares the native glass rendering context without adding another glass surface.
struct GlassGroup<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.glassOpaqueSurfaces) private var opaqueSurfaces
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if #available(macOS 26, *), !reduceTransparency, !opaqueSurfaces {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    func contentSurface(cornerRadius: CGFloat = 18, tinted: Bool = false) -> some View {
        modifier(ContentSurfaceModifier(cornerRadius: cornerRadius, tinted: tinted))
    }

    func glassSurface(cornerRadius: CGFloat = 18, tinted: Bool = false) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, tinted: tinted))
    }

    func glassAction(prominent: Bool = false) -> some View {
        modifier(GlassActionModifier(prominent: prominent))
    }

    func glassSelection(_ selected: Bool, cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassSelectionModifier(selected: selected, cornerRadius: cornerRadius))
    }
}

/// Content shares the window's existing vibrancy instead of stacking another
/// luminous glass layer behind long passages, lists, and forms.
private struct ContentSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.glassOpaqueSurfaces) private var opaqueSurfaces
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let tinted: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        let opaque = reduceTransparency || opaqueSurfaces
        content
            .background(
                (tinted ? GlassTheme.tintedSurface : GlassTheme.surface)
                    .opacity(opaque ? 1 : (colorScheme == .dark ? 0.28 : 0.22)),
                in: shape
            )
            .overlay {
                shape.strokeBorder(
                    contrast == .increased ? Color.primary.opacity(0.65) : GlassTheme.border.opacity(0.26),
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct GlassSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.glassOpaqueSurfaces) private var opaqueSurfaces
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let tinted: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || opaqueSurfaces {
            content
                .background(tinted ? GlassTheme.tintedSurface : GlassTheme.surface, in: shape)
                .overlay(border)
        } else {
            // One native backdrop samples the windows underneath the popup.
            // Keep text and actions outside the material so they remain crisp.
            content
                .background(
                    (tinted ? GlassTheme.tintedSurface : GlassTheme.surface)
                        .opacity(colorScheme == .dark ? 0.12 : 0.08),
                    in: shape
                )
                .background {
                    NativeBlurBackground(material: .popover, cornerRadius: cornerRadius)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .overlay(border)
        }
    }

    private var border: some View {
        shape.strokeBorder(
            contrast == .increased ? Color.primary.opacity(0.65) : GlassTheme.border.opacity(0.30),
            lineWidth: contrast == .increased ? 1.5 : 1
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GlassActionModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.glassOpaqueSurfaces) private var opaqueSurfaces
    @Environment(\.colorScheme) private var colorScheme
    let prominent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        // Keep the content's identity when appearance changes. A pale tint needs
        // dark labels; nil preserves the existing native foreground in Dark.
        styled(content.foregroundColor(colorScheme == .light ? GlassTheme.primary : nil))
    }

    @ViewBuilder private func styled<V: View>(_ content: V) -> some View {
        if #available(macOS 26, *), !reduceTransparency, !opaqueSurfaces {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct GlassSelectionModifier: ViewModifier {
    let selected: Bool
    let cornerRadius: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        if selected {
            content.modifier(ContentSurfaceModifier(cornerRadius: cornerRadius, tinted: true))
        } else {
            content
        }
    }
}

/// Native window vibrancy provides a backdrop; individual controls supply Liquid Glass.
struct GlassWindowBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.glassOpaqueSurfaces) private var opaqueSurfaces
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder var body: some View {
        ZStack {
            if reduceTransparency || opaqueSurfaces {
                GlassTheme.windowBackground
            } else {
                NativeBlurBackground(material: .underWindowBackground)
                GlassTheme.windowBackground.opacity(colorScheme == .dark ? 0.18 : 0.14)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
