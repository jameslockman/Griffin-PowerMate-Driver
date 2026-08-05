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
        // Bounded (not just `draw(at:)`) so a long default-script placeholder clips to the
        // view instead of overflowing past its edge.
        let rect = NSRect(x: origin.x, y: origin.y, width: max(0, bounds.width - origin.x - 4), height: max(0, bounds.height - origin.y))
        (placeholder as NSString).draw(in: rect, withAttributes: attrs)
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

/// Shared two-text-field script dialog, used for both the global "Configure Scripts..." sheet
/// and the per-app override sheet. Returns the two typed script bodies verbatim (empty string
/// if a field was left blank), or nil if the dialog was cancelled — callers decide what "blank"
/// means for their case.
private func showScriptDialog(
    title: String,
    description: String,
    label1: String, initial1: String, placeholder1: String,
    label2: String, initial2: String, placeholder2: String
) -> (String, String)? {
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
    func makeScriptView(text: String, placeholder: String) -> NSScrollView {
        let sv = NSScrollView(frame: .zero)
        sv.borderType          = .bezelBorder
        sv.hasVerticalScroller = true
        sv.autohidesScrollers  = true
        let tv = EditableTextView(frame: .zero)
        tv.isEditable        = true
        tv.isRichText        = false
        tv.font              = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        tv.string            = text
        tv.placeholderString = placeholder
        sv.documentView      = tv
        return sv
    }

    let scroll2 = makeScriptView(text: initial2, placeholder: placeholder2)
    scroll2.frame = NSRect(x: 0, y: 0, width: w, height: tvH)

    let label2Field = NSTextField(labelWithString: label2)
    label2Field.frame = NSRect(x: 0, y: tvH + 4, width: w, height: 17)

    let scroll1 = makeScriptView(text: initial1, placeholder: placeholder1)
    scroll1.frame = NSRect(x: 0, y: tvH + 28, width: w, height: tvH)

    let label1Field = NSTextField(labelWithString: label1)
    label1Field.frame = NSRect(x: 0, y: tvH * 2 + 32, width: w, height: 17)

    let desc = NSTextField(wrappingLabelWithString: description)
    desc.font      = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    desc.textColor = .labelColor
    desc.frame     = NSRect(x: 0, y: tvH * 2 + 57, width: w, height: 55)

    let titleField = NSTextField(labelWithString: title)
    titleField.font      = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    titleField.alignment = .center
    titleField.frame     = NSRect(x: 0, y: tvH * 2 + 120, width: w, height: 20)

    let totalH = tvH * 2 + 140
    let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: totalH))
    for v in [titleField, desc, label1Field, scroll1, label2Field, scroll2] { container.addSubview(v) }
    alert.accessoryView = container

    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let tv1 = (scroll1.documentView as? NSTextView)?.string ?? ""
    let tv2 = (scroll2.documentView as? NSTextView)?.string ?? ""
    return (tv1, tv2)
}

/// Show the Configure Scripts sheet with two text fields.
/// Long press runs script 1; shift + long press runs script 2.
func showConfigureScripts() {
    guard let (s1, s2) = showScriptDialog(
        title: "Configure Scripts",
        description: "Enter shell commands to run on long press. Each line is a separate command.\nHold Shift while pressing to run the second script.\nIf you leave the fields blank, no script will be run.",
        label1: "Long press:", initial1: defaults.string(forKey: kScript1) ?? "", placeholder1: "Enter shell script here...",
        label2: "Shift + long press:", initial2: defaults.string(forKey: kScript2) ?? "", placeholder2: "Enter shell script here..."
    ) else { return }
    defaults.set(s1, forKey: kScript1)
    defaults.set(s2, forKey: kScript2)
}

/// Show the per-app "Configure Script" sheet. Unlike the global version, a blank field here
/// means "no override — use the default script", not "run nothing": the current global default
/// (from Configure Scripts...) is shown as placeholder text in each empty field, so it's clear
/// what will actually run for this app if you don't type anything. Returns the two overrides
/// (nil where left blank) or nil if the dialog was cancelled.
func showConfigureAppScripts(current1: String?, current2: String?) -> (String?, String?)? {
    let default1 = defaults.string(forKey: kScript1) ?? ""
    let default2 = defaults.string(forKey: kScript2) ?? ""
    guard let (s1, s2) = showScriptDialog(
        title: "Configure Script for This App",
        description: "Enter shell commands to run on long press for this app only. Each line is a separate command.\nHold Shift while pressing to run the second script.\nLeave a field blank to use the default script shown as its placeholder (set via the main \"Configure Scripts...\" menu item).",
        label1: "Long press:", initial1: current1 ?? "", placeholder1: default1.isEmpty ? "Enter shell script here..." : "Default: \(default1)",
        label2: "Shift + long press:", initial2: current2 ?? "", placeholder2: default2.isEmpty ? "Enter shell script here..." : "Default: \(default2)"
    ) else { return nil }
    return (s1.isEmpty ? nil : s1, s2.isEmpty ? nil : s2)
}
