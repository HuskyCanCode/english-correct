import Foundation

public enum CorrectionTargetError: Error, LocalizedError, Equatable, Sendable {
    case emptyInput
    case inputTooLong
    case fieldTooLong
    case invalidSelection
    case emptyReplacement
    case replacementTooLong

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Type some text, or select the passage you want to check."
        case .inputTooLong:
            return "Select a shorter passage to check, up to 4,000 characters."
        case .fieldTooLong:
            return "This text field is too large to check safely. Copy a shorter passage into English Correct."
        case .invalidSelection:
            return "The app could not read that selection safely. Select the text again and retry the shortcut."
        case .emptyReplacement:
            return "The model returned an empty suggestion. Your text has not been changed."
        case .replacementTooLong:
            return "The model’s suggestion was unexpectedly long. Your text has not been changed."
        }
    }
}

/// An immutable snapshot of the text explicitly requested for correction.
/// Selection offsets use macOS Accessibility's UTF-16 convention. This value
/// performs no reads or writes; the caller must verify its snapshot before applying.
public struct CorrectionTarget: Equatable, Sendable {
    public let fullText: String
    public let text: String
    public let selectedRange: NSRange?

    public var scopeLabel: String { selectedRange == nil ? "Entire input" : "Selected text" }

    public init(fullText: String, selectedRange: NSRange?) throws {
        let fieldLength = fullText.utf16.count
        guard fieldLength <= 100_000 else { throw CorrectionTargetError.fieldTooLong }

        let activeRange: NSRange?
        let text: String
        if let selectedRange {
            // Check each operand before adding: malformed Accessibility ranges
            // must never overflow or silently fall back to checking the full field.
            guard selectedRange.location != NSNotFound,
                  selectedRange.location >= 0, selectedRange.length >= 0,
                  selectedRange.location <= fieldLength,
                  selectedRange.length <= fieldLength - selectedRange.location,
                  let range = Range(selectedRange, in: fullText),
                  Self.isCharacterBoundary(range.lowerBound, in: fullText),
                  Self.isCharacterBoundary(range.upperBound, in: fullText) else {
                throw CorrectionTargetError.invalidSelection
            }
            activeRange = selectedRange.length == 0 ? nil : selectedRange
            text = selectedRange.length == 0 ? fullText : String(fullText[range])
        } else {
            activeRange = nil
            text = fullText
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CorrectionTargetError.emptyInput
        }
        guard text.count <= 4_000, text.utf8.count <= 32_000 else {
            throw CorrectionTargetError.inputTooLong
        }

        self.fullText = fullText
        self.text = text
        self.selectedRange = activeRange
    }

    /// Produces the proposed whole-field value without mutating the snapshot.
    /// The returned string retains all bytes outside the exact selected offsets.
    public func replacing(with replacement: String) throws -> String {
        guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CorrectionTargetError.emptyReplacement
        }
        guard replacement.count <= 12_000 else { throw CorrectionTargetError.replacementTooLong }
        let retainedLength = fullText.utf16.count - (selectedRange?.length ?? fullText.utf16.count)
        // Subtract the bounded retained length instead of adding potentially
        // large lengths, including pathological combining-character output.
        guard replacement.utf16.count <= 112_000 - retainedLength else {
            throw CorrectionTargetError.replacementTooLong
        }
        guard let selectedRange else { return replacement }
        guard let range = Range(selectedRange, in: fullText) else {
            throw CorrectionTargetError.invalidSelection
        }
        return String(fullText[..<range.lowerBound]) + replacement + String(fullText[range.upperBound...])
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedRange == rhs.selectedRange
            && lhs.fullText.utf8.elementsEqual(rhs.fullText.utf8)
            && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }

    private static func isCharacterBoundary(_ index: String.Index, in text: String) -> Bool {
        index == text.endIndex || text.indices.contains(index)
    }
}
