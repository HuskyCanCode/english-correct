import AppKit
import SwiftUI
import EnglishCorrectCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel!
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let globalShortcut = GlobalShortcut()
    let loginItem = LoginItemController()
    private let aboutWindows = AboutWindows()
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        model.panel = SuggestionPanel(model: model)
        model.onShortcutChanged = { [weak self] choice in self?.registerShortcut(choice) }
        model.onOpenSettings = { [weak self] in self?.showWindow() }
        registerShortcut(model.shortcut)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 750), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "English Correct"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(model: model, loginItem: loginItem))
        window.minSize = NSSize(width: 890, height: 700)
        window.center()
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About English Correct", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Credits & Licenses…", action: #selector(showCredits), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Setup Guide…", action: #selector(showSetup), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit English Correct", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApplication.shared.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "English Correct")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open English Correct", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Pause suggestions", action: #selector(pause), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action == #selector(showWindow) || $0.action == #selector(pause) { $0.target = self } }
        statusItem.menu = menu
        showWindow()
        model.checkSetup()
    }
    func registerShortcut(_ shortcut: CorrectionShortcut) {
        model.shortcutRegistered = false
        do {
            try globalShortcut.register(shortcut) { [weak self] in self?.model.triggerShortcut() }
            model.shortcutRegistered = true
            model.shortcutStatus = "Ready in allowed apps, even when automatic suggestions are paused."
        } catch { model.shortcutStatus = error.localizedDescription }
    }
    func applicationDidBecomeActive(_ notification: Notification) { loginItem.refresh() }
    func applicationWillTerminate(_ notification: Notification) { BuiltInModelRuntime.shared.shutdown(); globalShortcut.unregister() }
    @objc func showWindow() { NSApplication.shared.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func showAbout() { aboutWindows.showAbout() }
    @objc func showSetup() { model.openSetup() }
    @objc func showCredits() { aboutWindows.showCredits() }
    @objc func pause() { model.enabled = false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

if CommandLine.arguments.contains("--test-builtin-ai") {
    Task { @MainActor in
        do {
            guard let path = ProcessInfo.processInfo.environment["ENGLISH_CORRECT_TEST_MODEL_DIRECTORY"] else {
                print("FAIL: provide an isolated test model directory"); exit(1)
            }
            let store = BuiltInModelStore(root: URL(fileURLWithPath: path).resolvingSymlinksInPath())
            print("Downloading/verifying Fast using the built-in downloader…")
            try await store.download("fast") { update in
                // Test output contains only public download progress, never user text.
                if update.status.contains("Verifying") { print(update.status) }
            }
            let url = try await store.modelURL(for: "fast")
            let config = try await BuiltInModelRuntime.shared.ensureLoaded(modelID: "fast", modelURL: url)
            let client = LocalAIClient(configuration: config)
            let samples = ["She don't like apples.", "I has two book.", "We went to the park yesterday."]
            for sample in samples {
                let result = try await client.correct(sample)
                print("INPUT: \(sample)\nOUTPUT: \(result.corrected)")
                if sample == samples[0] { guard SetupReadiness.validates(result) else { throw LocalAIError.invalidResponse } }
                if sample == samples[1] { guard result.corrected.contains("have") && result.corrected.contains("books") else { throw LocalAIError.invalidResponse } }
                if sample == samples[2] { guard result.corrected == sample else { throw LocalAIError.invalidResponse } }
            }
            BuiltInModelRuntime.shared.shutdown()
            print("PASS: built-in download, verification, engine startup, and 3 corrections; no external AI app used")
            exit(0)
        } catch { BuiltInModelRuntime.shared.shutdown(); print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    dispatchMain()
} else if CommandLine.arguments.contains("--test-local-ai") {
    let provider: LocalProvider = CommandLine.arguments.contains("--ollama") ? .ollama : .lmStudio
    let baseURL = ProcessInfo.processInfo.environment["ENGLISH_CORRECT_TEST_URL"] ?? (provider == .lmStudio ? "http://127.0.0.1:1234" : "http://127.0.0.1:11434")
    let modelName = ProcessInfo.processInfo.environment["ENGLISH_CORRECT_TEST_MODEL"] ?? "english-correct-local"
    Task {
        do {
            let client = LocalAIClient(configuration: LocalAIConfiguration(provider: provider, baseURL: baseURL, model: modelName))
            let models = try await client.models()
            print("Models available: \(models.count)")
            let samples = ["She don't like apples.", "I has two book.", "We went to the park yesterday."]
            for sample in samples {
                let result = try await client.correct(sample)
                print("INPUT: \(sample)\nOUTPUT: \(result.corrected)\nREASON: \(result.explanation)")
                guard !result.corrected.isEmpty else { fatalError("Empty correction") }
                if sample == samples[0] { guard result.corrected.lowercased().contains("doesn't") || result.corrected.lowercased().contains("does not") else { fatalError("Agreement correction failed") } }
                if sample == samples[1] { guard result.corrected.lowercased().contains("have") && result.corrected.lowercased().contains("books") else { fatalError("Agreement/plural correction failed") } }
                if sample == samples[2] { guard result.corrected == sample else { fatalError("Already correct sentence was altered") } }
            }
            print("PASS: real local-model integration (3 cases)")
            exit(0)
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    dispatchMain()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
