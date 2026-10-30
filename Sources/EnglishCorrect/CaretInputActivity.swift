import CoreGraphics
import Foundation

/// Detects interaction that should take precedence over a pending caret repair.
enum CaretInputActivity {
    // Releasing the accepting Return key or Apply click is harmless. Ordinary
    // pointer movement also must not cancel a repair, but dragging and scrolling
    // can be deliberate interaction with the editor.
    static let observedEventTypes: [CGEventType] = [
        .keyDown,
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .scrollWheel
    ]

    @MainActor
    static func hasInteraction(since uptime: TimeInterval) -> Bool {
        // Event counters omit key autorepeat, so use the age of the latest event
        // instead. Read uptime after the samples: any sampling delay then errs
        // toward cancelling a repair rather than overlooking recent input.
        let ages = observedEventTypes.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }
        return hasInteraction(since: uptime, now: ProcessInfo.processInfo.systemUptime, eventAges: ages)
    }

    /// Pure decision boundary for samples taken immediately before `now`.
    /// Invalid timing cancels a repair conservatively; an event at the boundary
    /// also counts as interaction because its ordering cannot be established.
    static func hasInteraction(since uptime: TimeInterval, now: TimeInterval,
                               eventAges: [TimeInterval]) -> Bool {
        guard uptime.isFinite, uptime >= 0, now.isFinite, now >= uptime,
              !eventAges.isEmpty else { return true }
        let elapsed = now - uptime
        return eventAges.contains { age in
            // A never-seen event can be represented as infinitely old. Unknown
            // or negative ages cannot establish that a repair is still safe.
            age.isNaN || age < 0 || age <= elapsed
        }
    }
}
