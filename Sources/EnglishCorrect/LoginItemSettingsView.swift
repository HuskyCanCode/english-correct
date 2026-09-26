import SwiftUI

struct LoginItemSettingsView: View {
    @ObservedObject var controller: LoginItemController
    var promptOnly = false

    private var needsAttention: Bool {
        controller.status == .requiresApproval || controller.errorMessage != nil
    }

    var body: some View {
        if !promptOnly || controller.shouldAsk || needsAttention {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "power.circle")
                        .font(.system(size: 23)).foregroundStyle(GlassTheme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(controller.shouldAsk ? "Open English Correct when you log in?" : "Open at login")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Have English Correct ready when you sign in to your Mac. Automatic suggestions still start paused.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !controller.shouldAsk && controller.status != .requiresApproval {
                        Spacer(minLength: 8)
                        Toggle("Open at login", isOn: Binding(
                            get: { controller.isEnabled },
                            set: { controller.setEnabled($0) }
                        ))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(controller.isChanging || controller.status == .unavailable)
                        .accessibilityLabel("Open English Correct at login")
                        .accessibilityIdentifier("open-at-login-toggle")
                    }
                }
                if controller.shouldAsk {
                    HStack(spacing: 10) {
                        Button("Not now") { controller.deferChoice() }
                            .accessibilityIdentifier("login-item-not-now")
                        Button("Enable open at login") { controller.setEnabled(true) }
                            .glassAction(prominent: true)
                            .accessibilityIdentifier("login-item-enable")
                    }.disabled(controller.isChanging)
                    Text("You can change this later in Setup.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text(controller.statusMessage)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if controller.status == .requiresApproval {
                    HStack(spacing: 10) {
                        Button("Open Login Items") { controller.openSystemSettings() }
                            .glassAction(prominent: true)
                        Button("Cancel request") { controller.setEnabled(false) }
                    }.disabled(controller.isChanging)
                }
                if let error = controller.errorMessage {
                    Text(error).font(.system(size: 12)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("login-item-error")
                    if controller.status != .requiresApproval {
                        Button("Open Login Items") { controller.openSystemSettings() }
                            .disabled(controller.isChanging)
                    }
                }
                if controller.isChanging {
                    ProgressView().controlSize(.small).accessibilityLabel("Updating open at login")
                }
            }.padding(18).contentSurface(cornerRadius: 18, tinted: controller.shouldAsk)
        }
    }
}
