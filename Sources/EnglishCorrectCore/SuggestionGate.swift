import Foundation

/// Authorizes suggestions for a consented, unchanged input field.
///
/// A new request always invalidates the preceding request, including when the new
/// request is ineligible. Call `invalidate()` when focus or consent changes.
public struct SuggestionGate: Sendable {
    public struct Ticket: Equatable, Sendable {
        public let bundleID: String
        public let fieldID: String
        public let text: String

        fileprivate let gateID: UUID
        fileprivate let epoch: UInt64

        fileprivate init(bundleID: String, fieldID: String, text: String, gateID: UUID, epoch: UInt64) {
            self.bundleID = bundleID
            self.fieldID = fieldID
            self.text = text
            self.gateID = gateID
            self.epoch = epoch
        }
    }

    private var gateID = UUID()
    private var epoch: UInt64 = 0

    public init() {}

    public mutating func invalidate() {
        // Rotating the identity at rollover prevents any old ticket becoming
        // valid again, even after the generation counter has exhausted its range.
        if epoch == UInt64.max {
            gateID = UUID()
            epoch = 0
        } else {
            epoch += 1
        }
    }

    public mutating func begin(
        bundleID: String,
        fieldID: String,
        text: String,
        accessibilityTrusted: Bool,
        enabled: Bool,
        allowedBundleIDs: Set<String>,
        allowShortText: Bool = false
    ) -> Ticket? {
        invalidate()
        guard Self.isEligible(
            bundleID: bundleID,
            fieldID: fieldID,
            text: text,
            accessibilityTrusted: accessibilityTrusted,
            enabled: enabled,
            allowedBundleIDs: allowedBundleIDs,
            allowShortText: allowShortText
        ) else { return nil }

        return Ticket(bundleID: bundleID, fieldID: fieldID, text: text, gateID: gateID, epoch: epoch)
    }

    public func accepts(
        _ ticket: Ticket,
        bundleID: String,
        fieldID: String,
        text: String,
        accessibilityTrusted: Bool,
        enabled: Bool,
        allowedBundleIDs: Set<String>,
        allowShortText: Bool = false
    ) -> Bool {
        ticket.gateID == gateID
            && ticket.epoch == epoch
            && ticket.bundleID == bundleID
            && ticket.fieldID == fieldID
            && ticket.text.utf8.elementsEqual(text.utf8)
            && Self.isEligible(
                bundleID: bundleID,
                fieldID: fieldID,
                text: text,
                accessibilityTrusted: accessibilityTrusted,
                enabled: enabled,
                allowedBundleIDs: allowedBundleIDs,
            allowShortText: allowShortText
            )
    }

    private static func isEligible(
        bundleID: String,
        fieldID: String,
        text: String,
        accessibilityTrusted: Bool,
        enabled: Bool,
        allowedBundleIDs: Set<String>,
        allowShortText: Bool = false
    ) -> Bool {
        guard accessibilityTrusted, enabled, allowedBundleIDs.contains(bundleID),
              !bundleID.isEmpty, !fieldID.isEmpty else { return false }
        // Count user-perceived characters so emoji and combining marks do not
        // consume multiple characters merely because of their encoding.
        return ((allowShortText ? 1 : 3)...4_000).contains(text.count)
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
