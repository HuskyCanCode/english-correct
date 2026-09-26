import Foundation
import EnglishCorrectCore

enum SetupAIState: Equatable, Sendable {
    case unchecked
    case checking
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
    var isChecking: Bool { self == .checking }

    var message: String {
        switch self {
        case .unchecked: return "Check your local model before using English Correct."
        case .checking: return "Checking your local model with a sample sentence…"
        case .ready: return "Your local model passed the writing check."
        case .failed(let message): return message
        }
    }
}

enum SetupReadiness {
    static let sample = "She don't like apples."

    static func containsSelectedModel(_ configuration: LocalAIConfiguration, in models: [String]) -> Bool {
        if configuration.provider != .ollama { return models.contains(configuration.model) }
        func canonical(_ name: String) -> String {
            let lastComponent = name.split(separator: "/").last ?? ""
            return lastComponent.contains(":") ? name : name + ":latest"
        }
        return models.contains { canonical($0) == canonical(configuration.model) }
    }

    static func validates(_ correction: Correction) -> Bool {
        guard correction.original.utf8.elementsEqual(sample.utf8), correction.hasChanges else { return false }
        let corrected = correction.corrected
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        return ["she doesn't like apples.", "she doesn't like apples",
                "she does not like apples.", "she does not like apples"].contains(corrected)
    }
}
