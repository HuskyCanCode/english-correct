import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public model metadata, never text from an input field.
public struct DownloadSpec: Sendable, Equatable {
    public let catalogID: String
    public let lmStudioRepository: String
    public let quantization: String
    public let ollamaModel: String

    public init(catalogID: String, lmStudioRepository: String, quantization: String, ollamaModel: String) {
        self.catalogID = catalogID
        self.lmStudioRepository = lmStudioRepository
        self.quantization = quantization
        self.ollamaModel = ollamaModel
    }
}

public struct ModelDownloadProgress: Sendable, Equatable {
    public let status: String
    public let completedBytes: Int64?
    public let totalBytes: Int64?

    public init(status: String, completedBytes: Int64? = nil, totalBytes: Int64? = nil) {
        self.status = status
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public var fraction: Double? {
        guard let completedBytes, let totalBytes, totalBytes > 0,
              completedBytes >= 0, completedBytes <= totalBytes else { return nil }
        return Double(completedBytes) / Double(totalBytes)
    }
}

public struct DownloadUpdate: Sendable, Equatable {
    public let progress: ModelDownloadProgress
    public let jobID: String?
    public let isComplete: Bool
    public let isPaused: Bool

    public init(progress: ModelDownloadProgress, jobID: String? = nil, isComplete: Bool = false, isPaused: Bool = false) {
        self.progress = progress
        self.jobID = jobID
        self.isComplete = isComplete
        self.isPaused = isPaused
    }
}

public enum ModelDownloadError: Error, LocalizedError, Equatable, Sendable {
    case invalidSpecification
    case wrongProvider
    case invalidJobID
    case authenticationRequired
    case endpointUnavailable
    case insufficientStorage
    case downloadFailed
    case deletionFailed
    case modelInUse
    case invalidResponse
    case responseTooLong
    case incompleteDownload
    case connectionFailed
    case timedOut
    case redirectBlocked
    case serverError(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidSpecification: return "This model’s information is invalid. Choose a suggested local model."
        case .wrongProvider: return "Choose the matching local AI provider for this model."
        case .invalidJobID: return "The saved download could not be identified. Check its progress in LM Studio."
        case .authenticationRequired: return "The local server requires authentication. Download or load the model in your AI app, then refresh the model list here."
        case .endpointUnavailable: return "This server does not support this model-management request, or the model or download was not found. For LM Studio, use version 0.4 or later, or download and load the model in LM Studio and refresh here."
        case .insufficientStorage: return "There is not enough free disk space for this model. Free some space or choose a smaller model."
        case .downloadFailed: return "The local AI app could not finish the model operation. Check its download screen and internet connection, then retry."
        case .deletionFailed: return "The local AI app could not remove this model. Check it in your AI app and refresh the model list here."
        case .modelInUse: return "Could not confirm that this model is unloaded. Stop using it in your AI app and try again."
        case .invalidResponse: return "The local AI app returned an unreadable model status. Check the model in that app and refresh here."
        case .responseTooLong: return "The local AI app returned an unexpectedly large model status. Check the download in that app."
        case .incompleteDownload: return "The download connection ended before the model was ready. Retry the download to continue it."
        case .connectionFailed: return "Could not connect to the local AI app. Start its local server and check the address and port."
        case .timedOut: return "The local AI app stopped responding. Check the operation in that app, then retry."
        case .redirectBlocked: return "The local AI server tried to redirect this request. Use its direct localhost address."
        case .serverError(let code): return "The local AI app returned HTTP \(code). Check its model screen and retry."
        }
    }
}

public struct ModelDownloadClient: Sendable {
    public let configuration: LocalAIConfiguration
    typealias DataTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias StreamTransport = @Sendable (URLRequest, @escaping @Sendable (StreamEvent) async throws -> Void) async throws -> Void
    enum StreamEvent: Sendable {
        case response(HTTPURLResponse)
        case line(Data)
    }
    private let transport: DataTransport
    private let streamTransport: StreamTransport
    static let maximumStatusBytes = 65_536

    public init(configuration: LocalAIConfiguration) {
        self.configuration = configuration
        self.transport = { try await Self.send($0) }
        self.streamTransport = { try await Self.stream($0, receive: $1) }
    }

