import Foundation
import Combine
import EnglishCorrectCore

@MainActor
protocol ModelLibraryBackend {
    func installed(_ config: LocalAIConfiguration) async throws -> [String]
    func start(_ spec: DownloadSpec, config: LocalAIConfiguration) async throws -> DownloadUpdate
    func poll(_ jobID: String, config: LocalAIConfiguration) async throws -> DownloadUpdate
    func pull(_ spec: DownloadSpec, config: LocalAIConfiguration, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws
    func prepare(_ id: String, config: LocalAIConfiguration) async throws -> String
    func delete(_ id: String, spec: DownloadSpec, config: LocalAIConfiguration) async throws -> [String]
}

@MainActor
private struct LocalModelLibraryBackend: ModelLibraryBackend {
    func installed(_ config: LocalAIConfiguration) async throws -> [String] { try await ModelDownloadClient(configuration: config).installedModelIDs() }
    func start(_ spec: DownloadSpec, config: LocalAIConfiguration) async throws -> DownloadUpdate { try await ModelDownloadClient(configuration: config).startLMStudio(spec) }
    func poll(_ jobID: String, config: LocalAIConfiguration) async throws -> DownloadUpdate { try await ModelDownloadClient(configuration: config).pollLMStudio(jobID: jobID) }
    func pull(_ spec: DownloadSpec, config: LocalAIConfiguration, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws { try await ModelDownloadClient(configuration: config).pullOllama(spec, onProgress: progress) }
    func prepare(_ id: String, config: LocalAIConfiguration) async throws -> String { try await ModelDownloadClient(configuration: config).prepareModel(id) }
    func delete(_ id: String, spec: DownloadSpec, config: LocalAIConfiguration) async throws -> [String] {
        if config.provider == .ollama {
            try await ModelDownloadClient(configuration: config).deleteOllamaModel(id)
            return [id]
        } else {
            return try await LMStudioModelRemoval().remove(id, spec: spec, configuration: config)
        }
    }
}

struct SavedModelDownload: Codable, Equatable {
    let catalogID: String
    let provider: LocalProvider
    let baseURL: String
    let jobID: String
}

struct SavedModelSelection: Codable, Equatable {
    let catalogID: String
    let provider: LocalProvider
    let baseURL: String
    let instanceID: String
    let installedModelID: String?

    init(catalogID: String, provider: LocalProvider, baseURL: String, instanceID: String, installedModelID: String? = nil) {
        self.catalogID = catalogID
        self.provider = provider
        self.baseURL = baseURL
        self.instanceID = instanceID
        self.installedModelID = installedModelID
    }
}

/// The confirmation owns its exact target so later settings changes cannot retarget deletion.
struct ModelDeletionRequest: Identifiable {
    let id: UUID
    let item: RecommendedModel
    let installedModelID: String
    let provider: LocalProvider
    let baseURL: String
    let selectedModelID: String
    let selectedInstanceIDs: [String]
    fileprivate let serverEpoch: UUID

    func matchesSelectedModel(_ modelID: String) -> Bool {
        modelID == installedModelID || selectedInstanceIDs.contains(modelID)
    }

    fileprivate func includingVerifiedAliases(_ aliases: [String]) -> ModelDeletionRequest {
        var seen = Set<String>()
        let unique = (selectedInstanceIDs + aliases).filter { !$0.isEmpty && seen.insert($0).inserted }
        return ModelDeletionRequest(id: id, item: item, installedModelID: installedModelID,
                                    provider: provider, baseURL: baseURL, selectedModelID: selectedModelID,
                                    selectedInstanceIDs: unique, serverEpoch: serverEpoch)
    }
}

@MainActor
final class ModelLibrary: ObservableObject {
    @Published private(set) var installedIDs: [String] = []
    @Published private(set) var activeDownloadID: String?
    @Published private(set) var preparingID: String?
    @Published private(set) var pendingDeletion: ModelDeletionRequest?
    @Published private(set) var deletingID: String?
    @Published private(set) var checking = false
    @Published private(set) var status = "Check your local server to see downloaded models."
    @Published private(set) var cardMessages: [String: String] = [:]
    @Published private(set) var progress: [String: ModelDownloadProgress] = [:]
    @Published private(set) var savedJobs: [SavedModelDownload] = []
    @Published private(set) var configuration = LocalAIConfiguration(provider: .lmStudio, baseURL: "http://127.0.0.1:1234", model: "")
    @Published private(set) var selectedInstances: [SavedModelSelection] = []
    private let defaults: UserDefaults
    private let backend: ModelLibraryBackend
    private let pollingNanoseconds: UInt64
    private var downloadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var deletionTask: Task<Void, Never>?
    private var startGenerations: [String: UUID] = [:]
    private var epoch = UUID()
    private var refreshEpoch = UUID()
    private var prepareEpoch = UUID()
    private var serverEpoch = UUID()

