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
        if !isEnabled { return Color(white: dark ? 0.63 : 0.40) }
        if prominent { return dark ? Color(red: 0.07, green: 0.19, blue: 0.16) : .white }
        return dark ? Color(red: 0.88, green: 0.98, blue: 0.94)
                    : Color(red: 0.08, green: 0.24, blue: 0.20)
    }

    private var background: Color {
        if !isEnabled { return Color(white: dark ? 0.22 : 0.88) }
        if prominent {
            return dark ? Color(red: 0.48, green: 0.82, blue: 0.72)
                        : Color(red: 0.10, green: 0.34, blue: 0.29)
        }
        return dark ? Color(red: 0.10, green: 0.25, blue: 0.21)
                    : Color(red: 0.85, green: 0.94, blue: 0.90)
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
