import AppKit
import SwiftUI

enum GlassTheme {
    static let accent = Color(nsColor: NSColor(name: "EnglishCorrectAccent") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.48, green: 0.82, blue: 0.72, alpha: 1)
        }
        return NSColor(srgbRed: 0.13, green: 0.39, blue: 0.34, alpha: 1)
    })

    static let primary = Color.primary
    static let secondary = Color.secondary
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
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, tinted: tinted, interactive: false))
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
            .background(tinted ? GlassTheme.accent.opacity(0.07) : .clear, in: shape)
            .background(
                Color(nsColor: .controlBackgroundColor)
                    .opacity(opaque ? 1 : (colorScheme == .dark ? 0.28 : 0.20)),
                in: shape
            )
            .overlay {
                shape.strokeBorder(
                    Color.primary.opacity(contrast == .increased ? 0.55 : 0.10),
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
    let cornerRadius: CGFloat
    let tinted: Bool
    let interactive: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || opaqueSurfaces {
            content
                .background(tinted ? GlassTheme.accent.opacity(0.10) : .clear, in: shape)
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(border)
        } else if #available(macOS 26, *) {
            content
                .glassEffect(
                    .regular
                        .tint(tinted ? GlassTheme.accent.opacity(0.18) : nil)
                        .interactive(interactive),
                    in: shape
                )
                .overlay {
                    if contrast == .increased { border }
                }
        } else {
            content
                .background(tinted ? GlassTheme.accent.opacity(0.08) : .clear, in: shape)
                .background(.regularMaterial, in: shape)
                .overlay(border)
        }
    }

    private var border: some View {
        shape.strokeBorder(
            Color.primary.opacity(contrast == .increased ? 0.55 : 0.12),
            lineWidth: contrast == .increased ? 1.5 : 1
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GlassActionModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.glassOpaqueSurfaces) private var opaqueSurfaces
    let prominent: Bool

    @ViewBuilder func body(content: Content) -> some View {
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
            content.modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, tinted: true, interactive: true))
        } else {
            content
        }
    }
}

/// Native window vibrancy provides a backdrop; individual controls supply Liquid Glass.
struct GlassWindowBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.glassOpaqueSurfaces) private var opaqueSurfaces

    @ViewBuilder var body: some View {
        Group {
            if reduceTransparency || opaqueSurfaces {
                Color(nsColor: .windowBackgroundColor)
            } else {
                WindowVibrancy()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WindowVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view, context: context)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view, context: context)
    }

    private func configure(_ view: NSVisualEffectView, context: Context) {
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        let dark = context.environment.colorScheme == .dark
        let highContrast = context.environment.colorSchemeContrast == .increased
        let name: NSAppearance.Name = highContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua)
        view.appearance = NSAppearance(named: name)
    }
}