    init(defaults: UserDefaults = .standard, backend: ModelLibraryBackend? = nil, pollingNanoseconds: UInt64 = 1_000_000_000) {
        self.defaults = defaults
        self.backend = backend ?? LocalModelLibraryBackend()
        self.pollingNanoseconds = pollingNanoseconds
        if let data = defaults.data(forKey: "modelSelectedInstances"), let saved = try? JSONDecoder().decode([SavedModelSelection].self, from: data) { selectedInstances = saved }
        if let data = defaults.data(forKey: "modelDownloadJobs"), let saved = try? JSONDecoder().decode([SavedModelDownload].self, from: data) { savedJobs = saved }
    }

    var isBusy: Bool { activeDownloadID != nil || preparingID != nil || deletingID != nil }
    var memoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }

    func configure(_ config: LocalAIConfiguration) {
        let changedServer = configuration.provider != config.provider || configuration.baseURL != config.baseURL
        let changedModel = configuration.model != config.model
        if changedModel || changedServer {
            pendingDeletion = nil
            prepareEpoch = UUID()
            prepareTask?.cancel()
            preparingID = nil
        }
        if changedServer { stopChecking() }
        configuration = config
        guard changedServer else { return }
        serverEpoch = UUID()
        refreshEpoch = UUID()
        refreshTask?.cancel()
        prepareEpoch = UUID()
        prepareTask?.cancel()
        preparingID = nil
        checking = false
        installedIDs = []
        cardMessages = [:]
        progress = [:]
        status = "Check your local server to see downloaded models."
    }

    func installedID(_ item: RecommendedModel) -> String? { item.installedID(in: installedIDs, provider: configuration.provider) }
    func savedJob(_ item: RecommendedModel) -> SavedModelDownload? {
        savedJobs.first { $0.catalogID == item.id && $0.provider == configuration.provider && $0.baseURL == configuration.baseURL }
    }

    func refresh() {
        guard !isBusy else { return }
        refreshTask?.cancel()
        let token = UUID(); refreshEpoch = token
        let config = configuration
        checking = true
        status = "Checking downloaded models…"
        refreshTask = Task {
            do {
                let ids = try await backend.installed(config)
                guard !Task.isCancelled, refreshEpoch == token else { return }
                installedIDs = ids
                status = "Connected to \(config.provider.displayName). Downloads stay in its model library."
            } catch {
                guard !Task.isCancelled, refreshEpoch == token else { return }
                status = error.localizedDescription
            }
            checking = false
        }
    }

    func download(_ item: RecommendedModel) {
        guard !isBusy else { return }
        pendingDeletion = nil
        let config = configuration
        let token = UUID(); epoch = token
        activeDownloadID = item.id
        let startKey = config.provider.rawValue + "|" + config.baseURL + "|" + item.id
        startGenerations[startKey] = token
        cardMessages[item.id] = "Starting download…"
        progress[item.id] = nil
        downloadTask = Task {
            do {
                if config.provider == .lmStudio {
                    let initial = try await backend.start(item.downloadSpec, config: config)
                    // Persist a server job even if the user stopped checking during this request.
                    if let jobID = initial.jobID, startGenerations[startKey] == token { saveJob(item, config: config, jobID: jobID) }
                    guard !Task.isCancelled, epoch == token else { return }
                    try await track(initial, item: item, config: config, token: token)
                } else {
                    try await backend.pull(item.downloadSpec, config: config) { [weak self] update in
                        await self?.record(update, itemID: item.id, token: token)
                    }
                    guard !Task.isCancelled, epoch == token else { return }
                }
                try await finish(item, config: config, token: token)
            } catch {
                guard !Task.isCancelled, epoch == token else { return }
                cardMessages[item.id] = error.localizedDescription
            }
            if epoch == token { activeDownloadID = nil }
        }
    }

