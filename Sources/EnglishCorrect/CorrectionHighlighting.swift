import Foundation
import SwiftUI
import EnglishCorrectCore

/// Styling is presentation-only: Copy and Apply continue to use the exact
/// corrected string, with no markup, annotation, or extra characters.
enum CorrectionHighlighting {
    static let foreground = Color(red: 0.08, green: 0.34, blue: 0.22)
    static let background = Color(red: 0.80, green: 0.93, blue: 0.84)

    static func correctedText(for correction: Correction) -> AttributedString {
        var result = AttributedString(correction.corrected)
        for range in correction.changeHighlights.correctedRanges {
            guard let stringRange = Range(range, in: correction.corrected),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: result),
                  let upper = AttributedString.Index(stringRange.upperBound, within: result) else { continue }
            result[lower..<upper].foregroundColor = foreground
            result[lower..<upper].backgroundColor = background
            result[lower..<upper].underlineStyle = .single
        }
        return result
    }
}
