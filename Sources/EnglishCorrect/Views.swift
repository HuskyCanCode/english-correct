import SwiftUI
import AppKit
import EnglishCorrectCore

private let teal = GlassTheme.accent

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var loginItem: LoginItemController
    private let sections = [("Setup", "checklist"), ("Write", "square.and.pencil"), ("App access", "hand.raised"), ("Models", "square.stack.3d.up")]
    var body: some View {
        GlassGroup(spacing: 12) {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "text.badge.checkmark").font(.system(size: 25)).foregroundStyle(teal)
                    Text("English\nCorrect").font(.system(size: 19, weight: .semibold, design: .serif)).lineSpacing(-1)
                }.padding(.top, 18)
                VStack(spacing: 6) {
                    ForEach(sections, id: \.0) { item in
                        Button {
                            if item.0 == "Setup" { model.openSetup() }
                            else { model.section = item.0; if item.0 == "App access" { model.refreshApps() } }
                        } label: {
                            HStack(spacing: 12) { Image(systemName: item.1).frame(width: 20); Text(item.0); Spacer() }
                                .font(.system(size: 14, weight: model.section == item.0 ? .semibold : .regular))
                                .padding(.horizontal, 13).padding(.vertical, 12)
                                .glassSelection(model.section == item.0, cornerRadius: 12)
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 11) {
                    Label("On your Mac", systemImage: "lock.shield").font(.system(size: 12, weight: .semibold)).foregroundStyle(teal)
                    Text("Your words stay between this app and your local AI server.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                }.padding(14).contentSurface(cornerRadius: 16)
                Text("A little help. Still your voice.").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(22).frame(width: 215)
                .background(.primary.opacity(0.035))
                .overlay(alignment: .trailing) { Rectangle().fill(.primary.opacity(0.07)).frame(width: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("YOUR EVERYDAY WRITING COMPANION").font(.system(size: 10, weight: .semibold)).tracking(1.7).foregroundStyle(.secondary)
                        Spacer()
                        Label("Local only", systemImage: "circle.fill").font(.system(size: 11)).foregroundStyle(teal)
                    }
                    if model.section == "Setup" { SetupGuideView(model: model, loginItem: loginItem) }
                    else if model.section == "Write" { writing }
                    else if model.section == "App access" { access }
                    else { ModelLibraryView(library: model.library, appModel: model) }
                }.padding(34).frame(maxWidth: .infinity, alignment: .leading)
            }.id(model.section)
        }
        }.background { GlassWindowBackground().ignoresSafeArea() }
            .foregroundStyle(.primary).frame(minWidth: 890, minHeight: 670)
            .glassAction()
            .tint(teal)
    }

    private func title(_ name: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.system(size: 35, weight: .medium, design: .serif))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var writing: some View {
        VStack(alignment: .leading, spacing: 22) {
            title("Make room for better words.", "Check a draft here, or get a gentle suggestion while you write in an app you allow.")
            LoginItemSettingsView(controller: loginItem, promptOnly: true)
            if !model.readyInOtherApps {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.readyInApp ? "Ready to write here" : "Finish setting up your local model")
                            .font(.system(size: 14, weight: .semibold))
                        Text(model.readyInApp ? "Complete setup to use suggestions in other apps." : model.setupAIState.message)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open setup guide") { model.openSetup() }
                }.padding(18).contentSurface(cornerRadius: 18)
            }
            HStack(spacing: 13) {
                Image(systemName: model.enabled ? "sparkle" : "pause.circle").font(.system(size: 24)).foregroundStyle(teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.enabled ? "Automatic suggestions are on" : "Automatic suggestions are paused").font(.system(size: 14, weight: .semibold))
                    Text(model.enabled ? model.monitoringStatus : (model.readyInOtherApps ? "The keyboard shortcut still works in allowed apps." : "Finish setup to use suggestions in other apps.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enable suggestions", isOn: Binding(get: { model.enabled }, set: { model.setAutomaticSuggestions($0) })).labelsHidden().toggleStyle(.switch).accessibilityLabel("Enable suggestions")
            }.padding(18).contentSurface(cornerRadius: 18, tinted: true)
            shortcutCard
            VStack(alignment: .leading, spacing: 13) {
                HStack { Text("YOUR DRAFT").font(.system(size: 11, weight: .semibold)).tracking(1.3); Spacer(); Text("\(model.draft.count) / 4,000").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                TextEditor(text: $model.draft).font(.system(size: 17)).lineSpacing(6).scrollContentBackground(.hidden)
                    .frame(minHeight: 145).accessibilityLabel("Writing draft")

                Divider()
                HStack {
                    Text("Only checked when you ask.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if model.draftBusy { ProgressView().controlSize(.small) }
                    Button(model.draftBusy ? "Checking…" : "Check writing") { model.checkDraft() }
                        .glassAction(prominent: true).controlSize(.large)
                        .disabled(!model.readyInApp || model.draftBusy || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 || model.draft.count > 4000)
                }
            }.padding(20).contentSurface(cornerRadius: 20)
            if !model.draftStatus.isEmpty {
                Text(model.draftStatus).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let suggestion = model.draftCorrection, suggestion.hasChanges {
                VStack(alignment: .leading, spacing: 13) {
                    Label("SUGGESTED REVISION", systemImage: "sparkles").font(.system(size: 11, weight: .semibold)).tracking(1)
                    Text(CorrectionHighlighting.correctedText(for: suggestion)).font(.system(size: 17)).lineSpacing(5).textSelection(.enabled)
                    Text(suggestion.editSummary).font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack { Spacer(); Button("Dismiss") { model.draftChanged() }; Button("Use suggestion") { model.applyDraft() }.glassAction(prominent: true) }
                }.padding(20).contentSurface(cornerRadius: 20, tinted: true)
            }
            HStack(alignment: .top, spacing: 26) {
                tip("01", "Choose a local model", "Download Fast or Pro in Models.")
                tip("02", "Choose your apps", "Grant access to the apps you want help in.")
                tip("03", "Keep the final say", "Review each suggestion before applying it.")
            }.padding(.top, 4)
            if !model.externalStatus.isEmpty { Text(model.externalStatus).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var shortcutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Check in other apps", systemImage: "keyboard").font(.system(size: 14, weight: .semibold))
                Spacer()
                Picker("Correction shortcut", selection: $model.shortcut) {
                    ForEach(CorrectionShortcut.allCases) { choice in Text(choice.label).tag(choice) }
                }.labelsHidden().frame(width: 150).accessibilityLabel("Correction shortcut")
            }
            Text("In an allowed app, select a sentence to check just that text. With nothing selected, the shortcut checks the whole input. Use Check writing for the draft here.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.shortcutRegistered && !model.readyInOtherApps ? "Shortcut registered. Complete setup to check writing in other apps." : model.shortcutStatus).font(.system(size: 11)).foregroundStyle(teal).fixedSize(horizontal: false, vertical: true)
            if !model.trusted {
                Button("Set up access to other apps") { model.section = "App access"; model.refreshApps() }.font(.system(size: 12))
            }
        }.padding(18).contentSurface(cornerRadius: 18)
    }

    private func tip(_ number: String, _ heading: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(number).font(.system(size: 11, design: .monospaced)).foregroundStyle(teal)
            Text(heading).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 22) {
            title("Help, by invitation.", "You choose where English Correct can read a focused text field and suggest a correction.")
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: model.trusted ? "checkmark.shield.fill" : "hand.raised.fill").font(.title2).foregroundStyle(teal)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("macOS Accessibility").font(.headline)
                        Text(model.trusted ? "Access granted" : "Allow access in System Settings to detect text fields.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.trusted ? "Open settings" : "Grant access") { model.requestAccess() }.controlSize(.large)
                }
                Text("Then turn on only the apps you want below. Password fields are skipped, and suggestions never apply automatically.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(20).contentSurface(cornerRadius: 18)
            HStack { Text("ALLOWED APPS · \(model.allowedCount)").font(.system(size: 11, weight: .semibold)).tracking(1); Spacer(); Button("Refresh apps", systemImage: "arrow.clockwise") { model.refreshApps() } }
            VStack(spacing: 0) {
                ForEach(model.runningApps) { app in
                    HStack(spacing: 13) {
                        appIcon(app.id)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.system(size: 14, weight: .medium))
                            Text(app.id).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Allow \(app.name)", isOn: Binding(get: { model.allowedIDs.contains(app.id) }, set: { model.setPermission(app, allowed: $0) })).labelsHidden().toggleStyle(.switch).accessibilityLabel("Allow \(app.name)")
                    }.padding(15)
                    if app.id != model.runningApps.last?.id { Divider().padding(.leading, 57) }
                }
                if model.runningApps.isEmpty { Text("Open an app, then choose Refresh apps.").font(.callout).padding(25) }
            }.contentSurface(cornerRadius: 18)
            shortcutCard
            Text("Works with text fields exposed by macOS Accessibility. Some browser editors and custom controls may not expose a supported field or selection. When direct replacement is unavailable, use Copy. Browser permission applies to the whole browser.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
        }
    }

    @ViewBuilder private func appIcon(_ bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 30, height: 30)
        } else { Image(systemName: "app").font(.title2).frame(width: 30, height: 30) }
    }


}