    func resume(_ item: RecommendedModel) {
        guard !isBusy, let job = savedJob(item) else { return }
        pendingDeletion = nil
        let config = configuration
        let token = UUID(); epoch = token
        activeDownloadID = item.id
        cardMessages[item.id] = "Checking the existing download…"
        downloadTask = Task {
            do {
                let current = try await backend.poll(job.jobID, config: config)
                guard !Task.isCancelled, epoch == token else { return }
                try await track(current, item: item, config: config, token: token)
                try await finish(item, config: config, token: token)
            } catch {
                guard !Task.isCancelled, epoch == token else { return }
                cardMessages[item.id] = error.localizedDescription
            }
            if epoch == token { activeDownloadID = nil }
        }
    }

    func stopChecking() {
        if let id = activeDownloadID {
            cardMessages[id] = configuration.provider == .lmStudio ? "Tracking stopped. LM Studio may continue downloading; manage or pause it there." : "Download connection closed. Choose Download to retry; Ollama can reuse partial files."
        }
        epoch = UUID()
        // LM Studio jobs live in its server; let an in-flight start return its job ID.
        // Epoch checks prevent its late response from updating this page or continuing polling.
        if configuration.provider == .ollama { downloadTask?.cancel() }
        downloadTask = nil
        activeDownloadID = nil
    }

    func use(_ item: RecommendedModel, onSelected: @escaping (String) -> Void) {
        guard !isBusy, let id = installedID(item) else { return }
        pendingDeletion = nil
        let config = configuration
        let token = UUID(); prepareEpoch = token
        preparingID = item.id
        cardMessages[item.id] = "Preparing \(item.tier)…"
        prepareTask = Task {
            do {
                let readyID = try await backend.prepare(id, config: config)
                guard !Task.isCancelled, prepareEpoch == token,
                      configuration.provider == config.provider, configuration.baseURL == config.baseURL else { return }
                selectedInstances.removeAll { $0.catalogID == item.id && $0.provider == config.provider && $0.baseURL == config.baseURL }
                selectedInstances.append(SavedModelSelection(catalogID: item.id, provider: config.provider, baseURL: config.baseURL, instanceID: readyID, installedModelID: id))
                persistSelections()
                onSelected(readyID)
                cardMessages[item.id] = "\(item.tier) is ready for your writing."
            } catch {
                guard !Task.isCancelled, prepareEpoch == token else { return }
                cardMessages[item.id] = error.localizedDescription
            }
            if prepareEpoch == token { preparingID = nil }
        }
    }

    func isSelected(_ item: RecommendedModel, modelID: String) -> Bool {
        item.installedID(in: [modelID], provider: configuration.provider) != nil || selectedInstances.contains {
            $0.catalogID == item.id && $0.provider == configuration.provider && $0.baseURL == configuration.baseURL && $0.instanceID == modelID
        }
    }

    func requestDeletion(_ item: RecommendedModel) {
        guard !isBusy, let installedModelID = installedID(item) else { return }
        let aliases = selectedInstances.filter {
            $0.catalogID == item.id && $0.provider == configuration.provider && $0.baseURL == configuration.baseURL
                && ($0.installedModelID == nil || $0.installedModelID == installedModelID)
        }.map(\.instanceID)
        pendingDeletion = ModelDeletionRequest(id: UUID(), item: item, installedModelID: installedModelID,
                                               provider: configuration.provider, baseURL: configuration.baseURL,
                                               selectedModelID: configuration.model, selectedInstanceIDs: aliases,
                                               serverEpoch: serverEpoch)
    }

    func cancelDeletion() { pendingDeletion = nil }

