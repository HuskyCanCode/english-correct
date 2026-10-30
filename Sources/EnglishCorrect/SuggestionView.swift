import SwiftUI
import AppKit
import EnglishCorrectCore

private let themeAccent = GlassTheme.accent

/// A value snapshot keeps a popup's measurement and displayed contents in sync.
struct SuggestionPresentation {
    let app: String
    let scope: String
    let busy: Bool
    let correction: Correction?
    let canApply: Bool
    let status: String
    let needsSetup: Bool
    let modelLabel: String
    let writingStyle: WritingStyle
    let undoAvailable: Bool

    @MainActor init(model: AppModel) {
        app = model.externalApp
        scope = model.externalScope
        busy = model.externalBusy
        correction = model.externalCorrection
        canApply = model.externalCanApply
        status = model.externalStatus
        needsSetup = model.externalNeedsSetup
        modelLabel = model.activeModelLabel
        writingStyle = model.writingStyle
        undoAvailable = model.externalUndoAvailable
    }
}

enum SuggestionMetrics {
    static let width: CGFloat = 380
    static let padding: CGFloat = 18
    static let maximumTextHeight: CGFloat = 150

    static func textHeight(_ text: String, width: CGFloat, fontSize: CGFloat, lineSpacing: CGFloat = 0,
                           maximum: CGFloat = maximumTextHeight) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph]
        )
        // A little breathing room also protects descenders from rounding at
        // different display scales. An explicit viewport cannot collapse.
        return min(maximum, max(28, ceil(bounds.height) + 8))
    }
}

struct SuggestionView: View {
    let presentation: SuggestionPresentation
    let width: CGFloat
    var acceptanceHint: String? = nil
    var dismissalHint: String? = nil
    var styleChanged: (WritingStyle) -> Void = { _ in }
    let dismiss: () -> Void
    let copy: () -> Void
    let apply: () -> Void
    let openSettings: () -> Void
    var undo: () -> Void = {}

    private var textWidth: CGFloat { width - SuggestionMetrics.padding * 2 }

    var body: some View {
        GlassGroup(spacing: 8) {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("English Correct", systemImage: "sparkles").font(.system(size: 12, weight: .semibold))
                Spacer()
                if !presentation.undoAvailable {
                    Text(presentation.modelLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(GlassTheme.accent)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(GlassTheme.glassTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Model: \(presentation.modelLabel)")
                        .accessibilityIdentifier("suggestion-model-name")
                        .help("Model: \(presentation.modelLabel)")
                }
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(GlassTheme.glassTint.opacity(0.16), in: Circle())
                        .contentShape(Circle())
                }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss suggestion")
            }
            Text([presentation.app, presentation.scope].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(GlassTheme.secondary).fixedSize(horizontal: false, vertical: true)
            if presentation.undoAvailable {
                HStack(spacing: 12) {
                    Label("Correction applied", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Undo", action: undo)
                        .buttonStyle(SuggestionActionStyle())
                        .accessibilityIdentifier("suggestion-undo")
                        .accessibilityHint("Restores your original wording if this input has not changed.")
                }
                Text("Available briefly while this input stays unchanged.")
                    .font(.system(size: 10)).foregroundStyle(GlassTheme.secondary)
            } else {
            Picker("Writing style", selection: Binding(get: { presentation.writingStyle }, set: styleChanged)) {
                ForEach(WritingStyle.allCases) { style in
                    Text(style.label).foregroundStyle(GlassTheme.primary).tag(style)
                }
            }.pickerStyle(.segmented).focusable(false)
                .accessibilityIdentifier("suggestion-writing-style")
            if presentation.busy { ProgressView().controlSize(.small) }
            if let suggestion = presentation.correction {
                ScrollView(.vertical) {
                    Text(CorrectionHighlighting.correctedText(for: suggestion))
                        .font(.system(size: 15)).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("suggestion-corrected-text")
                }
                .scrollIndicators(.visible)
                .frame(height: SuggestionMetrics.textHeight(suggestion.corrected, width: textWidth, fontSize: 15, lineSpacing: 4))
                .accessibilityIdentifier("suggestion-text-scroll")
                Text(suggestion.editSummary).font(.system(size: 11)).foregroundStyle(GlassTheme.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .center) {
                    if SuggestionMetrics.textHeight(suggestion.corrected, width: textWidth, fontSize: 15, lineSpacing: 4) >= SuggestionMetrics.maximumTextHeight {
                        Text("Scroll to read more.")
                            .font(.system(size: 10)).foregroundStyle(GlassTheme.secondary)
                    }
                    Spacer()
                    Button("Copy", action: copy)
                        .buttonStyle(SuggestionActionStyle())
                        .accessibilityIdentifier("suggestion-copy")
                        .accessibilityHint("Copies the corrected text to the clipboard.")
                        .help("Copy the corrected text")
                    Button("Apply", action: apply)
                        .buttonStyle(SuggestionActionStyle(prominent: true))
                        .disabled(!presentation.canApply)
                        .accessibilityIdentifier("suggestion-apply")
                        .accessibilityHint(presentation.canApply
                            ? "Replaces the reviewed text in your writing app. " + (acceptanceHint ?? "")
                            : "Direct replacement is unavailable in this field. Use Copy instead.")
                        .help(presentation.canApply ? "Apply the correction" : "This field doesn't support replacement. Use Copy instead.")
                }
            }
            if !presentation.status.isEmpty {
                Text(presentation.status).font(.caption).foregroundStyle(GlassTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if presentation.needsSetup {
                Button("Open English Correct settings", action: openSettings).font(.caption)
            }
            }
            if acceptanceHint != nil || dismissalHint != nil {
                Text([acceptanceHint, dismissalHint].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(GlassTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("suggestion-accept-key-hint")
            }
        }
        .padding(SuggestionMetrics.padding)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .glassSurface(cornerRadius: 20)
        }
        .foregroundStyle(GlassTheme.primary).tint(GlassTheme.controlAccent).glassAction()
    }
}