/// A value snapshot keeps a popup's measurement and displayed contents in sync.
struct SuggestionPresentation {
    let app: String
    let scope: String
    let busy: Bool
    let correction: Correction?
    let canApply: Bool
    let status: String
    let needsSetup: Bool

    @MainActor init(model: AppModel) {
        app = model.externalApp
        scope = model.externalScope
        busy = model.externalBusy
        correction = model.externalCorrection
        canApply = model.externalCanApply
        status = model.externalStatus
        needsSetup = model.externalNeedsSetup
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
    let dismiss: () -> Void
    let copy: () -> Void
    let apply: () -> Void
    let openSettings: () -> Void

    private var textWidth: CGFloat { width - SuggestionMetrics.padding * 2 }

    var body: some View {
        GlassGroup(spacing: 8) {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("English Correct", systemImage: "sparkles").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(.primary.opacity(0.055), in: Circle())
                        .contentShape(Circle())
                }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss suggestion")
            }
            Text([presentation.app, presentation.scope, "Local AI"].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Text(suggestion.editSummary).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(SuggestionMetrics.textHeight(suggestion.corrected, width: textWidth, fontSize: 15, lineSpacing: 4) >= SuggestionMetrics.maximumTextHeight
                         ? "Scroll for the full suggestion." : "Review before applying.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
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
                            ? "Replaces the reviewed text in your writing app."
                            : "Direct replacement is unavailable in this field. Use Copy instead.")
                        .help(presentation.canApply ? "Apply the correction" : "This field doesn't support replacement. Use Copy instead.")
                }
            }
            if !presentation.status.isEmpty {
                Text(presentation.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if presentation.needsSetup {
                Button("Open English Correct settings", action: openSettings).font(.caption)
            }
        }
        .padding(SuggestionMetrics.padding)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .glassSurface(cornerRadius: 20)
        }
        .foregroundStyle(.primary).tint(teal).glassAction()
    }
}
