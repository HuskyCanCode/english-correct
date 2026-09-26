import Foundation
import CryptoKit
import EnglishCorrectCore

struct BuiltInModelFile: Sendable {
    let name: String
    let url: URL
    let bytes: Int64
    let sha256: String
}

enum BuiltInModelError: Error, LocalizedError {
    case unknownModel, damagedDownload, unsafePath, busy, missingModel
    var errorDescription: String? {
        switch self {
        case .unknownModel: return "Choose Fast or Pro from Models."
        case .damagedDownload: return "The model download could not be verified. Choose Download to try again."
        case .unsafePath: return "The model folder is not a regular app-owned folder. Check its location in Application Support."
        case .busy: return "Wait for the current model operation to finish."
        case .missingModel: return "Download this model in Models before using it."
        }
    }
}

actor BuiltInModelStore {
    static let shared = BuiltInModelStore()
    typealias Progress = @Sendable (ModelDownloadProgress) async -> Void
    typealias Downloader = @Sendable (URL, @escaping Progress) async throws -> URL
    let root: URL
    private let catalog: [String: [BuiltInModelFile]]
    private let downloader: Downloader
    private var active = Set<String>()
    private var verified: [String: [Date]] = [:]

    static let catalog: [String: [BuiltInModelFile]] = {
        func file(_ size: String, _ revision: String, _ name: String, _ bytes: Int64, _ hash: String) -> BuiltInModelFile {
            BuiltInModelFile(name: name, url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-\(size)-Instruct-GGUF/resolve/\(revision)/\(name)")!, bytes: bytes, sha256: hash)
        }
        return [
            "fast": [file("1.5B", "91cad51170dc346986eccefdc2dd33a9da36ead9", "qwen2.5-1.5b-instruct-q4_k_m.gguf", 1_117_320_736, "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e")],
            "pro": [file("7B", "bb5d59e06d9551d752d08b292a50eb208b07ab1f", "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf", 3_993_201_344, "dfce12e3862a5283ccfb88221b48480e58745165de856439950d0f22590580db"),
                    file("7B", "bb5d59e06d9551d752d08b292a50eb208b07ab1f", "qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf", 689_872_288, "539cf93f78e887edea1c04e2d7d8cdaca9d01dae9c9025bcb8accbe29df3d72a")]
        ]
    }()

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/English Correct/Models"),
         catalog: [String: [BuiltInModelFile]] = BuiltInModelStore.catalog,
         downloader: @escaping Downloader = { url, progress in try await BuiltInModelStore.fetch(url, progress: progress) }) {
        self.root = root.standardizedFileURL
        self.catalog = catalog
        self.downloader = downloader
    }

    func installedModelIDs() async throws -> [String] {
        try ensureRoot()
        var result: [String] = []
        for id in catalog.keys.sorted() where !active.contains(id) {
            if (try? await modelURL(for: id)) != nil { result.append(id) }
        }
        return result
    }

    func modelURL(for id: String) async throws -> URL {
        let files = try files(for: id)
        try ensureRoot()
        let directory = root.appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("complete.json").path) else { throw BuiltInModelError.missingModel }
        try safe(directory)
        var stamps: [Date] = []
        for file in files {
            let url = directory.appendingPathComponent(file.name)
            try safe(url)
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard info.isRegularFile == true, Int64(info.fileSize ?? -1) == file.bytes,
                  let date = info.contentModificationDate else { throw BuiltInModelError.damagedDownload }
            stamps.append(date)
        }
        if verified[id] != stamps {
            for file in files { try await Self.verify(directory.appendingPathComponent(file.name), file: file) }
            verified[id] = stamps
        }
        return directory.appendingPathComponent(files[0].name)
    }

    func download(_ id: String, progress: @escaping Progress) async throws {
        let files = try files(for: id)
        guard active.insert(id).inserted else { throw BuiltInModelError.busy }
        defer { active.remove(id) }
        try ensureRoot()
        let directory = root.appendingPathComponent(id)
        try safe(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        verified[id] = nil
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        var finished: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let target = directory.appendingPathComponent(file.name)
            try safe(target)
            if (try? await Self.verify(target, file: file)) == nil {
                let prior = finished
                let temporary = try await downloader(file.url) { update in
                    await progress(ModelDownloadProgress(status: "Downloading model", completedBytes: prior + min(update.completedBytes ?? 0, file.bytes), totalBytes: total))
                }
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                await progress(ModelDownloadProgress(status: "Verifying model files…", completedBytes: finished + file.bytes, totalBytes: total))
                try await Self.verify(temporary, file: file)
                try Task.checkCancellation()
                try safe(target)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: temporary, to: target)
            }
            finished += file.bytes
        }
        try Task.checkCancellation()
        let receipt = directory.appendingPathComponent("complete.json")
        try safe(receipt)
        try JSONEncoder().encode(files.map(\.sha256)).write(to: receipt, options: .atomic)
        await progress(ModelDownloadProgress(status: "Downloaded", completedBytes: total, totalBytes: total))
    }

    func delete(_ id: String) throws {
        _ = try files(for: id)
        guard !active.contains(id) else { throw BuiltInModelError.busy }
        try ensureRoot()
        let directory = root.appendingPathComponent(id)
        try safe(directory)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        verified[id] = nil
    }

    private func files(for id: String) throws -> [BuiltInModelFile] {
        guard ["fast", "pro"].contains(id), let files = catalog[id], !files.isEmpty else { throw BuiltInModelError.unknownModel }
        return files
    }
    private func ensureRoot() throws {
        guard root.resolvingSymlinksInPath().path == root.path else { throw BuiltInModelError.unsafePath }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    private func safe(_ url: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(root.path + "/"),
              url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw BuiltInModelError.unsafePath }
    }
    private static func verify(_ url: URL, file: BuiltInModelFile) async throws {
        let task = Task.detached(priority: .utility) {
            let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard info.isRegularFile == true, Int64(info.fileSize ?? -1) == file.bytes else { throw BuiltInModelError.damagedDownload }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard try handle.read(upToCount: 4) == Data("GGUF".utf8) else { throw BuiltInModelError.damagedDownload }
            try handle.seek(toOffset: 0)
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                hash.update(data: chunk)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw BuiltInModelError.damagedDownload }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func fetch(_ url: URL, progress: @escaping Progress) async throws -> URL {
        let delegate = ModelTransferDelegate(progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 86_400
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: url, delegate: delegate)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw BuiltInModelError.damagedDownload }
        return temporary
    }
}

private final class ModelTransferDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: BuiltInModelStore.Progress
    private let progressLock = NSLock()
    private var lastProgress = Date.distantPast
    init(progress: @escaping BuiltInModelStore.Progress) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressLock.lock()
        let now = Date()
        let shouldReport = now.timeIntervalSince(lastProgress) >= 0.15 || totalBytesWritten == totalBytesExpectedToWrite
        if shouldReport { lastProgress = now }
        progressLock.unlock()
        guard shouldReport else { return }
        Task { await progress(ModelDownloadProgress(status: "Downloading model", completedBytes: totalBytesWritten, totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host?.lowercased() ?? ""
        let permitted = request.url?.scheme == "https" && (host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co"))
        completionHandler(permitted ? request : nil)
    }
}
