import Foundation

/// Exact UTF-16 ranges for presenting an edit without altering either string.
/// Each range starts and ends at an extended grapheme-cluster boundary.
public struct CorrectionChangeHighlights: Equatable, Sendable {
    public let originalRanges: [NSRange]
    public let correctedRanges: [NSRange]
    public let hasChanges: Bool
    public let hasWhitespaceChanges: Bool
}

extension Correction {
    /// Marks complete changed words, separate punctuation, and changed spacing.
    /// Large rewrites use a bounded comparison and may highlight a broader span.
    public var changeHighlights: CorrectionChangeHighlights {
        CorrectionDiff.highlights(original: original, corrected: corrected)
    }
}

private enum CorrectionDiff {
    private struct Token {
        let identity: Int
        let range: NSRange
        let isWhitespace: Bool
    }

    private enum Kind { case word, whitespace, punctuation }

    static func highlights(original: String, corrected: String) -> CorrectionChangeHighlights {
        guard !original.utf8.elementsEqual(corrected.utf8) else {
            return CorrectionChangeHighlights(originalRanges: [], correctedRanges: [],
                                              hasChanges: false, hasWhitespaceChanges: false)
        }

        // Swift String equality treats canonical Unicode equivalents as equal.
        // Intern bytes instead so normalization changes remain visible and exact.
        var identities: [Data: Int] = [:]
        let before = tokenize(original, identities: &identities)
        let after = tokenize(corrected, identities: &identities)
        var oldChanged = [Bool](repeating: true, count: before.count)
        var newChanged = [Bool](repeating: true, count: after.count)

        var prefix = 0
        while prefix < min(before.count, after.count),
              before[prefix].identity == after[prefix].identity {
            oldChanged[prefix] = false
            newChanged[prefix] = false
            prefix += 1
        }
        var oldEnd = before.count
        var newEnd = after.count
        while oldEnd > prefix, newEnd > prefix,
              before[oldEnd - 1].identity == after[newEnd - 1].identity {
            oldEnd -= 1
            newEnd -= 1
            oldChanged[oldEnd] = false
            newChanged[newEnd] = false
        }

        if let matches = matches(before, after, start: prefix, oldEnd: oldEnd, newEnd: newEnd) {
            for (old, new) in matches {
                oldChanged[old] = false
                newChanged[new] = false
            }
        }
        let spacingChanged = zip(before, oldChanged).contains { $0.isWhitespace && $1 }
            || zip(after, newChanged).contains { $0.isWhitespace && $1 }
        return CorrectionChangeHighlights(
            originalRanges: ranges(tokens: before, changed: oldChanged),
            correctedRanges: ranges(tokens: after, changed: newChanged),
            hasChanges: true,
            hasWhitespaceChanges: spacingChanged
        )
    }

    private static func tokenize(_ text: String, identities: inout [Data: Int]) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex
        var start = index
        var startOffset = 0
        var offset = 0
        var activeKind: Kind?
        var previousWasLetter = false

        func appendToken(endingAt end: String.Index, endOffset: Int, kind: Kind) {
            let bytes = Data(text[start..<end].utf8)
            let identity: Int
            if let existing = identities[bytes] {
                identity = existing
            } else {
                identity = identities.count
                identities[bytes] = identity
            }
            result.append(Token(identity: identity,
                                range: NSRange(location: startOffset, length: endOffset - startOffset),
                                isWhitespace: kind == .whitespace))
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let isInternalApostrophe = (character == "'" || character == "’")
                && previousWasLetter && next < text.endIndex && text[next].isLetter
            let kind: Kind = character.isWhitespace ? .whitespace
                : (character.isLetter || character.isNumber || isInternalApostrophe) ? .word
                : .punctuation
            if let activeKind, activeKind != kind || kind == .punctuation {
                appendToken(endingAt: index, endOffset: offset, kind: activeKind)
                start = index
                startOffset = offset
            }
            activeKind = kind
            offset += character.utf16.count
            previousWasLetter = character.isLetter
            index = next
        }
        if let activeKind {
            appendToken(endingAt: text.endIndex, endOffset: offset, kind: activeKind)
        }
        return result
    }

    /// Myers' shortest edit path keeps repeated words and distant edits aligned.
    /// The diagonal trace is capped at 512 edits (about 2 MiB), and a shared work
    /// budget bounds comparisons. Beyond that, the unmatched middle is a valid,
    /// deliberately broader highlight; the exact common prefix/suffix stay clear.
    private static func matches(_ before: [Token], _ after: [Token], start: Int,
                                oldEnd: Int, newEnd: Int) -> [(Int, Int)]? {
        let oldCount = oldEnd - start
        let newCount = newEnd - start
        guard oldCount > 0, newCount > 0 else { return [] }
        let maxDistance = min(oldCount + newCount, 512)
        var trace: [[Int]] = []
        var budget = 1_000_000

        func value(_ row: [Int], diagonal: Int, distance: Int) -> Int {
            let index = diagonal + distance
            return index >= 0 && index < row.count ? row[index] : -1
        }

        for distance in 0...maxDistance {
            var row = [Int](repeating: -1, count: 2 * distance + 1)
            let previous = trace.last ?? []
            for diagonal in stride(from: -distance, through: distance, by: 2) {
                budget -= 1
                guard budget >= 0 else { return nil }
                var x: Int
                if distance == 0 {
                    x = 0
                } else if diagonal == -distance
                    || (diagonal != distance
                        && value(previous, diagonal: diagonal - 1, distance: distance - 1)
                        < value(previous, diagonal: diagonal + 1, distance: distance - 1)) {
                    x = value(previous, diagonal: diagonal + 1, distance: distance - 1)
                } else {
                    x = value(previous, diagonal: diagonal - 1, distance: distance - 1) + 1
                }
                var y = x - diagonal
                while x < oldCount, y < newCount,
                      before[start + x].identity == after[start + y].identity {
                    budget -= 1
                    guard budget >= 0 else { return nil }
                    x += 1
                    y += 1
                }
                row[diagonal + distance] = x
                if x >= oldCount, y >= newCount {
                    trace.append(row)
                    var matches: [(Int, Int)] = []
                    if distance > 0 {
                        for step in stride(from: distance, through: 1, by: -1) {
                            let prior = trace[step - 1]
                            let currentDiagonal = x - y
                            let priorDiagonal: Int
                            if currentDiagonal == -step
                                || (currentDiagonal != step
                                    && value(prior, diagonal: currentDiagonal - 1, distance: step - 1)
                                    < value(prior, diagonal: currentDiagonal + 1, distance: step - 1)) {
                                priorDiagonal = currentDiagonal + 1
                            } else {
                                priorDiagonal = currentDiagonal - 1
                            }
                            let priorX = value(prior, diagonal: priorDiagonal, distance: step - 1)
                            let priorY = priorX - priorDiagonal
                            while x > priorX, y > priorY {
                                x -= 1
                                y -= 1
                                matches.append((start + x, start + y))
                            }
                            x = priorX
                            y = priorY
                        }
                    }
                    while x > 0, y > 0 {
                        x -= 1
                        y -= 1
                        matches.append((start + x, start + y))
                    }
                    return matches
                }
            }
            trace.append(row)
        }
        return nil
    }

    private static func ranges(tokens: [Token], changed: [Bool]) -> [NSRange] {
        var result: [NSRange] = []
        for (token, isChanged) in zip(tokens, changed) where isChanged {
            if let last = result.last, NSMaxRange(last) == token.range.location {
                result[result.count - 1].length += token.range.length
            } else {
                result.append(token.range)
            }
        }
        return result
    }
}
