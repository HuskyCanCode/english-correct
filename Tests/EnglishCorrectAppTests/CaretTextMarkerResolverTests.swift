import ApplicationServices
import Foundation
import XCTest
@testable import EnglishCorrect

@MainActor
final class CaretTextMarkerResolverTests: XCTestCase {
    func testEndUsesTheSameFieldsEndMarkerWithoutDocumentIndexArithmetic() {
        let fake = MarkerReads(text: "Corrected 😀 text.")
        let result = resolve(fake.text.utf16.count, fake)

        assertCollapsed(result, at: fake.text.utf16.count, fake: fake)
        XCTAssertEqual(fake.attributes, [kAXTextMarkerRangeForUIElementParameterizedAttribute,
                                         kAXStringForTextMarkerRangeParameterizedAttribute])
        XCTAssertTrue(fake.allReadsUsedField)
        XCTAssertTrue(fake.fieldParameterMatched)
    }

    func testInteriorUnicodePositionAccountsForDocumentRootAndRoundTripsBothSides() {
        let prefix = "Hi 👩🏽‍💻 café!"
        let fake = MarkerReads(text: prefix + " untouched suffix")
        fake.rootIndex = NSNumber(value: 4_000)
        let offset = prefix.utf16.count

        let result = resolve(offset, fake)

        assertCollapsed(result, at: offset, fake: fake)
        XCTAssertEqual(fake.requestedIndexes, [4_000 + offset])
        XCTAssertEqual(fake.readRanges, [NSRange(location: 0, length: fake.text.utf16.count),
                                         NSRange(location: 0, length: offset),
                                         NSRange(location: offset, length: " untouched suffix".utf16.count)])
        XCTAssertTrue(fake.allReadsUsedField)
    }

    func testStartUsesFieldBoundaryAndNeedsNoIndexRead() {
        let fake = MarkerReads(text: "A corrected sentence.")
        assertCollapsed(resolve(0, fake), at: 0, fake: fake)
        XCTAssertFalse(fake.attributes.contains(kAXIndexForTextMarkerParameterizedAttribute))
    }

    func testInvalidOffsetsAndSplitSurrogateAreRejectedBeforeAnyRead() {
        for offset in [-1, 2, 5, Int.max] {
            let fake = MarkerReads(text: "A😀B")
            XCTAssertNil(resolve(offset, fake), "Offset \(offset)")
            XCTAssertTrue(fake.attributes.isEmpty)
        }
    }

    func testUnsupportedOrFailedParameterizedReadsDoNotResolve() {
        for unsupported in [kAXTextMarkerRangeForUIElementParameterizedAttribute,
                            kAXStringForTextMarkerRangeParameterizedAttribute,
                            kAXIndexForTextMarkerParameterizedAttribute,
                            kAXTextMarkerForIndexParameterizedAttribute] {
            for error in [AXError.parameterizedAttributeUnsupported, .cannotComplete, .noValue] {
                let fake = MarkerReads(text: "Corrected text.")
                fake.override = { attribute, _ in
                    attribute == unsupported ? (error, nil) : nil
                }
                XCTAssertNil(resolve(3, fake), "\(unsupported), \(error)")
            }
        }
    }

    func testWrongCFTypesAtEveryBoundaryAreRejected() {
        for attribute in [kAXTextMarkerRangeForUIElementParameterizedAttribute,
                          kAXStringForTextMarkerRangeParameterizedAttribute,
                          kAXIndexForTextMarkerParameterizedAttribute,
                          kAXTextMarkerForIndexParameterizedAttribute] {
            let fake = MarkerReads(text: "Corrected text.")
            fake.override = { requested, _ in
                guard requested == attribute else { return nil }
                let wrong: CFTypeRef = attribute == kAXStringForTextMarkerRangeParameterizedAttribute
                    ? NSNumber(value: 17) : "wrong type" as CFString
                return (.success, wrong)
            }
            XCTAssertNil(resolve(3, fake), attribute)
        }
    }

    func testFullTextMustMatchBytesIncludingUnicodeNormalization() {
        for stale in ["Different text.", "cafe\u{301}"] {
            let fake = MarkerReads(text: stale)
            XCTAssertNil(resolve(2, fake, expected: "café"))
            XCTAssertFalse(fake.attributes.contains(kAXIndexForTextMarkerParameterizedAttribute))
        }
    }

    func testStalePrefixAndSuffixAreBothRejected() {
        for staleRead in [2, 3] {
            let fake = MarkerReads(text: "Corrected text.")
            var stringReads = 0
            fake.override = { attribute, _ in
                guard attribute == kAXStringForTextMarkerRangeParameterizedAttribute else { return nil }
                stringReads += 1
                return stringReads == staleRead ? (.success, "Stale text" as CFString) : nil
            }
            XCTAssertNil(resolve(4, fake), "String read \(staleRead)")
        }
    }