    func confirmDeletion(onDeleted: @escaping (ModelDeletionRequest) -> Void) {
        guard let request = pendingDeletion, !isBusy else { return }
        pendingDeletion = nil
        guard isCurrentServer(request), installedID(request.item) == request.installedModelID else {
            status = "The model library changed. Refresh and choose Delete again."
            return
        }

        // An earlier read must not restore the deleted model after this mutation.
        refreshEpoch = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        checking = false
        epoch = UUID()
        startGenerations[request.provider.rawValue + "|" + request.baseURL + "|" + request.item.id] = nil
        deletingID = request.item.id
        cardMessages[request.item.id] = "Deleting \(request.item.tier)…"
        let config = LocalAIConfiguration(provider: request.provider, baseURL: request.baseURL, model: request.selectedModelID)
        deletionTask = Task {
            defer {
                deletingID = nil
                deletionTask = nil
            }
            let completedRequest: ModelDeletionRequest
            do {
                let verifiedAliases = try await backend.delete(request.installedModelID, spec: request.item.downloadSpec, config: config)
                completedRequest = request.includingVerifiedAliases(verifiedAliases)
            } catch {
                if isCurrentServer(request) { cardMessages[request.item.id] = error.localizedDescription }
                return
            }

            // The old scope's persisted metadata must be cleaned even if the user changed servers.
            savedJobs.removeAll { $0.catalogID == request.item.id && $0.provider == request.provider && $0.baseURL == request.baseURL }
            persistJobs()
            selectedInstances.removeAll {
                $0.catalogID == request.item.id && $0.provider == request.provider && $0.baseURL == request.baseURL
                    && ($0.installedModelID == nil || $0.installedModelID == request.installedModelID)
            }
            persistSelections()
            if isCurrentServer(request) {
                installedIDs.removeAll { $0 == request.installedModelID }
                progress[request.item.id] = nil
                cardMessages[request.item.id] = "Deleted. You can download \(request.item.tier) again."
                status = "\(request.item.tier) was deleted from \(request.provider.displayName)."
                onDeleted(completedRequest)
            }

            do {
                let ids = try await backend.installed(config)
                guard isCurrentServer(request) else { return }
                installedIDs = ids.filter { $0 != request.installedModelID }
            } catch {
                guard isCurrentServer(request) else { return }
                status = "\(request.item.tier) was deleted, but the model list could not refresh. Choose Refresh to check your server."
            }
        }
    }

    private func isCurrentServer(_ request: ModelDeletionRequest) -> Bool {
        serverEpoch == request.serverEpoch && configuration.provider == request.provider && configuration.baseURL == request.baseURL
    }

    private func record(_ update: ModelDownloadProgress, itemID: String, token: UUID) {
        guard epoch == token else { return }
        progress[itemID] = update
        cardMessages[itemID] = update.status
    }

    private func track(_ initial: DownloadUpdate, item: RecommendedModel, config: LocalAIConfiguration, token: UUID) async throws {
        var current = initial
        while true {
            try Task.checkCancellation()
            guard epoch == token else { throw CancellationError() }
            record(current.progress, itemID: item.id, token: token)
            if current.isComplete { return }
            if current.isPaused { throw LibraryError.paused }
            guard let jobID = current.jobID ?? savedJobFor(item.id, config: config)?.jobID else { throw LibraryError.missingJob }
            try await Task.sleep(nanoseconds: pollingNanoseconds)
            current = try await backend.poll(jobID, config: config)
        }
    }

    private func finish(_ item: RecommendedModel, config: LocalAIConfiguration, token: UUID) async throws {
        guard !Task.isCancelled, epoch == token else { throw CancellationError() }
        savedJobs.removeAll { $0.catalogID == item.id && $0.provider == config.provider && $0.baseURL == config.baseURL }
        persistJobs()
        refreshEpoch = UUID()
        refreshTask?.cancel()
        checking = false
        // Completion alone does not make a model selectable. Confirm that the provider lists it.
        let ids = try await backend.installed(config)
        guard !Task.isCancelled, epoch == token else { throw CancellationError() }
        installedIDs = ids
        cardMessages[item.id] = installedID(item) == nil ? "Download finished. Choose Refresh to check whether the model is ready to use." : "Downloaded. Choose Use \(item.tier) when you’re ready."
        status = "Your download is complete. Your active model has not changed."
    }

    private func saveJob(_ item: RecommendedModel, config: LocalAIConfiguration, jobID: String) {
        savedJobs.removeAll { $0.catalogID == item.id && $0.provider == config.provider && $0.baseURL == config.baseURL }
        savedJobs.append(SavedModelDownload(catalogID: item.id, provider: config.provider, baseURL: config.baseURL, jobID: jobID))
        persistJobs()
    }
    private func savedJobFor(_ id: String, config: LocalAIConfiguration) -> SavedModelDownload? {
        savedJobs.first { $0.catalogID == id && $0.provider == config.provider && $0.baseURL == config.baseURL }
    }
    private func persistJobs() { defaults.set(try? JSONEncoder().encode(savedJobs), forKey: "modelDownloadJobs") }
    private func persistSelections() { defaults.set(try? JSONEncoder().encode(selectedInstances), forKey: "modelSelectedInstances") }
}

private enum LibraryError: LocalizedError {
    case paused, missingJob
    var errorDescription: String? {
        switch self {
        case .paused: return "Download is paused in LM Studio. Resume it there, then choose Resume checking."
        case .missingJob: return "The server did not return a download job. Check its model library and try again."
        }
    }
}