    // Injected transports let tests prove request shape, cancellation, and stream failures offline.
    init(configuration: LocalAIConfiguration, transport: @escaping DataTransport,
         streamTransport: @escaping StreamTransport = { try await Self.stream($0, receive: $1) }) {
        self.configuration = configuration
        self.transport = transport
        self.streamTransport = streamTransport
    }

    public func startLMStudio(_ spec: DownloadSpec) async throws -> DownloadUpdate {
        guard configuration.provider == .lmStudio else { throw ModelDownloadError.wrongProvider }
        try Self.validate(spec)
        let request = try request(path: "/api/v1/models/download", body: ["model": spec.lmStudioRepository, "quantization": spec.quantization])
        return try Self.parseLMStudio(try await requestData(request))
    }

    public func pollLMStudio(jobID: String) async throws -> DownloadUpdate {
        guard configuration.provider == .lmStudio else { throw ModelDownloadError.wrongProvider }
        guard Self.isValidJobID(jobID) else { throw ModelDownloadError.invalidJobID }
        let result = try Self.parseLMStudio(try await requestData(request(path: "/api/v1/models/download/status/" + jobID)))
        guard result.jobID == jobID else { throw ModelDownloadError.invalidResponse }
        return result
    }

    public func prepareModel(_ modelID: String) async throws -> String {
        try Task.checkCancellation()
        guard Self.validModelID(modelID) else { throw ModelDownloadError.invalidSpecification }
        // Validate the address even when Ollama defers loading until inference.
        _ = try LocalAIClient.endpoint(configuration, path: "/")
        if configuration.provider == .ollama { return modelID }
        let request = try request(path: "/api/v1/models/load", body: ["model": modelID, "context_length": 8192], timeout: 120)
        let root = try Self.object(try await requestData(request))
        if root["error"] != nil { throw Self.serverFailure(root) }
        guard root["type"] as? String == "llm", root["status"] as? String == "loaded",
              let instance = root["instance_id"] as? String, Self.validModelID(instance) else {
            throw ModelDownloadError.invalidResponse
        }
        return instance
    }

    /// Remove one explicitly chosen local Ollama model. The caller must obtain the exact
    /// tagged identifier from the installed model list and confirm it with the user.
    public func deleteOllamaModel(_ modelID: String) async throws {
        try Task.checkCancellation()
        guard configuration.provider == .ollama else { throw ModelDownloadError.wrongProvider }
        // Require an explicit tag: deleting an untagged name would implicitly select
        // "latest". A namespace is allowed, but URLs and remote registry hosts are not.
        guard Self.validModelID(modelID),
              modelID.range(of: "\\A(?:[A-Za-z0-9][A-Za-z0-9_-]{0,95}/)?[A-Za-z0-9][A-Za-z0-9._-]{0,95}:[A-Za-z0-9][A-Za-z0-9._-]{0,95}\\z", options: .regularExpression) != nil else {
            throw ModelDownloadError.invalidSpecification
        }
        // A plain alias can still point to Ollama Cloud. Recheck its local metadata
        // before calling generate, because generate can otherwise route to a remote host.
        let installedData = try await requestData(request(path: "/api/tags"), requiredStatus: 200)
        let installed = try Self.object(installedData)
        if installed["error"] != nil { throw ModelDownloadError.deletionFailed }
        guard let records = installed["models"] as? [[String: Any]],
              records.filter({ ($0["name"] as? String) == modelID }).count == 1,
              try LocalAIClient.parseModels(installedData, provider: .ollama).contains(modelID) else {
            throw LocalAIError.modelUnavailable
        }
        let unloadRequest = try request(path: "/api/generate", body: ["model": modelID, "keep_alive": 0, "stream": false])
        let unloaded = try Self.object(try await requestData(unloadRequest, requiredStatus: 200))
        if unloaded["error"] != nil { throw ModelDownloadError.deletionFailed }
        guard unloaded["model"] as? String == modelID,
              let done = unloaded["done"] as? NSNumber, CFGetTypeID(done) == CFBooleanGetTypeID(), done.boolValue,
              unloaded["done_reason"] as? String == "unload", unloaded["response"] as? String == "",
              Self.hasNoRemoteModelMetadata(unloaded) else { throw ModelDownloadError.invalidResponse }
        var request = try request(path: "/api/delete", body: ["model": modelID])
        request.httpMethod = "DELETE"
        let data = try await requestData(request, requiredStatus: 200)
        // Ollama documents a 200 with no content. Accept an empty JSON object from
        // compatible versions, but never turn an error or unexpected body into success.
        if data.isEmpty { return }
        let root = try Self.object(data)
        if root["error"] != nil { throw ModelDownloadError.deletionFailed }
        guard root.isEmpty else { throw ModelDownloadError.invalidResponse }
    }

