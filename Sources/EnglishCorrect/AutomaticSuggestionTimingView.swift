import SwiftUI

/// A short typing pause; model processing time is additional.
enum AutomaticSuggestionTiming {
    static let defaultSeconds = 1.2
    static let range = 0.3...10.0

    static func normalized(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultSeconds }
        return (min(max(seconds, range.lowerBound), range.upperBound) * 10).rounded() / 10
    }
}

struct AutomaticSuggestionTimingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Wait after typing").font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Stepper(value: $model.automaticSuggestionDelay, in: AutomaticSuggestionTiming.range, step: 0.1) {
                    Text(model.automaticSuggestionDelay, format: .number.precision(.fractionLength(1)))
                        + Text(" seconds")
                }
                .fixedSize()
                .accessibilityLabel("Wait after typing, in seconds")
                .accessibilityIdentifier("automatic-suggestion-delay")
            }
            Slider(value: $model.automaticSuggestionDelay, in: AutomaticSuggestionTiming.range, step: 0.1) {
                Text("Automatic suggestion delay")
            }.accessibilityValue("\(model.automaticSuggestionDelay.formatted(.number.precision(.fractionLength(1)))) seconds")
            Text("Wait 0.3–10 seconds after you stop typing before checking. The model then needs a moment to prepare the suggestion. Keyboard shortcuts check immediately.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
