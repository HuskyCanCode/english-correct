import XCTest
@testable import EnglishCorrectCore

final class CorrectionTargetTests: XCTestCase {
    func testNoSelectionChecksTheExactWholeField() throws {
        let input = "  i has two book.\nWe was happy.  "
        let target = try CorrectionTarget(fullText: input, selectedRange: nil)
        XCTAssertTrue(target.text.utf8.elementsEqual(input.utf8))
        XCTAssertNil(target.selectedRange)
        XCTAssertEqual(target.scopeLabel, "Entire input")
        XCTAssertEqual(try target.replacing(with: "I have two books."), "I have two books.")
    }

    func testEmptySelectionsAnywhereAtCharacterBoundariesCheckWholeField() throws {
        let input = "A 😊 sentence."
        for location in [0, 2, 4, input.utf16.count] {
            let target = try CorrectionTarget(fullText: input, selectedRange: NSRange(location: location, length: 0))
            XCTAssertEqual(target.text, input)
            XCTAssertNil(target.selectedRange)
        }
    }

    func testSelectionExcludesSurroundingContextAndPreservesItWhenReplacing() throws {
        let input = "PRIVATE PREFIX\nShe go yesterday.\nPRIVATE SUFFIX"
        let selection = (input as NSString).range(of: "She go yesterday.")
        let target = try CorrectionTarget(fullText: input, selectedRange: selection)
        XCTAssertEqual(target.text, "She go yesterday.")
        XCTAssertEqual(target.selectedRange, selection)
        XCTAssertEqual(target.scopeLabel, "Selected text")
        XCTAssertEqual(try target.replacing(with: "She went yesterday."),
                       "PRIVATE PREFIX\nShe went yesterday.\nPRIVATE SUFFIX")
    }

    func testDuplicateSentenceReplacementUsesOffsetsRatherThanSearch() throws {
        let sentence = "She go yesterday."
        let input = sentence + "\n" + sentence + "\n" + sentence
        let selection = NSRange(location: sentence.utf16.count + 1, length: sentence.utf16.count)
        let target = try CorrectionTarget(fullText: input, selectedRange: selection)
        XCTAssertEqual(try target.replacing(with: "She went yesterday."),
                       sentence + "\nShe went yesterday.\n" + sentence)
    }

    func testUnicodeSelectionAndReplacementPreserveExactSurroundingBytes() throws {
        let prefix = "Cafe\u{0301} 😊 👨‍👩‍👧‍👦\n"
        let selected = "we is here."
        let suffix = "\nCafé 🇺🇸"
        let input = prefix + selected + suffix
        let target = try CorrectionTarget(fullText: input,
                                          selectedRange: NSRange(location: prefix.utf16.count, length: selected.utf16.count))
        XCTAssertEqual(target.text, selected)
        XCTAssertTrue(try target.replacing(with: "we are here.").utf8.elementsEqual((prefix + "we are here." + suffix).utf8))
        XCTAssertTrue(target.fullText.utf8.elementsEqual(input.utf8))
    }

    func testInvalidRangesNeverFallBackToWholeInput() {
        for range in [
            NSRange(location: -1, length: 1),
            NSRange(location: 0, length: -1),
            NSRange(location: NSNotFound, length: 0),
            NSRange(location: 0, length: NSNotFound),
            NSRange(location: Int.max - 1, length: Int.max),
            NSRange(location: 9, length: 0),
            NSRange(location: 7, length: 2)
        ] {
            assertError(.invalidSelection) { try CorrectionTarget(fullText: "sentence", selectedRange: range) }
        }
    }

    func testRangesCannotSplitSurrogatesCombiningSequencesOrJoinedEmoji() {
        for (input, range) in [
            ("A😊B", NSRange(location: 2, length: 1)),
            ("A😊B", NSRange(location: 1, length: 1)),
            ("A😊B", NSRange(location: 2, length: 0)),
            ("Ae\u{0301}B", NSRange(location: 1, length: 1)),
            ("Ae\u{0301}B", NSRange(location: 2, length: 1)),
            ("Ae\u{0301}B", NSRange(location: 2, length: 0)),
            ("A👨‍👩‍👧‍👦B", NSRange(location: 1, length: 2)),
            ("A🇺🇸B", NSRange(location: 1, length: 2))
        ] {
            assertError(.invalidSelection) { try CorrectionTarget(fullText: input, selectedRange: range) }
        }
    }