    /// Unload only the unambiguous official Qwen Q4 catalog model before its verified
    /// files are moved to Trash. No file paths or deletion decisions come from this API.
    @discardableResult
    public func unloadLMStudioModelForDeletion(_ modelID: String, spec: DownloadSpec) async throws -> [String] {
        try Task.checkCancellation()
        guard configuration.provider == .lmStudio else { throw ModelDownloadError.wrongProvider }
        guard let recommendation = ModelCatalog.recommendations.first(where: { $0.downloadSpec == spec }),
              Self.validModelID(modelID), recommendation.installedID(in: [modelID], provider: .lmStudio) == modelID else {
            throw ModelDownloadError.invalidSpecification
        }
        let listRequest = try request(path: "/api/v1/models")
        let instances = try Self.lmStudioDeletionInstances(try await requestData(listRequest, requiredStatus: 200), modelID: modelID, recommendation: recommendation)
        for instance in instances {
            let unload = try request(path: "/api/v1/models/unload", body: ["instance_id": instance])
            let result = try Self.object(try await requestData(unload, requiredStatus: 200))
            if result["error"] != nil { throw ModelDownloadError.deletionFailed }
            guard result["instance_id"] as? String == instance, result.count == 1 else { throw ModelDownloadError.invalidResponse }
        }
        // Recheck once. Do not chase newly created instances or unload another user's
        // work repeatedly if another application is concurrently using this model.
        let remaining = try Self.lmStudioDeletionInstances(try await requestData(listRequest, requiredStatus: 200), modelID: modelID, recommendation: recommendation)
        guard remaining.isEmpty else { throw ModelDownloadError.modelInUse }
        return instances
    }

