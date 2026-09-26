import Foundation
import SwiftUI
import XCTest
import EnglishCorrectCore
@testable import EnglishCorrect

final class CorrectionHighlightingTests: XCTestCase {
    private func highlights(_ value: AttributedString) -> [String] {
        value.runs.compactMap { run in
            guard run.backgroundColor != nil else { return nil }
            return String(value[run.range].characters)
        }
    }

    private func assertExactTextAndCompleteStyles(_ value: AttributedString, expected: String,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(String(value.characters).utf8), Array(expected.utf8),
                       "Highlighting must preserve every byte used by Copy and Apply", file: file, line: line)
        for run in value.runs {
            if run.backgroundColor != nil {
                XCTAssertEqual(run.backgroundColor, CorrectionHighlighting.background, file: file, line: line)
                XCTAssertEqual(run.foregroundColor, CorrectionHighlighting.foreground, file: file, line: line)
                XCTAssertEqual(run.underlineStyle, .single, file: file, line: line)
            } else {
                XCTAssertNil(run.foregroundColor, "Unchanged text must retain ordinary styling", file: file, line: line)
                XCTAssertNil(run.underlineStyle, file: file, line: line)
            }
        }
    }

    func testDistantChangedWordsAreHighlightedWithoutMarkingTheWordsBetween() {
        let correction = Correction(original: "She go to work and he have a car.",
                                    corrected: "She goes to work and he has a car.", explanation: "")
        let rendered = CorrectionHighlighting.correctedText(for: correction)
        assertExactTextAndCompleteStyles(rendered, expected: correction.corrected)
        XCTAssertEqual(highlights(rendered), ["goes", "has"])
        let ordinary = rendered.runs.filter { $0.backgroundColor == nil }.map { String(rendered[$0.range].characters) }
        XCTAssertTrue(ordinary.contains(" to work and he "))
    }

    func testPunctuationOnlyChangeDoesNotHighlightTheWholeSentence() {
        let correction = Correction(original: "Hello world", corrected: "Hello, world!", explanation: "")
        let rendered = CorrectionHighlighting.correctedText(for: correction)
        assertExactTextAndCompleteStyles(rendered, expected: correction.corrected)
        XCTAssertEqual(highlights(rendered), [",", "!"])
    }

    func testUnicodeAndDecomposedAccentsArePreservedAroundAnEdit() {
        let correction = Correction(original: "👩🏽‍💻 Zoe\u{301} have a café.",
                                    corrected: "👩🏽‍💻 Zoe\u{301} has a café.", explanation: "")
        let rendered = CorrectionHighlighting.correctedText(for: correction)
        assertExactTextAndCompleteStyles(rendered, expected: correction.corrected)
        XCTAssertEqual(highlights(rendered), ["has"])
    }

    func testChangedEmojiIsOneCompleteHighlightedGrapheme() {
        let correction = Correction(original: "That is 👩🏽‍💻.", corrected: "That is 🧑🏽‍💻.", explanation: "")
        let rendered = CorrectionHighlighting.correctedText(for: correction)
        assertExactTextAndCompleteStyles(rendered, expected: correction.corrected)
        XCTAssertEqual(highlights(rendered), ["🧑🏽‍💻"])
        XCTAssertEqual(highlights(rendered).first?.count, 1)
    }

    func testDeletionOnlyKeepsTheSurvivingTextUnmarked() {
        let correction = Correction(original: "Please please send the report today.",
                                    corrected: "Please send the report today.", explanation: "")
        let rendered = CorrectionHighlighting.correctedText(for: correction)
        assertExactTextAndCompleteStyles(rendered, expected: correction.corrected)
        XCTAssertTrue(highlights(rendered).isEmpty)
    }

    func testIdenticalTextHasNoHighlightAttributes() {
        let text = "A clear sentence.\n\nThanks!"
        let rendered = CorrectionHighlighting.correctedText(for: Correction(original: text, corrected: text, explanation: ""))
        assertExactTextAndCompleteStyles(rendered, expected: text)
        XCTAssertTrue(highlights(rendered).isEmpty)
    }
}
