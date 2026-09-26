import XCTest
@testable import EnglishCorrectCore

final class CorrectionDiffTests: XCTestCase {
    private func correction(_ original: String, _ corrected: String) -> Correction {
        Correction(original: original, corrected: corrected, explanation: "Unused explanation.")
    }

    private func fragments(_ text: String, _ ranges: [NSRange]) -> [String] {
        ranges.map { (text as NSString).substring(with: $0) }
    }

    private func check(_ original: String, _ corrected: String,
                       removed: [String], added: [String],
                       file: StaticString = #filePath, line: UInt = #line) {
        let result = correction(original, corrected).changeHighlights
        XCTAssertEqual(fragments(original, result.originalRanges), removed, file: file, line: line)
        XCTAssertEqual(fragments(corrected, result.correctedRanges), added, file: file, line: line)
        verifyExactUnchangedText(original, corrected, result, file: file, line: line)
    }

    private func verifyExactUnchangedText(_ original: String, _ corrected: String,
                                         _ highlights: CorrectionChangeHighlights,
                                         file: StaticString = #filePath, line: UInt = #line) {
        func unchanged(_ text: String, _ ranges: [NSRange]) -> String {
            let boundaries = Set(text.indices).union([text.endIndex])
            var offset = text.startIndex
            var result = ""
            for range in ranges {
                guard let swiftRange = Range(range, in: text) else {
                    XCTFail("Invalid UTF-16 range: \(range)", file: file, line: line)
                    continue
                }
                XCTAssertTrue(range.length > 0, file: file, line: line)
                XCTAssertTrue(boundaries.contains(swiftRange.lowerBound), file: file, line: line)
                XCTAssertTrue(boundaries.contains(swiftRange.upperBound), file: file, line: line)
                XCTAssertGreaterThanOrEqual(swiftRange.lowerBound, offset, file: file, line: line)
                result += text[offset..<swiftRange.lowerBound]
                offset = swiftRange.upperBound
            }
            result += text[offset...]
            return result
        }
        let oldUnchanged = unchanged(original, highlights.originalRanges)
        let newUnchanged = unchanged(corrected, highlights.correctedRanges)
        XCTAssertTrue(oldUnchanged.utf8.elementsEqual(newUnchanged.utf8),
                      "Unchanged spans must retain the same exact bytes.", file: file, line: line)
        XCTAssertEqual(highlights.hasChanges, !original.utf8.elementsEqual(corrected.utf8), file: file, line: line)
    }

    func testHighlightsWholeReplacementWords() {
        check("I has this photo.", "I have this photo.", removed: ["has"], added: ["have"])
        check("He don't know.", "He doesn't know.", removed: ["don't"], added: ["doesn't"])
        check("He don’t know.", "He doesn’t know.", removed: ["don’t"], added: ["doesn’t"])
    }

    func testKeepsUnchangedWordsBetweenDistantEditsClear() {
        check("We was very happy with this results.", "We were very happy with these results.",
              removed: ["was", "this"], added: ["were", "these"])
        check("I has a book and she have a pen.", "I have a book and she has a pen.",
              removed: ["has", "have"], added: ["have", "has"])
    }

    func testInsertionAndDeletionLeaveExistingWordsClear() {
        check("I like books.", "I really like books.", removed: [], added: ["really "])
        check("I really like books.", "I like books.", removed: ["really "], added: [])
        check("Hello world", "Dear Hello world today", removed: [], added: ["Dear ", " today"])
        check("", "Hello!", removed: [], added: ["Hello!"])
        check("Goodbye!", "", removed: ["Goodbye!"], added: [])
    }

    func testPunctuationIsSeparateFromUnchangedWords() {
        check("Hello, world!", "Hello world.", removed: [",", "!"], added: ["."])
        check("Hello world", "Hello world!", removed: [], added: ["!"])
        check("The 'word' matters.", "The “word” matters.", removed: ["'", "'"], added: ["“", "”"])
    }

    func testRepeatedWordsAlignWithTheirSurroundings() {
        check("I had had enough, but he have had enough.", "I had enough, but he has had enough.",
              removed: ["had ", "have"], added: ["has"])
        check("the cat and the cat and the dog", "the cat and a cat and the dogs",
              removed: ["the", "dog"], added: ["a", "dogs"])
    }