    private static func lmStudioDeletionInstances(_ data: Data, modelID: String, recommendation: RecommendedModel) throws -> [String] {
        let root = try object(data)
        if root["error"] != nil { throw ModelDownloadError.deletionFailed }
        guard let models = root["models"] as? [[String: Any]] else { throw ModelDownloadError.invalidResponse }
        var matches: [([String: Any], String, [String])] = []
        for model in models {
            guard let key = model["key"] as? String, validModelID(key) else { throw ModelDownloadError.invalidResponse }
            var variants: [String] = []
            if let raw = model["variants"], !(raw is NSNull) {
                guard let names = raw as? [String], names.allSatisfy(validModelID), Set(names).count == names.count else {
                    throw ModelDownloadError.invalidResponse
                }
                variants = names
            }
            if key == modelID || variants.contains(modelID) { matches.append((model, key, variants)) }
        }
        guard matches.count == 1 else { throw ModelDownloadError.invalidResponse }
        let (model, key, variants) = matches[0]
        guard model["type"] as? String == "llm", (model["publisher"] as? String)?.lowercased() == "qwen",
              model["format"] as? String == "gguf", hasNoRemoteModelMetadata(model),
              recommendation.installedID(in: [key], provider: .lmStudio) == key,
              variants.count <= 1 else { throw ModelDownloadError.invalidResponse }
        if let variant = variants.first {
            guard isExplicitQ4Variant(variant), recommendation.installedID(in: [variant], provider: .lmStudio) == variant else {
                throw ModelDownloadError.invalidResponse
            }
            if let selected = model["selected_variant"], !(selected is NSNull), selected as? String != variant {
                throw ModelDownloadError.invalidResponse
            }
        }
        var knownQ4 = isExplicitQ4Variant(key) || variants.contains(where: isExplicitQ4Variant)
        if let raw = model["quantization"], !(raw is NSNull) {
            guard let quantization = raw as? [String: Any] else { throw ModelDownloadError.invalidResponse }
            if let name = quantization["name"], !(name is NSNull) {
                guard (name as? String)?.uppercased() == "Q4_K_M" else { throw ModelDownloadError.invalidResponse }
                knownQ4 = true
            }
        }
        guard knownQ4, let loaded = model["loaded_instances"] as? [[String: Any]], loaded.count <= 32 else {
            throw ModelDownloadError.invalidResponse
        }
        let instances = try loaded.map { instance -> String in
            guard let id = instance["id"] as? String, validModelID(id),
                  id.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._/@:-]{0,511}\\z", options: .regularExpression) != nil,
                  !id.contains("://") else { throw ModelDownloadError.invalidResponse }
            return id
        }
        guard Set(instances).count == instances.count else { throw ModelDownloadError.invalidResponse }
        // An instance ID shared by another model record is not a safe unload target.
        for other in models where (other["key"] as? String) != key {
            guard let loaded = other["loaded_instances"] as? [[String: Any]] else { throw ModelDownloadError.invalidResponse }
            if loaded.contains(where: { ($0["id"] as? String).map(instances.contains) ?? false }) {
                throw ModelDownloadError.invalidResponse
            }
        }
        return instances
    }

    private static func hasNoRemoteModelMetadata(_ model: [String: Any]) -> Bool {
        ["remote_host", "remote_model"].allSatisfy { field in
            guard let value = model[field], !(value is NSNull) else { return true }
            return value as? String == ""
        }
    }

    /// Discover downloaded catalog variants, including unloaded LM Studio models.
    /// The catalog uses Q4_K_M; a generic native key may otherwise resolve to Q8 or another variant.
    public func installedModelIDs() async throws -> [String] {
        if configuration.provider == .ollama {
            return try await LocalAIClient(configuration: configuration, transport: transport).models()
        }
        return try Self.parseInstalledLMStudio(try await requestData(request(path: "/api/v1/models")))
    }

    static func parseInstalledLMStudio(_ data: Data) throws -> [String] {
        let root = try object(data)
        if root["error"] != nil { throw serverFailure(root) }
        guard let models = root["models"] as? [[String: Any]] else { throw ModelDownloadError.invalidResponse }
        var identifiers = Set<String>()
        for model in models {
            guard let type = model["type"] as? String else { throw ModelDownloadError.invalidResponse }
            guard type == "llm" else { continue }
            guard let key = model["key"] as? String, validModelID(key) else { throw ModelDownloadError.invalidResponse }
            if let rawVariants = model["variants"], !(rawVariants is NSNull) {
                guard let variants = rawVariants as? [String], variants.allSatisfy(validModelID) else {
                    throw ModelDownloadError.invalidResponse
                }
                if !variants.isEmpty {
                    // Native variants are full loadable identifiers. Preserve those identifiers;
                    // synthesizing key + quantization can select a nonexistent or different file.
                    identifiers.formUnion(variants.filter(isExplicitQ4Variant))
                    continue
                }
            }
            let quantization = (model["quantization"] as? [String: Any])?["name"] as? String
            if let quantization, !quantization.isEmpty {
                if quantization.uppercased() == "Q4_K_M" { identifiers.insert(key) }
            } else if isExplicitQ4Variant(key) {
                identifiers.insert(key)
            }
        }
        return identifiers.sorted()
    }

    private static func isExplicitQ4Variant(_ identifier: String) -> Bool {
        identifier.lowercased().range(of: "(?:@q4_k_m|[.-]q4_k_m(?:-00001-of-[0-9]{5})?(?:\\.gguf)?)$", options: .regularExpression) != nil
    }

    public func pullOllama(_ spec: DownloadSpec,
                           onProgress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws {
        guard configuration.provider == .ollama else { throw ModelDownloadError.wrongProvider }
        try Self.validate(spec)
        let request = try request(path: "/api/pull", body: ["model": spec.ollamaModel, "stream": true], timeout: 120)
        let accumulator = PullAccumulator()
        do {
            try Task.checkCancellation()
            try await streamTransport(request) { event in
                try Task.checkCancellation()
                if let progress = try await accumulator.receive(event) {
                    await onProgress(progress)
                }
            }
            try Task.checkCancellation()
            try await accumulator.finish()
        } catch { throw Self.mapTransportError(error) }
    }

    private func request(path: String, body: [String: Any]? = nil, timeout: TimeInterval = 30) throws -> URLRequest {
        var request = URLRequest(url: try LocalAIClient.endpoint(configuration, path: path))
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }

    private func requestData(_ request: URLRequest, requiredStatus: Int? = nil) async throws -> Data {
        do {
            try Task.checkCancellation()
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            try Self.validateResponse(response, body: data)
            if let requiredStatus, response.statusCode != requiredStatus { throw ModelDownloadError.invalidResponse }
            guard data.count <= Self.maximumStatusBytes else { throw ModelDownloadError.responseTooLong }
            return data
        } catch { throw Self.mapTransportError(error) }
    }

    static func validate(_ spec: DownloadSpec) throws {
        guard !spec.catalogID.isEmpty, spec.catalogID.count <= 128,
              let repository = URLComponents(string: spec.lmStudioRepository),
              repository.scheme == "https", ["huggingface.co", "hf.co"].contains(repository.host),
              repository.user == nil, repository.password == nil, repository.port == nil,
              repository.query == nil, repository.fragment == nil,
              spec.lmStudioRepository.count <= 512,
              repository.percentEncodedPath.range(of: "^/[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil,
              spec.quantization.range(of: "^[A-Z][A-Z0-9_]{1,31}$", options: .regularExpression) != nil,
              spec.ollamaModel.range(of: "^[a-z0-9][a-z0-9._-]{0,95}:[a-zA-Z0-9][a-zA-Z0-9._-]{0,95}$", options: .regularExpression) != nil,
              Self.validModelID(spec.ollamaModel) else { throw ModelDownloadError.invalidSpecification }
    }

    private static func validModelID(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= 512 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.rangeOfCharacter(from: .controlCharacters) == nil
            && !normalized.split(whereSeparator: { ":/-_.".contains($0) }).contains("cloud")
    }

    static func isValidJobID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
    }

    static func parseLMStudio(_ data: Data) throws -> DownloadUpdate {
        let root = try object(data)
        if root["error"] != nil { throw serverFailure(root) }
        guard let status = root["status"] as? String else { throw ModelDownloadError.invalidResponse }
        if status == "failed" { throw serverFailure(root) }
        guard ["downloading", "paused", "completed", "already_downloaded"].contains(status) else {
            throw ModelDownloadError.invalidResponse
        }
        let job = root["job_id"] as? String
        if let job, !isValidJobID(job) { throw ModelDownloadError.invalidResponse }
        if status != "already_downloaded", job == nil { throw ModelDownloadError.invalidResponse }
        if root["job_id"] != nil, !(root["job_id"] is NSNull), job == nil { throw ModelDownloadError.invalidResponse }
        let completed = try byteCount(root["downloaded_bytes"])
        let total = try byteCount(root["total_size_bytes"])
        try validateCounts(completed: completed, total: total)
        let finished = status == "completed" || status == "already_downloaded"
        return DownloadUpdate(progress: ModelDownloadProgress(status: finished ? "Downloaded" : status == "paused" ? "Paused in LM Studio" : "Downloading", completedBytes: completed, totalBytes: total), jobID: job, isComplete: finished, isPaused: status == "paused")
    }

    static func parseOllamaLine(_ data: Data) throws -> DownloadUpdate {
        let root = try object(data)
        if root["error"] != nil { throw serverFailure(root) }
        guard let status = root["status"] as? String, status.count <= 512 else { throw ModelDownloadError.invalidResponse }
        let display: String
        switch status {
        case "pulling manifest": display = "Finding model files"
        case "verifying sha256 digest": display = "Verifying model files"
        case "writing manifest": display = "Finishing download"
        case "removing any unused layers": display = "Finishing download"
        case "success": display = "Downloaded"
        default:
            guard status.range(of: "^pulling (?:sha256:)?[a-fA-F0-9]{12,64}$", options: .regularExpression) != nil else {
                throw ModelDownloadError.invalidResponse
            }
            // Ollama byte counts describe one file (layer), not the whole model.
            display = "Downloading model file"
        }
        let completed = try byteCount(root["completed"])
        let total = try byteCount(root["total"])
        try validateCounts(completed: completed, total: total)
        return DownloadUpdate(progress: ModelDownloadProgress(status: display, completedBytes: completed, totalBytes: total), isComplete: status == "success")
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumStatusBytes else { throw ModelDownloadError.responseTooLong }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ModelDownloadError.invalidResponse
        }
        return root
    }

    private static func byteCount(_ value: Any?) throws -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let result = Int64(number.stringValue), result >= 0 else { throw ModelDownloadError.invalidResponse }
        return result
    }

    private static func validateCounts(completed: Int64?, total: Int64?) throws {
        if let completed, let total, completed > total { throw ModelDownloadError.invalidResponse }
    }

    static func validateResponse(_ response: HTTPURLResponse, body: Data? = nil) throws {
        if (300..<400).contains(response.statusCode) { throw ModelDownloadError.redirectBlocked }
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw ModelDownloadError.authenticationRequired
        case 404, 405, 501: throw ModelDownloadError.endpointUnavailable
        case 507: throw ModelDownloadError.insufficientStorage
        default:
            if let body, body.count <= maximumStatusBytes,
               let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
               serverFailure(root) == .insufficientStorage { throw ModelDownloadError.insufficientStorage }
            throw ModelDownloadError.serverError(response.statusCode)
        }
    }

    private static func serverFailure(_ root: [String: Any]) -> ModelDownloadError {
        let error = root["error"]
        let details = error as? [String: Any]
        let message = ((error as? String) ?? (details?["message"] as? String) ?? (root["message"] as? String) ?? "").lowercased()
        if ["no space left", "disk full", "not enough space", "insufficient disk", "insufficient storage", "disk quota"].contains(where: message.contains) {
            return .insufficientStorage
        }
        return .downloadFailed
    }

    private static func mapTransportError(_ error: Error) -> Error {
        guard let error = error as? URLError else { return error }
        if error.code == .cancelled { return CancellationError() }
        if error.code == .timedOut { return ModelDownloadError.timedOut }
        return ModelDownloadError.connectionFailed
    }

    static func sessionConfiguration(resourceTimeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        return configuration
    }

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: sessionConfiguration(resourceTimeout: 150), delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ModelDownloadError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumStatusBytes else { throw ModelDownloadError.responseTooLong }
            data.append(byte)
        }
        return (data, response)
    }

    private static func stream(_ request: URLRequest, receive: @escaping @Sendable (StreamEvent) async throws -> Void) async throws {
        let session = URLSession(configuration: sessionConfiguration(resourceTimeout: 86_400), delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ModelDownloadError.invalidResponse }
        try await receive(.response(response))
        var buffer = DownloadLineBuffer()
        for try await byte in bytes {
            try Task.checkCancellation()
            if let line = try buffer.append(byte) { try await receive(.line(line)) }
        }
        if let line = buffer.finish() { try await receive(.line(line)) }
    }

    private actor PullAccumulator {
        var receivedResponse = false
        var succeeded = false
        func receive(_ event: StreamEvent) throws -> ModelDownloadProgress? {
            switch event {
            case .response(let response):
                guard !receivedResponse else { throw ModelDownloadError.invalidResponse }
                try ModelDownloadClient.validateResponse(response)
                receivedResponse = true
                return nil
            case .line(let line):
                guard receivedResponse, !succeeded else { throw ModelDownloadError.invalidResponse }
                let update = try ModelDownloadClient.parseOllamaLine(line)
                succeeded = update.isComplete
                return update.progress
            }
        }
        func finish() throws {
            guard receivedResponse, succeeded else { throw ModelDownloadError.incompleteDownload }
        }
    }
}

/// Incremental framing avoids accumulating an entire long-lived download stream.
struct DownloadLineBuffer {
    private var data = Data()
    mutating func append(_ byte: UInt8) throws -> Data? {
        if byte == 10 {
            defer { data.removeAll(keepingCapacity: true) }
            if data.last == 13 { data.removeLast() }
            return data.isEmpty ? nil : data
        }
        guard data.count < ModelDownloadClient.maximumStatusBytes else { throw ModelDownloadError.responseTooLong }
        data.append(byte)
        return nil
    }
    mutating func finish() -> Data? {
        defer { data.removeAll(keepingCapacity: false) }
        if data.last == 13 { data.removeLast() }
        return data.isEmpty ? nil : data
    }
}