    func testInvalidOrOverflowingRootIndexesNeverRequestACandidate() {
        for index in [NSNumber(value: Int.max), NSNumber(value: -1), NSNumber(value: 1.5),
                      NSNumber(value: Double.nan), NSNumber(value: Double.infinity), NSNumber(value: true)] {
            let fake = MarkerReads(text: "abc")
            fake.rootIndex = index
            XCTAssertNil(resolve(1, fake), index.description)
            XCTAssertTrue(fake.requestedIndexes.isEmpty)
        }
    }

    func testWrongOrOutOfFieldCandidateDoesNotPassPrefixAndSuffixChecks() {
        for candidateOffset in [1, 100] {
            let fake = MarkerReads(text: "Corrected text.")
            fake.override = { attribute, _ in
                attribute == kAXTextMarkerForIndexParameterizedAttribute
                    ? (.success, fake.marker(at: candidateOffset)) : nil
            }
            XCTAssertNil(resolve(4, fake))
        }
    }

    func testEmptyExpectedFieldCanResolveItsOwnBoundary() {
        let fake = MarkerReads(text: "")
        assertCollapsed(resolve(0, fake), at: 0, fake: fake)
        XCTAssertTrue(fake.requestedIndexes.isEmpty)
    }

    private func resolve(_ offset: Int, _ fake: MarkerReads, expected: String? = nil) -> AXTextMarkerRange? {
        CaretTextMarkerResolver.collapsedRange(atUTF16Offset: offset, in: fake.field,
                                              expectedText: expected ?? fake.text, read: fake.read)
    }

    private func assertCollapsed(_ result: AXTextMarkerRange?, at offset: Int, fake: MarkerReads,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let result else { return XCTFail("No marker range", file: file, line: line) }
        XCTAssertEqual(fake.offset(of: AXTextMarkerRangeCopyStartMarker(result)), offset, file: file, line: line)
        XCTAssertEqual(fake.offset(of: AXTextMarkerRangeCopyEndMarker(result)), offset, file: file, line: line)
    }
}

/// Test-only marker bytes encode field-local offsets. The resolver never decodes
/// them, and these fake markers are never sent to another application's AX API.
@MainActor
private final class MarkerReads {
    let field = AXUIElementCreateApplication(99_007)
    let text: String
    var rootIndex: CFTypeRef = NSNumber(value: 700)
    var override: ((String, CFTypeRef) -> (AXError, CFTypeRef?)?)?
    private(set) var attributes: [String] = []
    private(set) var requestedIndexes: [Int] = []
    private(set) var readRanges: [NSRange] = []
    private(set) var allReadsUsedField = true
    private(set) var fieldParameterMatched = true

    init(text: String) { self.text = text }

    func read(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> (AXError, CFTypeRef?) {
        attributes.append(attribute)
        allReadsUsedField = allReadsUsedField && CFEqual(element, field)
        if let response = override?(attribute, parameter) { return response }
        switch attribute {
        case kAXTextMarkerRangeForUIElementParameterizedAttribute:
            fieldParameterMatched = CFGetTypeID(parameter) == AXUIElementGetTypeID() && CFEqual(parameter, field)
            return (.success, AXTextMarkerRangeCreate(nil, marker(at: 0), marker(at: text.utf16.count)))
        case kAXStringForTextMarkerRangeParameterizedAttribute:
            guard CFGetTypeID(parameter) == AXTextMarkerRangeGetTypeID() else { return (.illegalArgument, nil) }
            let range = parameter as! AXTextMarkerRange
            let start = offset(of: AXTextMarkerRangeCopyStartMarker(range))
            let end = offset(of: AXTextMarkerRangeCopyEndMarker(range))
            guard start >= 0, end >= start, end <= text.utf16.count else { return (.noValue, nil) }
            let characterRange = NSRange(location: start, length: end - start)
            readRanges.append(characterRange)
            return (.success, (text as NSString).substring(with: characterRange) as CFString)
        case kAXIndexForTextMarkerParameterizedAttribute:
            return (.success, rootIndex)
        case kAXTextMarkerForIndexParameterizedAttribute:
            guard let target = parameter as? NSNumber, let root = rootIndex as? NSNumber else { return (.illegalArgument, nil) }
            requestedIndexes.append(target.intValue)
            let (local, overflow) = target.intValue.subtractingReportingOverflow(root.intValue)
            return overflow ? (.noValue, nil) : (.success, marker(at: local))
        default:
            return (.parameterizedAttributeUnsupported, nil)
        }
    }

    func marker(at offset: Int) -> AXTextMarker {
        var value = Int64(offset)
        return withUnsafeBytes(of: &value) { bytes in
            AXTextMarkerCreate(nil, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count)
        }
    }

    func offset(of marker: AXTextMarker) -> Int {
        var value: Int64 = 0
        precondition(AXTextMarkerGetLength(marker) == MemoryLayout<Int64>.size)
        withUnsafeMutableBytes(of: &value) { bytes in
            bytes.copyMemory(from: UnsafeRawBufferPointer(start: AXTextMarkerGetBytePtr(marker), count: bytes.count))
        }
        return Int(value)
    }
}
