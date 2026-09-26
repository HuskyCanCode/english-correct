import AppKit
import SwiftUI
import EnglishCorrectCore

@MainActor
final class AboutWindows {
    private var aboutWindow: NSWindow?
    private var creditsWindow: NSWindow?

    func showAbout() {
        if aboutWindow == nil {
            let window = makeWindow(title: "About English Correct", size: NSSize(width: 440, height: 300))
            window.contentView = NSHostingView(rootView: AboutView(showCredits: { [weak self] in self?.showCredits() }))
            aboutWindow = window
        }
        present(aboutWindow)
    }

    func showCredits() {
        if creditsWindow == nil {
            let window = makeWindow(title: "Credits & Licenses", size: NSSize(width: 680, height: 660), resizable: true)
            window.minSize = NSSize(width: 580, height: 480)
            window.contentView = NSHostingView(rootView: CreditsView(close: { [weak self] in self?.creditsWindow?.close() }))
            creditsWindow = window
        }
        present(creditsWindow)
    }

    private func makeWindow(title: String, size: NSSize, resizable: Bool = false) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AboutView: View {
    let showCredits: () -> Void

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Development"
        let build = info["CFBundleVersion"] as? String
        return build.map { "Version \(version) (\($0))" } ?? version
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 40)).foregroundStyle(GlassTheme.accent)
                .accessibilityHidden(true)
            Text("English Correct").font(.system(size: 28, weight: .medium, design: .serif))
            Text(version).font(.callout).foregroundStyle(.secondary)
            Text("A little help. Still your voice.\nWriting suggestions powered by models on your Mac.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Credits & Licenses", action: showCredits)
                .glassAction(prominent: true).controlSize(.large)
                .accessibilityIdentifier("about-credits")
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { GlassWindowBackground().ignoresSafeArea() }
        .tint(GlassTheme.accent)
    }
}

private struct ModelCredit: Identifiable {
    let model: RecommendedModel
    var id: String { model.id }
    var licenseFilename: String {
        model.id == "fast" ? "Qwen2.5-1.5B-Instruct-LICENSE" : "Qwen2.5-7B-Instruct-LICENSE"
    }
}

private enum CreditResources {
    static func licenseText(named name: String) -> String? {
        // Distributable apps carry ordinary offline resources. SwiftPM keeps
        // its own resource bundle for `swift run` and development builds.
        let installed = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Credits")
        if let installed { return try? String(contentsOf: installed, encoding: .utf8) }
        guard Bundle.main.bundleURL.pathExtension != "app",
              let development = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Credits") else { return nil }
        return try? String(contentsOf: development, encoding: .utf8)
    }
}

private struct CreditsView: View {
    let close: () -> Void
    @State private var selectedLicense: ModelCredit?
    private let credits = ModelCatalog.recommendations.map { ModelCredit(model: $0) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Credits & Licenses").font(.system(size: 24, weight: .medium, design: .serif))
                Spacer()
                Button("Done", action: close).glassAction(prominent: true).keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("With thanks to the people behind the models.")
                        .font(.headline)
                    Text("English Correct recommends the following open-weight models. Their creators retain their rights and receive the credit below.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(credits) { credit in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(credit.model.name).font(.headline)
                                Spacer()
                                Text(credit.model.tier).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Qwen team · Alibaba Cloud")
                                .font(.callout).foregroundStyle(GlassTheme.accent)
                            Text("Copyright 2024 Alibaba Cloud\nApache License 2.0 · Q4_K_M quantization")
                                .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                            HStack(spacing: 16) {
                                Button("Read license") { selectedLicense = credit }.glassAction()
                                    .accessibilityLabel("Read license for \(credit.model.name)")
                                Link("Model source ↗", destination: credit.model.sourceURL).buttonStyle(.plain)
                                    .accessibilityLabel("Model source for \(credit.model.name)")
                                Link("License online ↗", destination: credit.model.licenseURL).buttonStyle(.plain)
                                    .accessibilityLabel("Online license for \(credit.model.name)")
                            }.font(.callout)
                        }.padding(20).contentSurface(cornerRadius: 18)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Built-in engine · llama.cpp").font(.headline)
                        Text("MIT License · upstream build b11146").font(.caption).foregroundStyle(.secondary)
                        Link("Engine source ↗", destination: URL(string: "https://github.com/ggml-org/llama.cpp/tree/b11146")!)
                        DisclosureGroup("Read engine and third-party licenses") {
                            Text(["llama.cpp-LICENSE", "llama.cpp-THIRD-PARTY"].compactMap { CreditResources.licenseText(named: $0) }.joined(separator: "\n\n"))
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(20).contentSurface(cornerRadius: 18)
                    Text("License copies are included in the app and can be read offline. Model files are downloaded separately inside English Correct; older configurations may use LM Studio or Ollama. Other models you choose have their own licenses.")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                    Text("English Correct is independently developed and is not affiliated with or endorsed by the model creators.")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background { GlassWindowBackground().ignoresSafeArea() }
        .foregroundStyle(.primary).tint(GlassTheme.accent)
        .sheet(item: $selectedLicense) { credit in
            LicenseTextView(credit: credit, close: { selectedLicense = nil })
        }
    }
}

private struct LicenseTextView: View {
    let credit: ModelCredit
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Apache License 2.0").font(.headline)
                    Text(credit.model.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: close).glassAction(prominent: true).keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            ScrollView {
                if let text = CreditResources.licenseText(named: credit.licenseFilename) {
                    Text(text).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(22)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The license copy is missing from this build.")
                        Link("Read the original license", destination: credit.model.licenseURL)
                    }.padding(22)
                }
            }
        }
        .frame(width: 580, height: 510)
        .background { GlassWindowBackground().ignoresSafeArea() }
        .foregroundStyle(.primary).tint(GlassTheme.accent)
    }
}