    func testWhitespaceOnlyChangesRemainDetectable() {
        for (original, corrected) in [
            ("Hello  world.", "Hello world."), ("Hello\nworld.", "Hello world."),
            ("  Hello! ", "Hello!"), ("a b", "ab"), ("\t", "\n"),
            ("Hello\u{00a0}world", "Hello world")
        ] {
            let result = correction(original, corrected).changeHighlights
            XCTAssertTrue(result.hasChanges)
            XCTAssertTrue(result.hasWhitespaceChanges)
            verifyExactUnchangedText(original, corrected, result)
        }
        check("Hello  world.", "Hello world.", removed: ["  "], added: [" "])
        check("Hello\nworld.", "Hello world.", removed: ["\n"], added: [" "])
        XCTAssertFalse(correction("I has it.", "I have it.").changeHighlights.hasWhitespaceChanges)
    }

    func testUnicodeRangesPreserveCompleteGraphemes() {
        check("Café was nice 😊", "Café is nice 😊", removed: ["was"], added: ["is"])
        check("I love 👩🏽‍💻!", "I love 👩🏾‍💻!", removed: ["👩🏽‍💻"], added: ["👩🏾‍💻"])
        check("🇺🇸 has a team.", "🇺🇸 have a team.", removed: ["has"], added: ["have"])
        check("Cafe\u{0301} was great.", "Cafe\u{0301} is great.", removed: ["was"], added: ["is"])
    }

    func testNormalizationOnlyChangeIsComparedByExactBytes() {
        let original = "Cafe\u{0301}"
        let corrected = "Café"
        let value = correction(original, corrected)
        XCTAssertTrue(value.hasChanges)
        let result = value.changeHighlights
        XCTAssertTrue(result.hasChanges)
        XCTAssertFalse(result.hasWhitespaceChanges)
        XCTAssertEqual(result.originalRanges, [NSRange(location: 0, length: 5)])
        XCTAssertEqual(result.correctedRanges, [NSRange(location: 0, length: 4)])
        XCTAssertTrue(fragments(original, result.originalRanges)[0].utf8.elementsEqual(original.utf8))
        XCTAssertTrue(fragments(corrected, result.correctedRanges)[0].utf8.elementsEqual(corrected.utf8))
        verifyExactUnchangedText(original, corrected, result)
    }

    func testIdenticalInputHasNoHighlights() {
        for text in ["", "This is correct.", "Café 👩🏽‍💻!", "  \n\t", "Cafe\u{0301}"] {
            let result = correction(text, text).changeHighlights
            XCTAssertFalse(result.hasChanges)
            XCTAssertFalse(result.hasWhitespaceChanges)
            XCTAssertTrue(result.originalRanges.isEmpty)
            XCTAssertTrue(result.correctedRanges.isEmpty)
        }
    }

    func testLongRepeatedInputRetainsDistantUnchangedIslands() {
        let bridge = String(repeating: "a, ", count: 1_200)
        check("I has " + bridge + "this result.", "I have " + bridge + "these results.",
              removed: ["has", "this", "result"], added: ["have", "these", "results"])
    }

    func testPathologicalTokenCountsUseBoundedFallbackAndKeepOuterContext() {
        let oldMiddle = String(repeating: "?,", count: 1_990)
        let newMiddle = String(repeating: "!;", count: 5_990)
        check("Start " + oldMiddle + " End.", "Start " + newMiddle + " End.",
              removed: [oldMiddle], added: [newMiddle])
    }

    func testVariedSmallInputsKeepUnchangedBytesAndValidRanges() {
        // Deterministic mixed text exercises alternate shortest paths, repeated
        // tokens, surrogate pairs, combining marks and spacing combinations.
        let vocabulary = ["a", "b", " ", "  ", ",", "!", "👩🏽‍💻", "é", "e\u{0301}", "\n"]
        var state: UInt64 = 0xCAFE
        func next(_ limit: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) % UInt64(limit))
        }
        for _ in 0..<300 {
            let original = (0..<next(24)).map { _ in vocabulary[next(vocabulary.count)] }.joined()
            let corrected = (0..<next(24)).map { _ in vocabulary[next(vocabulary.count)] }.joined()
            verifyExactUnchangedText(original, corrected, correction(original, corrected).changeHighlights)
        }
    }
}
