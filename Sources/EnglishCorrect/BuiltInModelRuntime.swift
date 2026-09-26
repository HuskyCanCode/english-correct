import Foundation
import Darwin
import EnglishCorrectCore

@MainActor
final class BuiltInModelRuntime {
    static let shared = BuiltInModelRuntime()
    private let executable: URL
    private var process: Process?
    private var loadedID: String?
    private var readyConfiguration: LocalAIConfiguration?
    private var loading: Task<LocalAIConfiguration, Error>?
    private var generation = UUID()

    init(executable: URL? = nil) {
        self.executable = executable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/LocalEngine/llama-server")
    }
    func checkBundledEngine() throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw RuntimeError.missingEngine }
    }
    func ensureLoaded(modelID: String, modelURL: URL) async throws -> LocalAIConfiguration {
        try checkBundledEngine()
        if loadedID == modelID, let process, process.isRunning {
            if let readyConfiguration { return readyConfiguration }
            if let loading { return try await loading.value }
        }
        shutdown()
        let epoch = UUID(); generation = epoch
        let port = try Self.availablePort()
        let key = UUID().uuidString + UUID().uuidString
        let config = LocalAIConfiguration(provider: .builtIn, baseURL: "http://127.0.0.1:\(port)", model: modelID, apiKey: key)
        let child = Process()
        child.executableURL = executable
        child.arguments = Self.arguments(modelID: modelID, modelURL: modelURL, port: port)
        // Do not inherit provider/network/tool options from a shell environment.
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                             "LLAMA_API_KEY": key]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child; loadedID = modelID
        let task = Task { () throws -> LocalAIConfiguration in
            do {
                let deadline = Date().addingTimeInterval(120)
                while Date() < deadline {
                    try Task.checkCancellation()
                    guard self.generation == epoch, child.isRunning else { throw RuntimeError.startFailed }
                    if let models = try? await LocalAIClient(configuration: config).models(), models.contains(modelID) {
                        guard self.generation == epoch, child.isRunning else { throw CancellationError() }
                        self.readyConfiguration = config
                        return config
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                throw RuntimeError.startFailed
            } catch {
                if self.generation == epoch { self.shutdown() }
                throw error
            }
        }
        loading = task
        return try await task.value
    }
    func shutdown() {
        generation = UUID()
        loading?.cancel(); loading = nil
        readyConfiguration = nil; loadedID = nil
        if let child = process, child.isRunning {
            child.terminate()
            // The Process object retains ownership; never signal a discovered external PID.
            Task.detached {
                for _ in 0..<20 {
                    if !child.isRunning { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        process = nil
    }
    static func arguments(modelID: String, modelURL: URL, port: UInt16) -> [String] {
        ["--model", modelURL.path, "--alias", modelID, "--host", "127.0.0.1", "--port", String(port),
         "--ctx-size", "8192", "--parallel", "1", "--n-gpu-layers", "99", "--no-webui", "--log-disable"]
    }
    private static func availablePort() throws -> UInt16 {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw RuntimeError.startFailed }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw RuntimeError.startFailed }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &size) }
        }
        guard result == 0 else { throw RuntimeError.startFailed }
        return UInt16(bigEndian: address.sin_port)
    }
    enum RuntimeError: Error, LocalizedError {
        case missingEngine, startFailed
        var errorDescription: String? {
            switch self {
            case .missingEngine: return "The built-in engine is missing. Install the latest complete English Correct app."
            case .startFailed: return "The model could not start. Close other memory-heavy apps, then try Fast again."
            }
        }
    }
}

@MainActor
enum BuiltInAI {
    static func models(_ config: LocalAIConfiguration) async throws -> [String] {
        try BuiltInModelRuntime.shared.checkBundledEngine()
        return try await BuiltInModelStore.shared.installedModelIDs()
    }
    static func correct(_ text: String, configuration: LocalAIConfiguration) async throws -> Correction {
        let url = try await BuiltInModelStore.shared.modelURL(for: configuration.model)
        try Task.checkCancellation()
        let config = try await BuiltInModelRuntime.shared.ensureLoaded(modelID: configuration.model, modelURL: url)
        try Task.checkCancellation()
        return try await LocalAIClient(configuration: config).correct(text)
    }
}
