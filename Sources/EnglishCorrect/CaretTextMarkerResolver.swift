import ApplicationServices
import Foundation

/// Resolves a caret inside one already-authorized field without editing it.
/// Callers must recheck focus, permissions, text, and user activity before any
/// later write. Markers are deliberately acquired anew for every resolution.
@MainActor
enum CaretTextMarkerResolver {
    typealias ParameterizedRead = (AXUIElement, String, CFTypeRef) -> (AXError, CFTypeRef?)

    static func collapsedRange(atUTF16Offset offset: Int, in field: AXUIElement,
                               expectedText: String, read: ParameterizedRead) -> AXTextMarkerRange? {
        let units = Array(expectedText.utf16)
        guard offset >= 0, offset <= units.count else { return nil }
        // AX uses UTF-16 offsets. A position between an emoji's surrogate pair
        // cannot describe an insertion point in the expected Swift string.
        if offset > 0, offset < units.count,
           (0xD800...0xDBFF).contains(units[offset - 1]),
           (0xDC00...0xDFFF).contains(units[offset]) { return nil }

        let (rangeResult, rangeValue) = read(field, kAXTextMarkerRangeForUIElementParameterizedAttribute, field)
        guard rangeResult == .success, let rangeValue,
              CFGetTypeID(rangeValue) == AXTextMarkerRangeGetTypeID() else { return nil }
        let fieldRange = rangeValue as! AXTextMarkerRange
        guard let fullText = string(in: fieldRange, field: field, read: read),
              fullText.utf8.elementsEqual(expectedText.utf8) else { return nil }

        let start = AXTextMarkerRangeCopyStartMarker(fieldRange)
        let end = AXTextMarkerRangeCopyEndMarker(fieldRange)
        // The field's own boundary markers avoid document-relative arithmetic.
        if offset == units.count { return AXTextMarkerRangeCreate(nil, end, end) }
        if offset == 0 { return AXTextMarkerRangeCreate(nil, start, start) }

        guard let startIndex = index(of: start, field: field, read: read) else { return nil }
        let (targetIndex, overflow) = startIndex.addingReportingOverflow(offset)
        guard !overflow else { return nil }
        let (markerResult, markerValue) = read(field, kAXTextMarkerForIndexParameterizedAttribute,
                                              NSNumber(value: targetIndex))
        guard markerResult == .success, let markerValue,
              CFGetTypeID(markerValue) == AXTextMarkerGetTypeID() else { return nil }
        let candidate = markerValue as! AXTextMarker

        // Browser indexes may refer to an entire document and count DOM breaks
        // differently. Both sides must round-trip inside this field exactly;
        // an index result alone is never sufficient evidence of the position.
        let prefixRange = AXTextMarkerRangeCreate(nil, start, candidate)
        let suffixRange = AXTextMarkerRangeCreate(nil, candidate, end)
        let expected = expectedText as NSString
        guard let prefix = string(in: prefixRange, field: field, read: read),
              prefix.utf8.elementsEqual(expected.substring(to: offset).utf8),
              let suffix = string(in: suffixRange, field: field, read: read),
              suffix.utf8.elementsEqual(expected.substring(from: offset).utf8) else { return nil }
        return AXTextMarkerRangeCreate(nil, candidate, candidate)
    }

    private static func string(in range: AXTextMarkerRange, field: AXUIElement,
                               read: ParameterizedRead) -> String? {
        let (result, value) = read(field, kAXStringForTextMarkerRangeParameterizedAttribute, range)
        guard result == .success, let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    private static func index(of marker: AXTextMarker, field: AXUIElement,
                              read: ParameterizedRead) -> Int? {
        let (result, value) = read(field, kAXIndexForTextMarkerParameterizedAttribute, marker)
        guard result == .success, let value, CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var index: Int64 = 0
        guard CFNumberGetValue(value as! CFNumber, .sInt64Type, &index), index >= 0 else { return nil }
        return Int(exactly: index)
    }
}
