import XCTest
@testable import EnglishCorrectCore

final class SuggestionGateTests: XCTestCase {
    private let bundleID = "com.example.Editor"
    private let fieldID = "document-body"
    private let text = "I has a suggestion."

    private func begin(
        _ gate: inout SuggestionGate,
        bundleID: String? = nil,
        fieldID: String? = nil,
        text: String? = nil,
        trusted: Bool = true,
        enabled: Bool = true,
        allowed: Set<String>? = nil
    ) -> SuggestionGate.Ticket? {
        gate.begin(
            bundleID: bundleID ?? self.bundleID,
            fieldID: fieldID ?? self.fieldID,
            text: text ?? self.text,
            accessibilityTrusted: trusted,
            enabled: enabled,
            allowedBundleIDs: allowed ?? [self.bundleID]
        )
    }

    private func accepts(
        _ gate: SuggestionGate,
        _ ticket: SuggestionGate.Ticket,
        bundleID: String? = nil,
        fieldID: String? = nil,
        text: String? = nil,
        trusted: Bool = true,
        enabled: Bool = true,
        allowed: Set<String>? = nil
    ) -> Bool {
        gate.accepts(
            ticket,
            bundleID: bundleID ?? self.bundleID,
            fieldID: fieldID ?? self.fieldID,
            text: text ?? self.text,
            accessibilityTrusted: trusted,
            enabled: enabled,
            allowedBundleIDs: allowed ?? [self.bundleID]
        )
    }

    func testConsentedUnchangedFieldAcceptsTicket() throws {
        var gate = SuggestionGate()
        let ticket = try XCTUnwrap(begin(&gate))
        XCTAssertEqual(ticket.bundleID, bundleID)
        XCTAssertEqual(ticket.fieldID, fieldID)
        XCTAssertEqual(ticket.text, text)
        XCTAssertTrue(accepts(gate, ticket))
    }

    func testEachPermissionIsRequiredBeforeRequestStarts() {
        var gate = SuggestionGate()
        XCTAssertNil(begin(&gate, trusted: false))
        XCTAssertNil(begin(&gate, enabled: false))
        XCTAssertNil(begin(&gate, allowed: []))
        XCTAssertNil(begin(&gate, allowed: ["com.example.OtherEditor"]))
    }

    func testRevokedPermissionsRejectPendingTicket() throws {
        var gate = SuggestionGate()
        let ticket = try XCTUnwrap(begin(&gate))
        XCTAssertFalse(accepts(gate, ticket, trusted: false))
        XCTAssertFalse(accepts(gate, ticket, enabled: false))
        XCTAssertFalse(accepts(gate, ticket, allowed: []))
    }

    func testChangedTextRejectsTicket() throws {
        var gate = SuggestionGate()
        let ticket = try XCTUnwrap(begin(&gate))
        XCTAssertFalse(accepts(gate, ticket, text: text + " "))
        XCTAssertFalse(accepts(gate, ticket, text: "I have a suggestion."))
    }

    func testChangedFieldOrApplicationRejectsTicket() throws {
        var gate = SuggestionGate()
        let ticket = try XCTUnwrap(begin(&gate))
        XCTAssertFalse(accepts(gate, ticket, fieldID: "search-box"))
        XCTAssertFalse(accepts(gate, ticket, bundleID: "com.example.OtherEditor", allowed: [bundleID, "com.example.OtherEditor"]))
    }

    func testLatestRequestWinsEvenWhenRequestsHaveIdenticalText() throws {
        var gate = SuggestionGate()
        let first = try XCTUnwrap(begin(&gate))
        let second = try XCTUnwrap(begin(&gate))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(accepts(gate, second))
        XCTAssertFalse(accepts(gate, first))
    }

    func testIneligibleRequestInvalidatesEarlierTicket() throws {
        var gate = SuggestionGate()
        let ticket = try XCTUnwrap(begin(&gate))
        XCTAssertNil(begin(&gate, text: ""))
        XCTAssertFalse(accepts(gate, ticket))
    }

    func testDeniedRequestInvalidatesEarlierTicketEvenIfPermissionReturns() throws {
        var gate = SuggestionGate()
        let ticket = try XCTUnwrap(begin(&gate))
        XCTAssertNil(begin(&gate, trusted: false))
        XCTAssertFalse(accepts(gate, ticket, trusted: true))
    }

    func testExplicitInvalidationRejectsTicket() throws {
        var gate = SuggestionGate()
        let ticket = try XCTUnwrap(begin(&gate))
        gate.invalidate()
        XCTAssertFalse(accepts(gate, ticket))
        let next = try XCTUnwrap(begin(&gate))
        XCTAssertTrue(accepts(gate, next))
    }

    func testIndependentGatesCannotAcceptEachOthersTickets() throws {
        var firstGate = SuggestionGate()
        var secondGate = SuggestionGate()
        let first = try XCTUnwrap(begin(&firstGate))
        let second = try XCTUnwrap(begin(&secondGate))
        XCTAssertFalse(accepts(secondGate, first))
        XCTAssertFalse(accepts(firstGate, second))
    }

    func testTextLengthBoundaries() throws {
        var gate = SuggestionGate()
        for invalid in ["", "a", "ab", String(repeating: "a", count: 4_001)] {
            XCTAssertNil(begin(&gate, text: invalid))
        }
        for valid in ["abc", String(repeating: "a", count: 4_000)] {
            let ticket = try XCTUnwrap(begin(&gate, text: valid))
            XCTAssertTrue(accepts(gate, ticket, text: valid))
        }
    }

    func testWhitespaceOnlyIsIneligible() {
        var gate = SuggestionGate()
        for whitespace in ["   ", "\t\r\n", "\u{00A0}\u{2003}\u{2028}"] {
            XCTAssertNil(begin(&gate, text: whitespace))
        }
    }

    func testMissingApplicationOrFieldIdentityIsIneligible() {
        var gate = SuggestionGate()
        XCTAssertNil(begin(&gate, bundleID: "", allowed: [""]))
        XCTAssertNil(begin(&gate, fieldID: ""))
    }

    func testUnicodeUsesUserPerceivedCharacters() throws {
        var gate = SuggestionGate()
        let family = "👨‍👩‍👧‍👦"
        XCTAssertNil(begin(&gate, text: String(repeating: family, count: 2)))
        let threeFamilies = String(repeating: family, count: 3)
        let emojiTicket = try XCTUnwrap(begin(&gate, text: threeFamilies))
        XCTAssertTrue(accepts(gate, emojiTicket, text: threeFamilies))

        let combined = String(repeating: "e\u{301}", count: 4_000)
        let combiningTicket = try XCTUnwrap(begin(&gate, text: combined))
        XCTAssertTrue(accepts(gate, combiningTicket, text: combined))
        XCTAssertNil(begin(&gate, text: combined + "e\u{301}"))

        let nonLatin = "我喜欢学习英语。"
        let nonLatinTicket = try XCTUnwrap(begin(&gate, text: nonLatin))
        XCTAssertTrue(accepts(gate, nonLatinTicket, text: nonLatin))
    }

    func testChangedUnicodeEncodingRejectsTicket() throws {
        var gate = SuggestionGate()
        let decomposed = "Cafe\u{301}"
        let composed = "Café"
        let ticket = try XCTUnwrap(begin(&gate, text: decomposed))
        XCTAssertFalse(accepts(gate, ticket, text: composed))
    }
}
