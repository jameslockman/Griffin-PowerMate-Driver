import Foundation
import AppKit

// MARK: - Editable text views

/// NSTextView subclass that fixes paste/copy/cut/selectAll inside NSAlert accessory views
/// and adds placeholder text support (NSTextView has no public placeholderString API).
class EditableTextView: NSTextView {
    var placeholderString: String?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder = placeholderString else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let inset = textContainerInset
        let origin = CGPoint(x: inset.width + 5, y: inset.height)
        placeholder.draw(at: origin, withAttributes: attrs)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)),     to: nil, from: self)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)),      to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)),       to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "z": return NSApp.sendAction(Selector(("undo:")),             to: nil, from: self)
        default:  return super.performKeyEquivalent(with: event)
        }
    }
}

/// NSTextField subclass that fixes paste/copy/cut/selectAll inside NSAlert accessory views.
/// NSAlert intercepts Cmd+key events before they reach the field editor; overriding
/// performKeyEquivalent routes them directly to the field editor's text view.
class EditableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)),      to: nil, from: self)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)),       to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)),        to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)),  to: nil, from: self)
        case "z": return NSApp.sendAction(Selector(("undo:")),              to: nil, from: self)
        default:  return super.performKeyEquivalent(with: event)
        }
    }
}

// MARK: - Script execution

/// Run a shell command in the background via /bin/sh -c.
/// Leading ~/ and mid-command ~/ are expanded to the user's home directory so
/// users can type ~/scripts/foo.sh instead of the full absolute path.
func runScript(_ command: String) {
    let trimmed = command.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let expanded = trimmed.replacingOccurrences(of: "~/", with: home + "/")
    DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", expanded]
        try? process.run()
    }
}

// MARK: - Configure scripts dialog

/// Show the Configure Scripts sheet with two text fields.
/// Long press runs script 1; shift + long press runs script 2.
func showConfigureScripts() {
    let alert = NSAlert()
    alert.messageText = ""
    alert.informativeText = ""
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    // Layout (AppKit: y=0 at bottom, increasing upward):
    //  0–70   scroll2 (multi-line text view)
    //  74–91  label2
    //  98–168 scroll1 (multi-line text view)
    //  172–189 label1
    //  197–227 description
    //  235–255 title
    let w: CGFloat   = 420
    let tvH: CGFloat = 70   // height of each script text view

    // Helper: a bordered, scrollable NSTextView pre-filled with text.
    func makeScriptView(text: String) -> NSScrollView {
        let sv = NSScrollView(frame: .zero)
        sv.borderType          = .bezelBorder
        sv.hasVerticalScroller = true
        sv.autohidesScrollers  = true
        let tv = EditableTextView(frame: .zero)
        tv.isEditable        = true
        tv.isRichText        = false
        tv.font              = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        tv.string            = text
        tv.placeholderString = "Enter shell script here..."
        sv.documentView      = tv
        return sv
    }

    let scroll2 = makeScriptView(text: defaults.string(forKey: kScript2) ?? "")
    scroll2.frame = NSRect(x: 0, y: 0, width: w, height: tvH)

    let label2 = NSTextField(labelWithString: "Shift + long press:")
    label2.frame = NSRect(x: 0, y: tvH + 4, width: w, height: 17)

    let scroll1 = makeScriptView(text: defaults.string(forKey: kScript1) ?? "")
    scroll1.frame = NSRect(x: 0, y: tvH + 28, width: w, height: tvH)

    let label1 = NSTextField(labelWithString: "Long press:")
    label1.frame = NSRect(x: 0, y: tvH * 2 + 32, width: w, height: 17)

    let desc = NSTextField(wrappingLabelWithString: "Enter shell commands to run on long press. Each line is a separate command.\nHold Shift while pressing to run the second script.\nIf you leave the fields blank, no script will be run.")
    desc.font      = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    desc.textColor = .labelColor
    desc.frame     = NSRect(x: 0, y: tvH * 2 + 57, width: w, height: 55)

    let title = NSTextField(labelWithString: "Configure Scripts")
    title.font      = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    title.alignment = .center
    title.frame     = NSRect(x: 0, y: tvH * 2 + 120, width: w, height: 20)

    let totalH = tvH * 2 + 140
    let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: totalH))
    for v in [title, desc, label1, scroll1, label2, scroll2] { container.addSubview(v) }
    alert.accessoryView = container

    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn {
        let tv1 = (scroll1.documentView as? NSTextView)?.string ?? ""
        let tv2 = (scroll2.documentView as? NSTextView)?.string ?? ""
        defaults.set(tv1, forKey: kScript1)
        defaults.set(tv2, forKey: kScript2)
    }
}
