import AppKit
import SwiftUI
import EnglishCorrectCore

/// The runtime is a separate installation; a model cannot be downloaded until
/// its management API answers, even when no models have been installed yet.
struct LocalModelSetupView: View {
    @ObservedObject var library: ModelLibrary
    @State private var applicationURL: URL?
    @State private var launchError: String?

    private var provider: LocalProvider { library.configuration.provider }
    private var providerName: String { provider.displayName }
    private var downloadURL: URL {
        URL(string: provider == .lmStudio ? "https://lmstudio.ai/download" : "https://ollama.com/download")!
    }
    private var port: Int { URLComponents(string: library.configuration.baseURL)?.port ?? 80 }

    var body: some View {
        Group {
            if provider == .builtIn {
                VStack(alignment: .leading, spacing: 10) {
                    Label("AI is built in", systemImage: "desktopcomputer")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(GlassTheme.accent)
                    Text("Download Fast or Pro, then choose Use. English Correct starts the model for you—no extra app or server setup.")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Text("Only model downloads need internet. Your writing is checked on this Mac.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if !library.serverReady && !library.checking {
                        Text(library.status).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Button("Check again") { library.refresh() }.disabled(library.isBusy)
                    }
                }.padding(18).contentSurface(cornerRadius: 18, tinted: true)
                    .task { library.refresh() }
            } else { externalSetup }
        }
    }

    private var externalSetup: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: library.serverReady ? "checkmark.circle.fill" : "desktopcomputer")
                    .font(.system(size: 23)).foregroundStyle(GlassTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(library.serverReady ? "\(providerName) is connected" : "First, set up \(providerName)")
                        .font(.system(size: 15, weight: .semibold))
                    Text(library.serverReady
                         ? "Ready to download and use models. Keep \(providerName)’s local server running while you write."
                         : "English Correct needs \(providerName) to download and run models on your Mac. It is a separate, free download.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !library.serverReady {
                VStack(alignment: .leading, spacing: 7) {
                    Text(provider == .lmStudio ? "1. Install LM Studio 0.4 or later and open it." : "1. Install Ollama and open it.")
                    Text(provider == .lmStudio
                         ? "2. In LM Studio’s Developer tab, turn on Start server (port \(port))."
                         : "2. Keep Ollama running on this Mac (port \(port)).")
                    Text("3. Choose Check connection below. Then download Fast or Pro in Models.")
                }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if provider == .lmStudio {
                    Text("If Developer is hidden, enable Developer mode in LM Studio’s settings. Opening LM Studio alone does not start its server.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                if let applicationURL {
                    Button("Open \(providerName)") { openApplication(applicationURL) }
                        .accessibilityIdentifier("open-local-runtime")
                }
                if !library.serverReady {
                    Link(applicationURL == nil ? "Download \(providerName)" : "Update \(providerName)", destination: downloadURL)
                        .glassAction(prominent: applicationURL == nil)
                        .accessibilityIdentifier("download-local-runtime")
                }
                Spacer(minLength: 0)
                if library.checking { ProgressView().controlSize(.small).accessibilityLabel("Checking local server") }
                Button(library.checking ? "Checking…" : "Check connection") { refresh() }
                    .glassAction(prominent: applicationURL != nil || library.serverReady)
                    .disabled(library.checking || library.isBusy)
                    .accessibilityIdentifier("check-local-runtime")
            }
            if let issue = library.serverIssue, !library.checking {
                Text(issue == .connectionFailed
                     ? "\(providerName)’s local server is not available. Complete the steps above, then check again."
                     : issue.localizedDescription)
                    .font(.system(size: 12)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("local-runtime-issue")
            }
            if let launchError {
                Text(launchError).font(.system(size: 12)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !library.serverReady && provider == .lmStudio {
                Link("LM Studio setup instructions ↗", destination: URL(string: "https://lmstudio.ai/docs/developer/core/server")!)
                    .font(.system(size: 11))
            }
        }.padding(18).contentSurface(cornerRadius: 18, tinted: true)
            .task(id: library.configuration.provider.rawValue + library.configuration.baseURL) { refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if !library.checking && !library.isBusy { refresh() }
            }
    }

    private func refresh() {
        let bundleID = provider == .lmStudio ? "ai.elementlabs.lmstudio" : "com.electron.ollama"
        applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        if applicationURL == nil {
            let candidates = [URL(fileURLWithPath: "/Applications"),
                              FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            applicationURL = candidates.map { $0.appendingPathComponent("\(providerName).app") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        library.refresh()
    }

    private func openApplication(_ url: URL) {
        launchError = nil
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            Task { @MainActor in
                if error != nil { launchError = "Could not open \(providerName). Open it from Applications, or install it again using the download link." }
            }
        }
    }
}