    func testWholeEmojiAndCombiningCharactersCanBeSelected() throws {
        for selected in ["😊", "e\u{0301}", "👨‍👩‍👧‍👦", "🇺🇸"] {
            let target = try CorrectionTarget(fullText: "A" + selected + "B",
                                              selectedRange: NSRange(location: 1, length: selected.utf16.count))
            XCTAssertTrue(target.text.utf8.elementsEqual(selected.utf8))
            XCTAssertEqual(try target.replacing(with: "replacement"), "AreplacementB")
        }
    }

    func testSingleNonWhitespaceCharacterIsAllowedButWhitespaceIsNot() throws {
        XCTAssertEqual(try CorrectionTarget(fullText: "i", selectedRange: nil).text, "i")
        for input in ["", " \n\t", "\u{00a0}"] {
            assertError(.emptyInput) { try CorrectionTarget(fullText: input, selectedRange: nil) }
        }
        assertError(.emptyInput) {
            try CorrectionTarget(fullText: "valid    text", selectedRange: NSRange(location: 5, length: 4))
        }
    }

    func testLongFullFieldCanHaveABoundedSelection() throws {
        let input = String(repeating: "a", count: 99_990) + "i has book"
        assertError(.inputTooLong) { try CorrectionTarget(fullText: input, selectedRange: nil) }
        let target = try CorrectionTarget(fullText: input, selectedRange: NSRange(location: 99_990, length: 10))
        XCTAssertEqual(target.text, "i has book")
        XCTAssertEqual(try target.replacing(with: "I have a book.").utf16.count, 100_004)
        assertError(.fieldTooLong) {
            try CorrectionTarget(fullText: input + "x", selectedRange: NSRange(location: 99_990, length: 10))
        }
    }

    func testInputCharacterAndEncodedByteBounds() throws {
        XCTAssertEqual(try CorrectionTarget(fullText: String(repeating: "a", count: 4_000), selectedRange: nil).text.count, 4_000)
        assertError(.inputTooLong) { try CorrectionTarget(fullText: String(repeating: "a", count: 4_001), selectedRange: nil) }
        let joinedEmoji = String(repeating: "👨‍👩‍👧‍👦", count: 1_281)
        XCTAssertLessThan(joinedEmoji.count, 4_000)
        assertError(.inputTooLong) { try CorrectionTarget(fullText: joinedEmoji, selectedRange: nil) }
    }

    func testReplacementRejectsEmptyOrExcessiveOutput() throws {
        let target = try CorrectionTarget(fullText: "i", selectedRange: nil)
        for replacement in ["", " \n\t"] {
            assertError(.emptyReplacement) { try target.replacing(with: replacement) }
        }
        XCTAssertEqual(try target.replacing(with: String(repeating: "a", count: 12_000)).count, 12_000)
        assertError(.replacementTooLong) { try target.replacing(with: String(repeating: "a", count: 12_001)) }
        let pathologicalCharacter = "a" + String(repeating: "\u{0301}", count: 112_000)
        XCTAssertEqual(pathologicalCharacter.count, 1)
        assertError(.replacementTooLong) { try target.replacing(with: pathologicalCharacter) }
    }

    func testResultingWholeFieldLengthIsBounded() throws {
        let target = try CorrectionTarget(fullText: String(repeating: "a", count: 100_000),
                                          selectedRange: NSRange(location: 10, length: 1))
        XCTAssertEqual(try target.replacing(with: String(repeating: "a", count: 12_000)).utf16.count, 111_999)
        assertError(.replacementTooLong) { try target.replacing(with: String(repeating: "😊", count: 12_000)) }
    }

    func testEqualityUsesExactBytesRatherThanUnicodeCanonicalEquivalence() throws {
        let decomposed = try CorrectionTarget(fullText: "Cafe\u{0301}", selectedRange: nil)
        let composed = try CorrectionTarget(fullText: "Café", selectedRange: nil)
        XCTAssertEqual(decomposed.text, composed.text)
        XCTAssertNotEqual(decomposed, composed)
        XCTAssertEqual(decomposed, try CorrectionTarget(fullText: decomposed.fullText, selectedRange: nil))
    }

    func testReplacementOnlyProducesProposedTextAndDoesNotModifySnapshot() throws {
        let target = try CorrectionTarget(fullText: "Before. i has book. After.",
                                          selectedRange: NSRange(location: 8, length: 11))
        _ = try target.replacing(with: "I have a book.")
        XCTAssertEqual(target.text, "i has book.")
        XCTAssertEqual(target.fullText, "Before. i has book. After.")
        XCTAssertEqual(target.selectedRange, NSRange(location: 8, length: 11))
    }

    private func assertError<T>(_ expected: CorrectionTargetError, file: StaticString = #filePath,
                                line: UInt = #line, _ action: () throws -> T) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual(error as? CorrectionTargetError, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
    }
}
