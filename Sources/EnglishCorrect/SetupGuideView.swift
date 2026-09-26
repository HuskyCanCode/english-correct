import SwiftUI
import EnglishCorrectCore

struct SetupGuideView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var loginItem: LoginItemController

    private var readinessTitle: String {
        if model.readyInOtherApps { return "Ready here and in your allowed apps" }
        if model.readyInApp { return "Ready to check writing here" }
        if model.setupAIState.isChecking { return "Checking your setup…" }
        return "Let’s get everything ready"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("A little setup. Better writing.")
                    .font(.system(size: 32, weight: .medium, design: .serif))
                Text("Connect a local model, choose where you want help, and decide when suggestions appear.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if model.setupAIState.isChecking {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking setup")
                } else {
                    Image(systemName: model.readyInApp ? "checkmark.circle.fill" : "list.bullet.clipboard")
                        .font(.title2).foregroundStyle(GlassTheme.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(readinessTitle).font(.system(size: 14, weight: .semibold))
                    Text("Checks use a sample sentence, never text from another app.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(model.setupAIState.isChecking ? "Checking…" : "Check setup") { model.checkSetup() }
                    .glassAction(prominent: true)
                    .disabled(model.setupAIState.isChecking)
                    .accessibilityIdentifier("check-setup")
            }.padding(18).contentSurface(cornerRadius: 18, tinted: true)

            VStack(alignment: .leading, spacing: 0) {
                setupStep("01", title: "Connect your local model", ready: model.setupAIState.isReady, checking: model.setupAIState.isChecking) {
                    if !model.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Selected: \(model.model)").textSelection(.enabled)
                    }
                    Text(model.setupAIState.message)
                    if !model.setupAIState.isReady && !model.setupAIState.isChecking {
                        Text(model.provider == .lmStudio
                             ? "Start LM Studio’s local server, then open Models. Download Fast or Pro and choose Use to select it. Setup will check it automatically."
                             : "Start Ollama on this Mac, then open Models. Download Fast or Pro and choose Use to select it. Setup will check it automatically.")
                    }
                    Button("Manage models") { model.openModels() }.padding(.top, 4)
                }
                Divider().padding(.horizontal, 18)
                setupStep("02", title: "Allow access to other apps", ready: model.trusted) {
                    Text(model.trusted ? "macOS Accessibility access is granted." : "In System Settings → Privacy & Security → Accessibility, turn on English Correct.")
                    if !model.trusted {
                        Button("Open Accessibility settings") { model.requestAccess() }.padding(.top, 4)
                    }
                }
                Divider().padding(.horizontal, 18)
                setupStep("03", title: "Choose the apps you allow", ready: model.allowedCount > 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.allowedCount > 0
                             ? "\(model.allowedCount) app\(model.allowedCount == 1 ? " is" : "s are") allowed. You can change this at any time."
                             : "Turn on at least one app in App access.")
                        Spacer(minLength: 8)
                        Button("Choose apps") { model.section = "App access"; model.refreshApps() }
                    }
                }
                Divider().padding(.horizontal, 18)
                setupStep("04", title: "Check your shortcut", ready: model.shortcutRegistered) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.shortcutRegistered ? "\(model.shortcut.label) is registered. Try it in an allowed text field." : model.shortcutStatus)
                        Spacer(minLength: 8)
                        Picker("Correction shortcut", selection: $model.shortcut) {
                            ForEach(CorrectionShortcut.allCases) { choice in Text(choice.label).tag(choice) }
                        }.labelsHidden().frame(width: 140).accessibilityLabel("Setup correction shortcut")
                    }
                    Text("Select text to check that part, or leave it unselected to check the whole input. Empty fields are skipped.")
                }
            }.contentSurface(cornerRadius: 18)

            LoginItemSettingsView(controller: loginItem)
            suggestionChoice
            Text("Accessibility and app access are optional for writing inside English Correct. Some custom text fields do not support suggestions; use Copy when direct replacement is unavailable.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var suggestionChoice: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Would you like automatic suggestions?")
                .font(.system(size: 18, weight: .semibold))
            Text("When on, English Correct checks the focused field after you pause typing, only in apps you allow. You always review changes before applying them.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.readyInOtherApps {
                Text("Complete the four checks above to use suggestions in other apps.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(GlassTheme.accent)
            }
            HStack(spacing: 10) {
                Button("Use shortcut only") { model.finishSetup(automatic: false) }
                    .disabled(!model.readyInOtherApps)
                    .accessibilityIdentifier("setup-manual")
                Button("Enable automatic suggestions") { model.finishSetup(automatic: true) }
                    .glassAction(prominent: true)
                    .disabled(!model.readyInOtherApps)
                    .accessibilityIdentifier("setup-automatic")
            }
            HStack(alignment: .firstTextBaseline) {
                Button("Use only this app") { model.finishSetup(automatic: false, inAppOnly: true) }
                    .disabled(!model.readyInApp)
                    .accessibilityIdentifier("setup-in-app")
                Spacer()
                Text("Automatic suggestions start paused after a restart.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(20).contentSurface(cornerRadius: 18, tinted: true)
    }

    private func setupStep<Content: View>(_ number: String, title: String, ready: Bool, checking: Bool = false,
                                          @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Group {
                if ready { Image(systemName: "checkmark.circle.fill").font(.system(size: 20)) }
                else { Text(number).font(.system(size: 13, weight: .semibold, design: .monospaced)) }
            }.foregroundStyle(GlassTheme.accent).frame(width: 24, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(ready ? "Ready" : (checking ? "Checking…" : "Needs attention"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ready ? GlassTheme.accent : .secondary)
                }
                content()
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(18)
    }
}
