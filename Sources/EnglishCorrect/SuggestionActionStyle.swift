import SwiftUI

/// A floating review panel never becomes the key window. Its essential actions
/// must not inherit the inactive tint or vibrancy of native glass buttons.
struct SuggestionActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    var prominent = false

    private var dark: Bool { colorScheme == .dark }

    private var foreground: Color {
        if !isEnabled { return GlassTheme.secondary }
        return prominent ? GlassTheme.accentForeground : GlassTheme.primary
    }

    private var background: Color {
        if !isEnabled { return GlassTheme.disabledActionSurface }
        return prominent ? GlassTheme.prominentActionSurface : GlassTheme.actionSurface
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .frame(minWidth: 64, minHeight: 34)
            .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color(white: dark ? 0.60 : 0.45),
                                  lineWidth: contrast == .increased ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                if configuration.isPressed && isEnabled {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.black.opacity(0.12))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
