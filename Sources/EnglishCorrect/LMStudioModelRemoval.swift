import Foundation
import EnglishCorrectCore

/// LM Studio has no public delete endpoint. Only the exact official catalog
/// GGUF files are eligible here; arbitrary model IDs never become file paths.
@MainActor
struct LMStudioModelRemoval {
    typealias Unload = (String, DownloadSpec, LocalAIConfiguration) async throws -> [String]
    typealias Trash = (URL) throws -> Void

    private let fileManager = FileManager.default
    private let rootOverride: URL?
    private let settingsURL: URL
    private let fallbackRoot: URL
    private let unload: Unload
    private let trash: Trash

    init(root: URL? = nil, settingsURL: URL? = nil, fallbackRoot: URL? = nil,
         unload: @escaping Unload = { id, spec, config in
             try await ModelDownloadClient(configuration: config).unloadLMStudioModelForDeletion(id, spec: spec)
         }, trash: @escaping Trash = { url in
             try FileManager.default.trashItem(at: url, resultingItemURL: nil)
         }) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.rootOverride = root
        self.settingsURL = settingsURL ?? home.appendingPathComponent(".lmstudio/settings.json")
        self.fallbackRoot = fallbackRoot ?? home.appendingPathComponent(".lmstudio/models", isDirectory: true)
        self.unload = unload
        self.trash = trash
    }

    @discardableResult
    func remove(_ modelID: String, spec: DownloadSpec, configuration: LocalAIConfiguration) async throws -> [String] {
        try Task.checkCancellation()
        guard configuration.provider == .lmStudio,
              let item = ModelCatalog.recommendations.first(where: { $0.downloadSpec == spec }),
              ["fast", "pro"].contains(item.id),
              item.installedID(in: [modelID], provider: .lmStudio) == modelID,
              !modelID.lowercased().hasPrefix("lmstudio-community/") else {
            throw LMStudioRemovalError.unsupportedModel
        }
        let root = try modelRoot()
        let size = item.id == "fast" ? "1.5" : "7"
        let repository = root.appendingPathComponent("Qwen/Qwen2.5-\(size)B-Instruct-GGUF", isDirectory: true)
        let stem = "qwen2.5-\(size)b-instruct-q4_k_m"
        let names = item.id == "fast" ? [stem + ".gguf"] : [stem + "-00001-of-00002.gguf", stem + "-00002-of-00002.gguf"]
        let files = names.map { repository.appendingPathComponent($0) }
        let originals = try files.map { try fingerprint($0, under: root) }

        // Validate the live provider's exact model identity and unload all its
        // instances before touching disk. This also enforces loopback-only URLs.
        let unloadedInstances = try await unload(modelID, spec, configuration)
        try Task.checkCancellation()
        guard try modelRoot() == root else { throw LMStudioRemovalError.changedFiles }
        guard try files.map({ try fingerprint($0, under: root) }) == originals else {
            throw LMStudioRemovalError.changedFiles
        }

        var removed = 0
        do {
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                guard try fingerprint(file, under: root) == originals[index] else {
                    throw LMStudioRemovalError.changedFiles
                }
                try trash(file)
                guard !fileManager.fileExists(atPath: file.path) else { throw LMStudioRemovalError.trashFailed }
                removed += 1
            }
        } catch {
            if removed > 0 { throw LMStudioRemovalError.partiallyRemoved }
            if let known = error as? LMStudioRemovalError { throw known }
            if error is CancellationError { throw error }
            throw LMStudioRemovalError.trashFailed
        }
        return [modelID] + unloadedInstances
    }

    private func modelRoot() throws -> URL {
        let root: URL
        if let rootOverride { root = rootOverride }
        else if fileManager.fileExists(atPath: settingsURL.path) {
            guard let size = try fileManager.attributesOfItem(atPath: settingsURL.path)[.size] as? NSNumber,
                  size.intValue <= 1_048_576,
                  let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any] else {
                throw LMStudioRemovalError.unknownFolder
            }
            if let value = object["downloadsFolder"] {
                guard let path = value as? String, path.hasPrefix("/"),
                      path.rangeOfCharacter(from: .controlCharacters) == nil else {
                    throw LMStudioRemovalError.unknownFolder
                }
                root = URL(fileURLWithPath: path, isDirectory: true)
            } else { root = fallbackRoot }
        } else { root = fallbackRoot }
        let normalized = root.standardizedFileURL
        guard normalized.isFileURL, normalized.path != "/",
              normalized.resolvingSymlinksInPath().path == normalized.path,
              (try? fileManager.attributesOfItem(atPath: normalized.path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw LMStudioRemovalError.unknownFolder
        }
        return normalized
    }

    private struct Fingerprint: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }

    private func fingerprint(_ file: URL, under root: URL) throws -> Fingerprint {
        let normalized = file.standardizedFileURL
        guard normalized.path.hasPrefix(root.path + "/"),
              normalized.resolvingSymlinksInPath().path == normalized.path else {
            throw LMStudioRemovalError.unsafeFile
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: normalized.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber, size.uint64Value >= 4,
              let modified = attributes[.modificationDate] as? Date else {
            throw LMStudioRemovalError.missingFiles
        }
        let handle = try FileHandle(forReadingFrom: normalized)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("GGUF".utf8) else {
            throw LMStudioRemovalError.unsafeFile
        }
        return Fingerprint(device: device.uint64Value, inode: inode.uint64Value,
                           size: size.uint64Value, modified: modified)
    }
}

enum LMStudioRemovalError: Error, LocalizedError, Equatable {
    case unsupportedModel, unknownFolder, missingFiles, unsafeFile, changedFiles, trashFailed, partiallyRemoved

    var errorDescription: String? {
        switch self {
        case .unsupportedModel: return "This copy cannot be identified safely. Delete it from LM Studio’s My Models screen, then Refresh here."
        case .unknownFolder: return "Could not safely locate LM Studio’s model folder. Delete the model in LM Studio, then Refresh here."
        case .missingFiles: return "The expected model files were not found, or the download is incomplete. Manage this model in LM Studio, then Refresh here."
        case .unsafeFile: return "The model files could not be verified safely. Delete this copy in LM Studio, then Refresh here."
        case .changedFiles: return "The model files changed during deletion. Nothing further was removed. Refresh and try again."
        case .trashFailed: return "Could not move the model to Trash. Check the model folder’s permissions or delete it in LM Studio. You may need to choose Use again to reload it."
        case .partiallyRemoved: return "Some model files moved to Trash, but others could not be removed. Restore those files from Trash or finish removing this model in LM Studio, then Refresh here."
        }
    }
}
