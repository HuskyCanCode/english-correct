import AppKit
import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// One application override lets the main window, suggestions, and credits
/// follow the same choice. A nil override keeps following macOS automatically.
@MainActor
final class AppearanceController: ObservableObject {
    static let shared = AppearanceController()
    static let preferenceKey = "appearancePreference"

    @Published private(set) var selection: AppearancePreference
    private let defaults: UserDefaults
    private let applyAppearance: @MainActor (NSAppearance?) -> Void

    init(defaults: UserDefaults = .standard,
         applyAppearance: @escaping @MainActor (NSAppearance?) -> Void = { NSApplication.shared.appearance = $0 }) {
        self.defaults = defaults
        self.applyAppearance = applyAppearance
        let stored = defaults.string(forKey: Self.preferenceKey)
        let restored = stored.flatMap(AppearancePreference.init(rawValue:)) ?? .system
        selection = restored
        if let stored, AppearancePreference(rawValue: stored) == nil {
            defaults.set(restored.rawValue, forKey: Self.preferenceKey)
        }
        applyAppearance(restored.appearance)
    }

    func select(_ preference: AppearancePreference) {
        guard selection != preference else { return }
        selection = preference
        defaults.set(preference.rawValue, forKey: Self.preferenceKey)
        applyAppearance(preference.appearance)
    }
}

@MainActor
struct AppearanceSettingsView: View {
    @ObservedObject var controller: AppearanceController = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Appearance")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(GlassTheme.secondary)
            Picker("Appearance", selection: Binding(
                get: { controller.selection },
                set: { controller.select($0) }
            )) {
                ForEach(AppearancePreference.allCases) { preference in
                    Text(preference.label).tag(preference)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("App appearance")
            .accessibilityHint("Choose System to follow your Mac’s appearance.")
            .accessibilityIdentifier("app-appearance-picker")
        }
    }
}
