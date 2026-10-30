import Foundation

public enum WritingStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case formal
    case casual
    case slang

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .slang: return "Slang"
        }
    }

    var instruction: String {
        switch self {
        case .formal:
            return "Writing style: Formal. Rewrite the supplied text in formal, professional English. Remove casual greetings, slang and texting abbreviations."
        case .casual:
            return "Writing style: Casual. Correct the supplied text in natural everyday English with a friendly, conversational tone. Contractions are welcome; do not add slang."
        case .slang:
            return "Writing style: Slang. Rewrite the supplied text in relaxed conversational English with light, common slang where it fits. Do not add profanity or stereotypes."
        }
    }
}
