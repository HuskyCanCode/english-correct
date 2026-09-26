import AppKit
import SwiftUI
import EnglishCorrectCore

struct AppPermission: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var allowed: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published var section = "Write"
    @Published var setupAIState: SetupAIState = .unchecked
    @Published var setupCompleted = false
    @Published var shortcutRegistered = false {
        didSet {
            if oldValue && !shortcutRegistered { pauseExternalSuggestions() }
        }
    }
    @Published var enabled = false {
        didSet {
            guard enabled != oldValue, !isRestoringSettings else { return }
            if enabled {
                trusted = monitor.accessibilityTrusted
                guard readyInOtherApps else {
                    enabled = false
                    updateConsent()
                    return
                }
            }
            updateConsent()
        }
    }
    @Published var trusted = false {
        didSet {
            if oldValue && !trusted && !isRestoringSettings { pauseExternalSuggestions() }
        }
    }
    @Published var monitoringStatus = "Suggestions are paused"
    @Published var permissions: [AppPermission] = []
    @Published var runningApps: [AppPermission] = []
    @Published var provider: LocalProvider = .lmStudio { didSet { if provider != oldValue && !isRestoringSettings { switchProvider() } } }
    @Published var baseURL = "http://127.0.0.1:1234" { didSet { if baseURL != oldValue { saveConfiguration() } } }
    @Published var model = "" { didSet { if model != oldValue { defaultsModelChanged() } } }
    @Published var models: [String] = []
    @Published var connectionStatus = "Connect to a model on this Mac"
    @Published var checkingConnection = false
    @Published var draft = "She don't have enough time to finish the report yesterday." { didSet { if !draft.utf8.elementsEqual(oldValue.utf8) { draftChanged() } } }
    @Published var draftCorrection: Correction?
    @Published var draftBusy = false
    @Published var draftStatus = ""
    @Published var externalCorrection: Correction?
    @Published var externalApp = ""
    @Published var externalStatus = ""
    @Published var externalBusy = false
    @Published var externalScope = ""
    @Published var externalCanApply = false
    @Published var externalNeedsSetup = false
    @Published var shortcut: CorrectionShortcut = .optionCommandE {
        didSet {
            guard shortcut != oldValue, !isRestoringSettings else { return }
            defaults.set(shortcut.rawValue, forKey: "correctionShortcut")
            onShortcutChanged?(shortcut)
        }
    }
    @Published var shortcutStatus = "Starting keyboard shortcut…"
    var onShortcutChanged: ((CorrectionShortcut) -> Void)?
    var onOpenSettings: (() -> Void)?
    let monitor: AccessibilityMonitor
    let library: ModelLibrary
    var panel: SuggestionPanel?
    private var externalTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var scheduledSetupTask: Task<Void, Never>?
    private var permissionTimer: Timer?
    private var manualTimer: Timer?
    private var manualRequestActive = false
    private enum ExternalSettingsDestination { case appAccess, models, setup }
    private var externalSettingsDestination: ExternalSettingsDestination = .appAccess
    private let correctText: (String, LocalAIConfiguration) async throws -> Correction
    private let listModels: (LocalAIConfiguration) async throws -> [String]
    private var gate = SuggestionGate()
    private var snapshot: FieldSnapshot?
    private var fieldID = ""
    private var draftEpoch = UUID()
    private var connectionEpoch = UUID()
    private var setupEpoch = UUID()
    private var isRestoringSettings = true
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, monitor: AccessibilityMonitor? = nil, modelLibrary: ModelLibrary? = nil,
         startMonitoring: Bool = true,
         listModels: @escaping (LocalAIConfiguration) async throws -> [String] = { config in
             try await LocalAIClient(configuration: config).models()
         },
         correctText: @escaping (String, LocalAIConfiguration) async throws -> Correction = { text, config in
             try await LocalAIClient(configuration: config).correct(text)
         }) {
        self.defaults = defaults
        // Older versions already saved these preferences before onboarding existed.
        // Opening the guide once is separate from completing its readiness checks.
        let hasUsedApp = defaults.bool(forKey: "hasLaunchedBefore") || [
            "appPermissions", "provider", "baseURL", "model", "correctionShortcut", "setupGuideCompleted"
        ].contains { defaults.object(forKey: $0) != nil }
        self.monitor = monitor ?? AccessibilityMonitor()
        self.correctText = correctText
        self.listModels = listModels
        library = modelLibrary ?? ModelLibrary(defaults: defaults)
        if let data = defaults.data(forKey: "appPermissions"), let saved = try? JSONDecoder().decode([AppPermission].self, from: data) { permissions = saved }
        if let raw = defaults.string(forKey: "provider"), let saved = LocalProvider(rawValue: raw) { provider = saved }
        baseURL = defaults.string(forKey: "baseURL") ?? "http://127.0.0.1:1234"
        model = defaults.string(forKey: "model") ?? ""
        if let saved = defaults.string(forKey: "correctionShortcut"), let choice = CorrectionShortcut(rawValue: saved) { shortcut = choice }
        setupCompleted = defaults.bool(forKey: "setupGuideCompleted")
        section = hasUsedApp ? "Write" : "Setup"
        defaults.set(true, forKey: "hasLaunchedBefore")
        isRestoringSettings = false
        library.configure(configuration)
        self.monitor.onCapture = { [weak self] value in
            guard let self, !self.manualRequestActive else { return }
            self.received(value)
        }
        self.monitor.onStatus = { [weak self] in self?.monitoringStatus = $0 }
        refreshApps()
        updateConsent()
        if startMonitoring {
            self.monitor.start()
            let permissionTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let current = self.monitor.accessibilityTrusted
                    if current != self.trusted { self.trusted = current; self.updateConsent() }
                }
            }
            self.permissionTimer = permissionTimer
            RunLoop.main.add(permissionTimer, forMode: .common)
            let manualTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.validateManualTarget() }
            }
            self.manualTimer = manualTimer
            RunLoop.main.add(manualTimer, forMode: .common)
        }
        trusted = self.monitor.accessibilityTrusted
    }

    deinit {
        permissionTimer?.invalidate()
        manualTimer?.invalidate()
        externalTask?.cancel()
        draftTask?.cancel()
        connectionTask?.cancel()
        setupTask?.cancel()
        scheduledSetupTask?.cancel()
    }

    var configuration: LocalAIConfiguration { LocalAIConfiguration(provider: provider, baseURL: baseURL, model: model) }
    var allowedIDs: Set<String> { Set(permissions.filter(\.allowed).map(\.id)) }
    var allowedCount: Int { allowedIDs.count }
    var readyInApp: Bool { setupAIState.isReady && library.deletingID == nil }
    var readyInOtherApps: Bool { readyInApp && trusted && allowedCount > 0 && shortcutRegistered }

    func checkSetup() {
        invalidateSetupReadiness()
        trusted = monitor.accessibilityTrusted
        refreshApps()
        guard library.deletingID == nil else {
            setupAIState = .failed("Wait for model deletion to finish, then check setup again.")
            return
        }
        let config = configuration
        guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setupAIState = .failed("Choose a local model in Models, then run the setup check.")
            return
        }
        connectionEpoch = UUID()
        connectionTask?.cancel()
        checkingConnection = false
        let epoch = UUID()
        setupEpoch = epoch
        setupAIState = .checking
        setupTask = Task {
            do {
                guard setupCheckIsCurrent(epoch, configuration: config) else { return }
                let found = try await listModels(config)
                guard setupCheckIsCurrent(epoch, configuration: config) else { return }
                models = found
                guard SetupReadiness.containsSelectedModel(config, in: found) else {
                    setupAIState = .failed("The selected model is not available on your local server. Choose a downloaded model and check again.")
                    return
                }
                let correction = try await correctText(SetupReadiness.sample, config)
                guard setupCheckIsCurrent(epoch, configuration: config) else { return }
                guard SetupReadiness.validates(correction) else {
                    setupAIState = .failed("The model did not correct the sample sentence reliably. Choose another local model and check again.")
                    return
                }
                setupAIState = .ready
            } catch {
                guard setupCheckIsCurrent(epoch, configuration: config) else { return }
                setupAIState = .failed(error.localizedDescription)
            }
        }
    }

    private func setupCheckIsCurrent(_ epoch: UUID, configuration config: LocalAIConfiguration) -> Bool {
        !Task.isCancelled && setupEpoch == epoch && configuration == config && library.deletingID == nil
    }

    private func scheduleSetupVerification() {
        scheduledSetupTask?.cancel()
        scheduledSetupTask = nil
        guard !isRestoringSettings,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              library.deletingID == nil,
              !setupAIState.isChecking, !setupAIState.isReady else { return }
        let config = configuration
        scheduledSetupTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 550_000_000) }
            catch { return }
            guard let self, !Task.isCancelled, self.configuration == config,
                  self.library.deletingID == nil, !self.checkingConnection,
                  !self.setupAIState.isChecking, !self.setupAIState.isReady else { return }
            // checkSetup invalidates all previous verification work. Detach this
            // completed delay first so it cannot cancel the check it is starting.
            self.scheduledSetupTask = nil
            self.checkSetup()
        }
    }

    private func invalidateSetupReadiness() {
        setupEpoch = UUID()
        scheduledSetupTask?.cancel()
        scheduledSetupTask = nil
        setupTask?.cancel()
        setupTask = nil
        setupAIState = .unchecked
        if enabled { enabled = false }
        invalidateExternal()
        draftChanged()
    }

    private func pauseExternalSuggestions() {
        if enabled { enabled = false }
        invalidateExternal()
    }

    @discardableResult
    private func noteServiceFailure(_ error: Error) -> Bool {
        guard let localError = error as? LocalAIError else { return false }
        switch localError {
        case .invalidAddress, .missingModel, .cloudModel, .modelUnavailable,
             .redirectBlocked, .connectionFailed, .timedOut, .serverError:
            invalidateSetupReadiness()
            setupAIState = .failed(error.localizedDescription)
            return true
        case .emptyInput, .inputTooLong, .invalidResponse, .responseTooLong, .incompleteResponse:
            return false
        }
    }

    func finishSetup(automatic: Bool, inAppOnly: Bool = false) {
        trusted = monitor.accessibilityTrusted
        let requiresOtherApps = automatic || !inAppOnly
        guard requiresOtherApps ? readyInOtherApps : readyInApp else { openSetup(); return }
        setAutomaticSuggestions(automatic)
        guard !automatic || enabled else { return }
        setupCompleted = true
        defaults.set(true, forKey: "setupGuideCompleted")
        section = "Write"
    }

    func openSetup() {
        if enabled { enabled = false }
        invalidateExternal()
        section = "Setup"
        onOpenSettings?()
    }

    func setAutomaticSuggestions(_ automatic: Bool) {
        if automatic {
            trusted = monitor.accessibilityTrusted
            guard readyInOtherApps else {
                enabled = false
                return
            }
        }
        enabled = automatic
    }

    func refreshApps() {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        runningApps = apps.compactMap { app in
            guard let id = app.bundleIdentifier else { return nil }
            return AppPermission(id: id, name: app.localizedName ?? id, allowed: allowedIDs.contains(id))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Include previously configured applications even when they are closed.
        for saved in permissions where !runningApps.contains(where: { $0.id == saved.id }) { runningApps.append(saved) }
    }

    func setPermission(_ app: AppPermission, allowed: Bool) {
        let revoked = allowedIDs.contains(app.id) && !allowed
        if let index = permissions.firstIndex(where: { $0.id == app.id }) { permissions[index].allowed = allowed }
        else { permissions.append(AppPermission(id: app.id, name: app.name, allowed: allowed)) }
        defaults.set(try? JSONEncoder().encode(permissions), forKey: "appPermissions")
        if revoked { pauseExternalSuggestions() }
        updateConsent()
        refreshApps()
    }

    func updateConsent() {
        trusted = monitor.accessibilityTrusted
        if enabled && !readyInOtherApps { enabled = false; return }
        invalidateExternal()
        monitor.allowedBundleIDs = allowedIDs
        monitor.isEnabled = enabled
        trusted = monitor.accessibilityTrusted
        received(monitor.captureCurrent())
    }

    func requestAccess() { AccessibilityMonitor.requestAccess() }

    func saveConfiguration(verifyAfterChange: Bool = true) {
        guard !isRestoringSettings else { return }
        invalidateSetupReadiness()
        library.configure(configuration)
        defaults.set(provider.rawValue, forKey: "provider")
        defaults.set(baseURL, forKey: "baseURL")
        defaults.set(model, forKey: "model")
        invalidateExternal()
        draftChanged()
        connectionEpoch = UUID()
        connectionTask?.cancel()
        checkingConnection = false
        models = []
        connectionStatus = "Settings saved. Check the connection to list models."
        received(monitor.captureCurrent())
        if verifyAfterChange { scheduleSetupVerification() }
    }

    func switchProvider() {
        baseURL = provider == .lmStudio ? "http://127.0.0.1:1234" : "http://127.0.0.1:11434"
        model = ""
        saveConfiguration()
    }

    func connect() {
        saveConfiguration(verifyAfterChange: false)
        let config = configuration
        let epoch = UUID()
        connectionEpoch = epoch
        checkingConnection = true
        connectionStatus = "Looking for local models…"
        connectionTask = Task {
            do {
                let found = try await listModels(config)
                guard !Task.isCancelled, connectionEpoch == epoch else { return }
                if !found.contains(model) { model = found.first ?? "" }
                // Choosing the first model invalidates old requests synchronously.
                // Publish this completed discovery after that observer has run.
                models = found
                defaults.set(model, forKey: "model")
                connectionStatus = found.isEmpty ? "Server is online. Load a chat model in your local AI app." : "Connected · \(found.count) local model\(found.count == 1 ? "" : "s") available"
                checkingConnection = false
                scheduleSetupVerification()
            } catch {
                guard !Task.isCancelled, connectionEpoch == epoch else { return }
                connectionStatus = error.localizedDescription
            }
            checkingConnection = false
        }
    }

    func draftChanged() {
        draftEpoch = UUID()
        draftTask?.cancel()
        draftBusy = false
        draftCorrection = nil
        draftStatus = ""
    }

    func checkDraft() {
        draftChanged()
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard library.deletingID == nil else {
            draftStatus = "Wait for model deletion to finish before checking writing."
            return
        }
        guard readyInApp else {
            draftStatus = "Complete the setup check before checking your writing."
            return
        }
        let original = draft
        let epoch = draftEpoch
        let config = configuration
        draftBusy = true
        draftStatus = "Your local model is reading this draft…"
        draftTask = Task {
            do {
                let correction = try await correctText(original, config)
                guard !Task.isCancelled, draftEpoch == epoch, draft.utf8.elementsEqual(original.utf8), configuration == config else { return }
                draftCorrection = correction
                draftStatus = correction.hasChanges ? "A clearer version is ready." : "Looks good. No changes suggested."
            } catch {
                guard !Task.isCancelled, draftEpoch == epoch else { return }
                noteServiceFailure(error)
                draftStatus = error.localizedDescription
            }
            draftBusy = false
        }
    }

    func applyDraft() {
        guard let correction = draftCorrection, draft.utf8.elementsEqual(correction.original.utf8) else { draftChanged(); return }
        draft = correction.corrected
        draftChanged()
        draftStatus = "Suggestion applied."
    }

    func invalidateExternal() {
        gate.invalidate()
        externalTask?.cancel()
        externalTask = nil
        externalCorrection = nil
        snapshot = nil
        externalStatus = ""
        externalScope = ""
        externalBusy = false
        externalCanApply = false
        externalNeedsSetup = false
        externalSettingsDestination = .appAccess
        manualRequestActive = false
        panel?.hide()
    }

    /// A deliberate check works independently of background suggestions, while
    /// retaining both macOS permission and the user's per-app allowlist.
    func triggerShortcut() {
        invalidateExternal()
        guard library.deletingID == nil else { return }
        trusted = monitor.accessibilityTrusted
        guard let value = monitor.captureCurrent(intent: .shortcut) else {
            guard !monitor.lastCaptureWasEmpty else { return }
            externalApp = "Keyboard shortcut"
            externalStatus = monitor.lastCaptureStatus
            externalNeedsSetup = true
            externalSettingsDestination = readyInOtherApps ? .appAccess : .setup
            panel?.show(near: nil)
            return
        }
        guard readyInOtherApps else {
            externalApp = value.appName
            externalScope = value.scopeLabel
            externalStatus = "Complete setup to check writing in other apps."
            externalNeedsSetup = true
            externalSettingsDestination = .setup
            panel?.show(near: value.frame)
            return
        }
        received(value)
    }

    private func received(_ value: FieldSnapshot?) {
        invalidateExternal()
        guard let value else { return }
        guard library.deletingID == nil else { return }
        guard readyInOtherApps else { return }
        let manual = value.intent == .shortcut
        manualRequestActive = manual
        snapshot = value
        fieldID = UUID().uuidString
        externalApp = value.appName
        externalScope = value.scopeLabel
        externalCanApply = value.canApply
        let id = fieldID
        guard let ticket = gate.begin(bundleID: value.bundleID, fieldID: id, text: value.text,
                                      accessibilityTrusted: monitor.accessibilityTrusted,
                                      enabled: enabled || manual, allowedBundleIDs: allowedIDs,
                                      allowShortText: manual) else {
            externalStatus = "This text cannot be checked. Focus an allowed input and try again."
            if manual { panel?.show(near: value.frame) }
            return
        }
        let config = configuration
        externalBusy = true
        if manual {
            externalStatus = "Checking \(value.scopeLabel.lowercased())…"
            panel?.show(near: value.frame)
        }
        externalTask = Task {
            do {
                if !manual { try await Task.sleep(nanoseconds: 1_200_000_000) }
                guard !Task.isCancelled, canPresent(ticket, value: value, id: id) else { return }
                let correction = try await correctText(value.text, config)
                guard !Task.isCancelled, configuration == config, canPresent(ticket, value: value, id: id) else { return }
                externalBusy = false
                if correction.hasChanges {
                    externalCorrection = correction
                    externalStatus = value.canApply ? "" : "This app doesn't allow direct replacement. Use Copy to paste the suggestion yourself."
                    panel?.show(near: value.frame)
                } else if manual {
                    externalStatus = "Looks good. No changes suggested."
                    panel?.show(near: value.frame)
                }
            } catch {
                guard !Task.isCancelled, canPresent(ticket, value: value, id: id) else { return }
                let needsSetupCheck = noteServiceFailure(error)
                if needsSetupCheck && manual {
                    // Keep only the review target so editing or clearing the
                    // field still dismisses this error through normal validation.
                    snapshot = value
                    manualRequestActive = true
                }
                externalBusy = false
                externalApp = value.appName
                externalScope = value.scopeLabel
                externalStatus = error.localizedDescription
                externalNeedsSetup = true
                externalSettingsDestination = needsSetupCheck ? .setup : .models
                if manual { panel?.show(near: value.frame) }
            }
        }
    }

    private func canPresent(_ ticket: SuggestionGate.Ticket, value: FieldSnapshot, id: String) -> Bool {
        guard readyInOtherApps else { return false }
        guard let current = monitor.captureCurrent(intent: value.intent), current.isSame(as: value) else {
            if monitor.lastCaptureWasEmpty { invalidateExternal() }
            return false
        }
        let manual = value.intent == .shortcut
        return gate.accepts(ticket, bundleID: current.bundleID, fieldID: id, text: current.text,
                            accessibilityTrusted: monitor.accessibilityTrusted, enabled: enabled || manual,
                            allowedBundleIDs: allowedIDs, allowShortText: manual)
    }

    func validateManualTarget() {
        guard manualRequestActive, let value = snapshot else { return }
        guard let current = monitor.captureCurrent(intent: .shortcut), current.isSame(as: value) else {
            // Editing ends this review. In particular, deleting a field in
            // stages must not leave a changed-input notice behind when empty.
            invalidateExternal()
            return
        }
    }

    func applyExternal() {
        guard let value = snapshot, let correction = externalCorrection, externalCanApply else { return }
        do {
            try monitor.apply(correction, to: value)
            invalidateExternal()
        } catch {
            if (error as? AccessibilityMonitorError) == .sourceChanged, monitor.lastCaptureWasEmpty {
                invalidateExternal()
                return
            }
            externalStatus = error.localizedDescription
            externalCorrection = nil
            externalBusy = false
            panel?.show(near: value.frame)
        }
    }

    func copyExternal() {
        guard let value = snapshot, let correction = externalCorrection else { return }
        guard let current = monitor.captureCurrent(intent: value.intent), current.isSame(as: value) else {
            if monitor.lastCaptureWasEmpty { invalidateExternal() }
            else { validateManualTarget() }
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(correction.corrected, forType: .string)
        invalidateExternal()
    }

    func openModels() {
        section = "Models"
    }

    func openExternalSettings() {
        let destination = externalSettingsDestination
        invalidateExternal()
        switch destination {
        case .setup:
            openSetup()
            return
        case .models:
            openModels()
        case .appAccess:
            section = "App access"
            refreshApps()
        }
        onOpenSettings?()
    }

    func dismissExternal() { invalidateExternal() }

    func prepareForModelDeletion(_ request: ModelDeletionRequest) {
        guard library.pendingDeletion?.id == request.id,
              provider == request.provider, baseURL == request.baseURL else { return }
        invalidateExternal()
        draftChanged()
        if request.matchesSelectedModel(model) || setupAIState.isChecking || scheduledSetupTask != nil {
            invalidateSetupReadiness()
        }
    }

    func modelWasDeleted(_ request: ModelDeletionRequest) {
        guard provider == request.provider, baseURL == request.baseURL else { return }
        models.removeAll { request.matchesSelectedModel($0) }
        guard request.matchesSelectedModel(model) else { return }
        invalidateSetupReadiness()
        invalidateExternal()
        draftChanged()
        enabled = false
        model = ""
        connectionStatus = "Model deleted. Download or choose a local model to check writing."
    }

}

extension AppModel {
    func defaultsModelChanged() {
        guard !isRestoringSettings else { return }
        invalidateSetupReadiness()
        library.configure(configuration)
        defaults.set(model, forKey: "model")
        connectionStatus = model.isEmpty ? "Choose a local model." : "Model selection saved. Setup verifies it automatically."
        connectionEpoch = UUID()
        connectionTask?.cancel()
        checkingConnection = false
        draftChanged()
        received(monitor.captureCurrent())
        scheduleSetupVerification()
    }
}
