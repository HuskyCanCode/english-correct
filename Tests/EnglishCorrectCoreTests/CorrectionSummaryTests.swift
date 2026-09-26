import XCTest
@testable import EnglishCorrectCore

final class CorrectionSummaryTests: XCTestCase {
    private func summary(_ before: String, _ after: String) -> String {
        Correction(original: before, corrected: after, explanation: "An unreliable grammar claim.").editSummary
    }

    func testReplacementShowsChangedWordsAndPreservesInterveningCommonWords() {
        XCTAssertEqual(summary("I has two books.", "I have two books."), "“has” → “have”")
        XCTAssertEqual(summary("She go to school yesterday.", "She went to the school yesterday."), "“go to” → “went to the”")
        XCTAssertEqual(summary("We was very happy with this results.", "We were very happy with these results."), "“was very happy with this” → “were very happy with these”")
        XCTAssertEqual(summary("I has  a apple.", "I have\tan apple."), "“has  a” → “have\tan”")
    }

    func testInsertionsAndDeletionsDoNotIncludeUnchangedWords() {
        XCTAssertEqual(summary("I like books.", "I really like books."), "Added “really”")
        XCTAssertEqual(summary("I really like books.", "I like books."), "Removed “really”")
        XCTAssertEqual(summary("Hello world", "Dear Hello world"), "Added “Dear”")
        XCTAssertEqual(summary("Hello world", "Hello world today"), "Added “today”")
        XCTAssertEqual(summary("", "Hello!"), "Added “Hello!”")
        XCTAssertEqual(summary("Goodbye!", ""), "Removed “Goodbye!”")
    }

    func testPunctuationRemainsPartOfTheExactChangedSpan() {
        XCTAssertEqual(summary("Hello world", "Hello world!"), "“world” → “world!”")
        XCTAssertEqual(summary("Hello, world!", "Hello world!"), "“Hello,” → “Hello”")
        XCTAssertEqual(summary("I said \"hello\"", "I said “hello.”"), "“\"hello\"” → ““hello.””")
    }

    func testWhitespaceOnlyChangesAreDescribedAsSpacing() {
        for (before, after) in [
            ("Hello  world.", "Hello world."), ("Hello\nworld.", "Hello world."),
            ("  Hello! ", "Hello!"), ("a b", "ab"), ("\t", "\n"),
            ("Hello\u{00a0}world", "Hello world")
        ] {
            XCTAssertEqual(summary(before, after), "Spacing changed.")
        }
    }

    func testUnchangedTextDoesNotUseModelExplanation() {
        XCTAssertEqual(summary("This is correct.", "This is correct."), "No changes suggested.")
        XCTAssertEqual(summary("", ""), "No changes suggested.")
        let correction = Correction(original: "I has books.", corrected: "I have books.", explanation: "Have agrees with books.")
        XCTAssertEqual(correction.editSummary, "“has” → “have”")
    }

    func testUnicodeIsComparedAndPreservedExactly() {
        XCTAssertEqual(summary("Café was nice 😊", "Café is nice 😊"), "“was” → “is”")
        XCTAssertEqual(summary("I love 🐈", "I love 🐕"), "“🐈” → “🐕”")
        let decomposed = "Cafe\u{0301}"
        let composed = "Café"
        let result = summary(decomposed, composed)
        XCTAssertTrue(result.utf8.elementsEqual("“\(decomposed)” → “\(composed)”".utf8))
        XCTAssertFalse(result.contains("No changes"))
    }

    func testLongChangedSpansUseABoundedReviewPrompt() {
        let eighty = String(repeating: "a", count: 80)
        let eightyOne = String(repeating: "b", count: 81)
        XCTAssertEqual(summary("before", eighty), "“before” → “\(eighty)”")
        let generic = "Review the proposed changes before applying."
        XCTAssertEqual(summary("before", eightyOne), generic)
        XCTAssertEqual(summary(eightyOne, "after"), generic)
        XCTAssertEqual(summary("", eightyOne), generic)
        XCTAssertEqual(summary(eightyOne, ""), generic)
        XCTAssertEqual(summary("start " + eightyOne + " wrong end", "start " + eightyOne + " right end"), "“wrong” → “right”")
    }
}
