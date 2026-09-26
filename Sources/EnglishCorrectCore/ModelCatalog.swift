import Foundation

public struct RecommendedModel: Identifiable, Sendable {
    public let id: String
    public let tier: String
    public let name: String
    public let summary: String
    public let recommendedMemoryGB: Int
    public let lmStudioBytes: Int64
    public let ollamaBytes: Int64
    public let sourceURL: URL
    public let licenseURL: URL
    private let parameterSize: String

    public var downloadSpec: DownloadSpec {
        DownloadSpec(catalogID: id, lmStudioRepository: sourceURL.absoluteString,
                     quantization: "Q4_K_M", ollamaModel: "qwen2.5:\(parameterSize)-instruct-q4_K_M")
    }

    public func downloadBytes(for provider: LocalProvider) -> Int64 {
        provider != .ollama ? lmStudioBytes : ollamaBytes
    }

    /// Return the server's original identifier only for a recognized equivalent model.
    /// Exact forms avoid mistaking a coder, base, adapter, or different quantization
    /// for the recommended instruction model merely because its name contains ours.
    public func installedID(in identifiers: [String], provider: LocalProvider) -> String? {
        switch provider {
        case .builtIn: return identifiers.first { $0 == id }
        case .ollama:
            let explicit = "qwen2.5:\(parameterSize)-instruct-q4_k_m"
            let aliases = [explicit, "qwen2.5:\(parameterSize)"]
            for alias in aliases {
                if let match = identifiers.first(where: { $0.lowercased() == alias }) { return match }
            }
            return nil
        case .lmStudio:
            return identifiers.first(where: matchesLMStudioIdentifier)
        }
    }

    private func matchesLMStudioIdentifier(_ identifier: String) -> Bool {
        let stem = "qwen2.5-\(parameterSize)-instruct"
        let parts = identifier.lowercased().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let publishers: Set<String> = ["qwen", "lmstudio-community"]
        let repositories: Set<String> = [stem, stem + "-gguf"]
        let bareNames: Set<String> = [
            stem, stem + "-gguf", stem + "-q4_k_m", stem + ".q4_k_m",
            stem + "@q4_k_m", stem + "-gguf@q4_k_m",
            stem + ".gguf", stem + "-q4_k_m.gguf", stem + ".q4_k_m.gguf"
        ]
        // The official 7B download is sharded. Only the entry shard is a loadable ID.
        let fileNames = bareNames.union(parameterSize == "7b" ? [stem + "-q4_k_m-00001-of-00002.gguf"] : [])
        switch parts.count {
        case 1:
            return fileNames.contains(parts[0])
        case 2:
            return publishers.contains(parts[0]) && fileNames.contains(parts[1])
                || repositories.contains(parts[0]) && fileNames.contains(parts[1])
        case 3:
            return publishers.contains(parts[0]) && repositories.contains(parts[1]) && fileNames.contains(parts[2])
        default:
            return false
        }
    }

    fileprivate init(id: String, tier: String, name: String, summary: String,
                     parameterSize: String, recommendedMemoryGB: Int,
                     lmStudioBytes: Int64, ollamaBytes: Int64) {
        self.id = id
        self.tier = tier
        self.name = name
        self.summary = summary
        self.parameterSize = parameterSize
        self.recommendedMemoryGB = recommendedMemoryGB
        self.lmStudioBytes = lmStudioBytes
        self.ollamaBytes = ollamaBytes
        self.sourceURL = URL(string: "https://huggingface.co/Qwen/Qwen2.5-\(parameterSize.uppercased())-Instruct-GGUF")!
        self.licenseURL = sourceURL.appendingPathComponent("blob/main/LICENSE")
    }
}

public enum ModelCatalog {
    // GGUF byte counts are from the official Qwen Hugging Face repositories.
    // Ollama sizes are rounded estimates from its corresponding library tags.
    // Memory figures are our conservative Mac recommendations, not vendor minimums.
    public static let recommendations: [RecommendedModel] = [
        RecommendedModel(
            id: "fast", tier: "Fast", name: "Qwen2.5 1.5B Instruct",
            summary: "Small download for quick, everyday corrections. Start here for short messages.",
            parameterSize: "1.5b", recommendedMemoryGB: 8,
            lmStudioBytes: 1_117_320_736, ollamaBytes: 986_000_000
        ),
        RecommendedModel(
            id: "pro", tier: "Pro", name: "Qwen2.5 7B Instruct",
            summary: "A larger model for more demanding writing. Uses more memory and may respond more slowly.",
            parameterSize: "7b", recommendedMemoryGB: 16,
            lmStudioBytes: 4_683_073_632, ollamaBytes: 4_700_000_000
        )
    ]
}
