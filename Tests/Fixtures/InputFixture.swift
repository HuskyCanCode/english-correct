import Cocoa

/// A separate app used for testing Accessibility against known, disposable inputs.
@main
final class InputFixture: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var plainField: NSTextField!
    private var multilineField: NSTextView!
    private var secureField: NSSecureTextField!

    static func main() {
        let app = NSApplication.shared
        let delegate = InputFixture()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "English Correct — Input Test"
        window.setAccessibilityIdentifier("input-fixture-window")
        window.center()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])

        let title = NSTextField(labelWithString: "Input detection test")
        title.font = .boldSystemFont(ofSize: 22)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(NSTextField(labelWithString: "These disposable fields contain sample text only."))

        stack.addArrangedSubview(NSTextField(labelWithString: "Editable single-line input"))
        plainField = NSTextField(string: "She go to school yesterday.")
        plainField.setAccessibilityLabel("Editable single-line input")
        plainField.setAccessibilityIdentifier("fixture-plain-input")
        plainField.font = .systemFont(ofSize: 16)
        stack.addArrangedSubview(plainField)
        plainField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(NSTextField(labelWithString: "Editable multiline input"))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        multilineField = NSTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 100))
        multilineField.isRichText = false
        multilineField.isEditable = true
        multilineField.isVerticallyResizable = true
        multilineField.autoresizingMask = [.width]
        multilineField.font = .systemFont(ofSize: 16)
        multilineField.string = "I has a question.\nWe was ready for the meeting."
        multilineField.setAccessibilityLabel("Editable multiline input")
        multilineField.setAccessibilityIdentifier("fixture-multiline-input")
        scroll.documentView = multilineField
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        stack.addArrangedSubview(NSTextField(labelWithString: "Password input — suggestions must stay hidden"))
        secureField = NSSecureTextField(string: "fixture-secret-do-not-read")
        secureField.setAccessibilityLabel("Secure password input")
        secureField.setAccessibilityIdentifier("fixture-secure-input")
        stack.addArrangedSubview(secureField)
        secureField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(NSTextField(labelWithString: "Read-only input — shortcut offers Copy; automatic suggestions stay hidden"))
        let readOnly = NSTextField(string: "This field cannot be edited.")
        readOnly.isEditable = false
        readOnly.isSelectable = true
        readOnly.setAccessibilityLabel("Read-only input")
        readOnly.setAccessibilityIdentifier("fixture-readonly-input")
        stack.addArrangedSubview(readOnly)
        readOnly.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for (title, action) in [
            ("Focus plain input", #selector(focusPlain)),
            ("Focus multiline", #selector(focusMultiline)),
            ("Focus password", #selector(focusSecure)),
            ("Reset samples", #selector(resetSamples))
        ] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            buttons.addArrangedSubview(button)
        }
        stack.addArrangedSubview(buttons)
        let selectionButtons = NSStackView()
        selectionButtons.orientation = .horizontal
        selectionButtons.spacing = 8
        for (title, action) in [
            ("Select second sentence", #selector(selectSecondSentence)),
            ("Use whole input", #selector(clearSelection))
        ] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            selectionButtons.addArrangedSubview(button)
        }
        stack.addArrangedSubview(selectionButtons)
        stack.addArrangedSubview(NSTextField(labelWithString: "Press Option–Command–E in an allowed input to check its selection or whole text."))
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeFirstResponder(plainField)
    }

    @objc private func focusPlain() { window.makeFirstResponder(plainField) }
    @objc private func focusMultiline() { window.makeFirstResponder(multilineField) }
    @objc private func focusSecure() { window.makeFirstResponder(secureField) }
    @objc private func selectSecondSentence() {
        window.makeFirstResponder(multilineField)
        let range = (multilineField.string as NSString).range(of: "We was ready for the meeting.")
        guard range.location != NSNotFound else { return }
        multilineField.setSelectedRange(range)
    }
    @objc private func clearSelection() {
        window.makeFirstResponder(multilineField)
        multilineField.setSelectedRange(NSRange(location: 0, length: 0))
    }
    @objc private func resetSamples() {
        plainField.stringValue = "She go to school yesterday."
        multilineField.string = "I has a question.\nWe was ready for the meeting."
        window.makeFirstResponder(plainField)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
