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
            return "Writing style: Slang. Rewrite with natural, playful idioms where they fit. Use full words, not texting abbreviations. Preserve all details. If no idiom fits, leave the text alone. Do not add profanity or stereotypes."
        }
    }

    var examples: [WritingStyleExample] {
        guard self == .slang else { return [] }
        return [
            WritingStyleExample(original: "Let me think.", corrected: "Let me noodle on it.", explanation: "Used a playful idiom for thinking."),
            WritingStyleExample(original: "I am very busy today.", corrected: "I'm swamped today.", explanation: "Used a colloquial idiom for being busy."),
            WritingStyleExample(original: "The noodles are in the soup.", corrected: "The noodles are in the soup.", explanation: "No fitting idiom; preserved literal details.")
        ]
    }

}

struct WritingStyleExample: Sendable {
    let original: String
    let corrected: String
    let explanation: String
}
