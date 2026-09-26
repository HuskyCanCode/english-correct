import Foundation

extension Correction {
    /// A factual description of the proposed edit, independent of the model's explanation.
    public var editSummary: String {
        guard !original.utf8.elementsEqual(corrected.utf8) else { return "No changes suggested." }

        let originalWithoutSpacing = original.filter { !$0.isWhitespace }
        let correctedWithoutSpacing = corrected.filter { !$0.isWhitespace }
        if originalWithoutSpacing.utf8.elementsEqual(correctedWithoutSpacing.utf8) {
            return "Spacing changed."
        }

        let before = original.split(whereSeparator: { $0.isWhitespace })
        let after = corrected.split(whereSeparator: { $0.isWhitespace })
        var prefix = 0
        while prefix < min(before.count, after.count),
              before[prefix].utf8.elementsEqual(after[prefix].utf8) {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - suffix - 1].utf8.elementsEqual(after[after.count - suffix - 1].utf8) {
            suffix += 1
        }

        func changedSpan(in text: String, words: [Substring]) -> String {
            let end = words.count - suffix
            guard prefix < end else { return "" }
            return String(text[words[prefix].startIndex..<words[end - 1].endIndex])
        }
        let old = changedSpan(in: original, words: before)
        let new = changedSpan(in: corrected, words: after)
        guard old.count <= 80, new.count <= 80 else {
            return "Review the proposed changes before applying."
        }
        if old.isEmpty { return "Added “\(new)”" }
        if new.isEmpty { return "Removed “\(old)”" }
        return "“\(old)” → “\(new)”"
    }
}
