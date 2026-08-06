import Foundation
import AppKit
import CoreGraphics

// MARK: - Keypress mode
//
// An alternative to Scroll/Audio mode: turning the knob sends a configurable keypress
// instead of scrolling. Right-turn and left-turn each have their own key, and holding a
// modifier (or the PowerMate button) while turning selects a different configured key.
// Defaults match the arrow keys already hardcoded for menu-mode rotation.

enum TurnDirection: String, CaseIterable, Codable {
    case right, left
}

enum TurnSlot: String, CaseIterable, Codable {
    case plain, press, shift, option, command

    var columnTitle: String {
        switch self {
        case .plain:   return "Turn"
        case .press:   return "Press +\nTurn"
        case .shift:   return "Shift +\nTurn"
        case .option:  return "Option +\nTurn"
        case .command: return "Command +\nTurn"
        }
    }
}

struct KeyBinding: Codable, Equatable {
    var keyCode: CGKeyCode
    var label: String
    // CGEventFlags.rawValue; stored as a plain UInt64 since CGEventFlags itself isn't Codable.
    var modifierFlags: UInt64

    var flags: CGEventFlags { CGEventFlags(rawValue: modifierFlags) }

    init(keyCode: CGKeyCode, label: String, modifierFlags: UInt64 = 0) {
        self.keyCode = keyCode
        self.label = label
        self.modifierFlags = modifierFlags
    }

    // Custom decoding so bindings saved before modifier capture existed (no "modifierFlags"
    // key) still load, defaulting to no modifiers instead of failing to decode entirely.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(CGKeyCode.self, forKey: .keyCode)
        label = try container.decode(String.self, forKey: .label)
        modifierFlags = try container.decodeIfPresent(UInt64.self, forKey: .modifierFlags) ?? 0
    }
}

/// Maps the modifiers a user held during key capture to CGEventFlags, for baking into the
/// synthesized keystroke (e.g. Control+Option+{ ). Only the standard shortcut modifiers are
/// captured — Fn is excluded since it already has its own meaning elsewhere in this app.
func cgEventFlags(from modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
    var flags: CGEventFlags = []
    if modifiers.contains(.command) { flags.insert(.maskCommand) }
    if modifiers.contains(.option)  { flags.insert(.maskAlternate) }
    if modifiers.contains(.control) { flags.insert(.maskControl) }
    if modifiers.contains(.shift)   { flags.insert(.maskShift) }
    return flags
}

/// The conventional macOS modifier-symbol prefix for a label, in HIG order: ⌃⌥⇧⌘.
private func modifierPrefix(for flags: CGEventFlags) -> String {
    var s = ""
    if flags.contains(.maskControl)   { s += "⌃" }
    if flags.contains(.maskAlternate) { s += "⌥" }
    if flags.contains(.maskShift)     { s += "⇧" }
    if flags.contains(.maskCommand)   { s += "⌘" }
    return s
}

// Mirrors the arrow keys already hardcoded for menu-mode rotation (see kUpArrow/kDownArrow
// in EventPosting.swift): right turn (delta > 0) -> Down, left turn (delta < 0) -> Up.
private let defaultBindingCode: [TurnDirection: CGKeyCode] = [.right: kDownArrow, .left: kUpArrow]
private let defaultBindingLabel: [TurnDirection: String]   = [.right: "↓ Down", .left: "↑ Up"]

private func defaultBinding(for direction: TurnDirection) -> KeyBinding {
    KeyBinding(keyCode: defaultBindingCode[direction]!, label: defaultBindingLabel[direction]!)
}

/// The stock keypress-mode bindings (arrow keys, matching legacy menu-mode rotation),
/// used as the default value for any AppSettings that hasn't customized them.
func defaultKeypressBindings() -> [TurnDirection: [TurnSlot: KeyBinding]] {
    var dict = [TurnDirection: [TurnSlot: KeyBinding]]()
    for direction in TurnDirection.allCases {
        var slots = [TurnSlot: KeyBinding]()
        for slot in TurnSlot.allCases {
            slots[slot] = defaultBinding(for: direction)
        }
        dict[direction] = slots
    }
    return dict
}

// MARK: - Legacy flat-key migration

// Only used once, the first time AppOverrides.swift builds `defaultSettings` on a machine
// that still has the old individual UserDefaults keys from before per-app settings existed.
func migrateLegacyKeypressBindings() -> [TurnDirection: [TurnSlot: KeyBinding]] {
    var dict = defaultKeypressBindings()
    for direction in TurnDirection.allCases {
        for slot in TurnSlot.allCases {
            let base = "keypress\(direction.rawValue.capitalized)\(slot.rawValue.capitalized)"
            if let code = defaults.object(forKey: base + "Code") as? Int,
               let label = defaults.string(forKey: base + "Label") {
                dict[direction, default: [:]][slot] = KeyBinding(keyCode: CGKeyCode(code), label: label)
            }
        }
    }
    return dict
}

// MARK: - AppSettings bindings access

extension AppSettings {
    func keypressBinding(for direction: TurnDirection, slot: TurnSlot) -> KeyBinding {
        keypressBindings[direction]?[slot] ?? defaultBinding(for: direction)
    }

    mutating func setKeypressBinding(_ binding: KeyBinding, for direction: TurnDirection, slot: TurnSlot) {
        keypressBindings[direction, default: [:]][slot] = binding
    }

    mutating func resetKeypressBindingsToDefaults() {
        keypressBindings = defaultKeypressBindings()
    }
}

// MARK: - Real-time modifier tracking

/// The real, currently-held keyboard modifier state — tracked by directly observing genuine
/// `.flagsChanged` events, rather than polling any OS-level shared/aggregate state table.
///
/// Two earlier approaches both polled a shared table at read time: first `NSEvent.modifierFlags`
/// (`CGEventSourceStateID.combinedSessionState`), then `CGEventSourceStateID.hidSystemState`.
/// Both are affected by posted synthetic key events — postKey posts a keyDown/keyUp for the
/// configured Turn key with an explicit `.flags` value (usually empty, since most recorded
/// bindings have no baked-in modifier of their own), and apparently that can still leak into
/// either table under the right timing, most noticeably right at a direction reversal (rapid
/// back-to-back reports). Tracking modifier state ourselves via NSEvent's monitor APIs sidesteps
/// this rather than hoping some other shared table happens to be immune: our posted Turn-mode
/// keys are regular (non-modifier) virtual keys, so they're always delivered as keyDown/keyUp,
/// never `.flagsChanged` — they can't feed back into this value at all. The only latency left is
/// the same small, unavoidable gap any two independent HID devices (the keyboard and the
/// PowerMate) have relative to each other.
private(set) var realModifierFlags: CGEventFlags = []

private var _globalModifierMonitor: Any?
private var _localModifierMonitor: Any?

/// Starts observing real keyboard modifier transitions. Call once at startup. A global NSEvent
/// monitor for keyboard-type events requires Accessibility permission, already required
/// elsewhere in this app for menu detection, so this doesn't prompt for anything new.
func startTrackingRealModifierFlags() {
    realModifierFlags = cgEventFlags(from: NSEvent.modifierFlags)
    _globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
        realModifierFlags = cgEventFlags(from: event.modifierFlags)
    }
    // Global monitors don't see events delivered to this app's own key window (e.g. while a
    // Configure... dialog is focused) — a local monitor covers that case too.
    _localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
        realModifierFlags = cgEventFlags(from: event.modifierFlags)
        return event
    }
}

/// Sends the configured key (from `settings`) for the given turn direction/slot, once per
/// unit of rotation.
func postTurnKeypress(delta: Int, slot: TurnSlot, settings: AppSettings) {
    let direction: TurnDirection = delta > 0 ? .right : .left
    let key = settings.keypressBinding(for: direction, slot: slot)
    for _ in 0 ..< abs(delta) {
        postKey(key.keyCode, flags: key.flags)
    }
    // Courtesy re-broadcast so anything else that reads the session-combined table (e.g. another
    // app's own NSEvent.modifierFlags check) also sees the truth, not whatever flags postKey's
    // calls above just left it with. Harmless even though we no longer rely on it ourselves.
    refreshSessionModifierState()
}

private func refreshSessionModifierState() {
    // A keyboard event whose virtual key is one of the standard modifier codes is delivered as
    // a .flagsChanged event regardless of the `keyDown` parameter — what actually updates the
    // tracked state is the event's own .flags field, which we set from the (uncorrupted)
    // hardware-state read above.
    guard let event = CGEvent(keyboardEventSource: kHIDEventSource, virtualKey: 0x38 /* kVK_Shift */, keyDown: true) else { return }
    event.flags = realModifierFlags
    event.post(tap: .cghidEventTap)
}

// MARK: - Key labeling

// Key codes (HIToolbox) for keys with no printable representation.
private let namedKeyLabels: [CGKeyCode: String] = [
    0x24: "⏎ Return", 0x4C: "⌤ Enter",
    0x30: "⇥ Tab", 0x31: "Space",
    0x33: "⌫ Delete", 0x75: "⌦ Fwd Del",
    0x35: "⎋ Escape", 0x72: "Help",
    0x73: "↖ Home", 0x77: "↘ End",
    0x74: "⇞ Pg Up", 0x79: "⇟ Pg Dn",
    0x7B: "← Left", 0x7C: "→ Right", 0x7D: "↓ Down", 0x7E: "↑ Up",
    0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
    0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
    0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
]

/// A short, human-readable label for the base key alone (no modifier prefix). Uses the
/// fully-unmodified character (ignoring Shift too) so e.g. Shift+1 labels as "1", not "!" —
/// the held Shift is shown separately via the ⇧ prefix instead of being baked into the glyph.
func keyLabel(for keyCode: CGKeyCode, event: NSEvent) -> String {
    if let named = namedKeyLabels[keyCode] { return named }
    if let chars = event.characters(byApplyingModifiers: []), !chars.isEmpty,
       !chars.unicodeScalars.contains(where: { $0.value < 0x20 }) {
        return chars.uppercased()
    }
    return "Key \(keyCode)"
}

// MARK: - Key capture control

/// A push button that, when clicked, records the next key pressed anywhere in the app and
/// shows it as its title. Only one button captures at a time; starting a new capture cancels
/// any other button still waiting.
final class KeyCaptureButton: NSButton {
    private static weak var activeCapture: KeyCaptureButton?

    var binding: KeyBinding {
        didSet { updateTitle() }
    }
    private var monitor: Any?

    init(binding: KeyBinding) {
        self.binding = binding
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startCapture)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateTitle() {
        title = binding.label
    }

    @objc private func startCapture() {
        KeyCaptureButton.activeCapture?.cancelCapture()
        KeyCaptureButton.activeCapture = self
        title = "Press a key…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.finishCapture(with: event)
            return nil // swallow so it doesn't also trigger e.g. Esc-cancels-the-alert
        }
    }

    private func finishCapture(with event: NSEvent) {
        stopMonitoring()
        // Escape cancels the capture instead of being recorded, matching the usual
        // shortcut-recorder convention.
        guard event.keyCode != 0x35 else {
            updateTitle()
            return
        }
        let keyCode = CGKeyCode(event.keyCode)
        let flags = cgEventFlags(from: event.modifierFlags)
        let label = modifierPrefix(for: flags) + keyLabel(for: keyCode, event: event)
        binding = KeyBinding(keyCode: keyCode, label: label, modifierFlags: flags.rawValue)
    }

    /// Cancels an in-progress capture (if any) without changing the current binding.
    func cancelCapture() {
        guard monitor != nil else { return }
        stopMonitoring()
        updateTitle()
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if KeyCaptureButton.activeCapture === self { KeyCaptureButton.activeCapture = nil }
    }
}

// MARK: - Custom keypress menu/pop-up titling

/// The title for a "Custom Keypress" menu item or pop-up entry: shows the recorded key once one
/// has been set, so the choice is visible without opening the capture dialog again.
func customKeypressTitle(_ binding: KeyBinding?) -> String {
    binding.map { "Custom Keypress: \($0.label)" } ?? "Custom Keypress..."
}

// MARK: - Single custom-keypress capture dialog

/// Presents a small dialog with one key-capture control for picking a single custom keypress —
/// used by the Click/Double-click/Long-press "Custom Keypress" actions, as opposed to the
/// per-direction/per-modifier grid `showConfigureKeypressMode` uses for Keypress mode. Seeded
/// with `current` if the action was already set to a custom keypress. Returns the recorded
/// binding, or nil if the dialog was cancelled.
@discardableResult
func showCaptureCustomKeypress(current: KeyBinding?) -> KeyBinding? {
    let alert = NSAlert()
    alert.messageText = "Custom Keypress"
    alert.informativeText = "Click the button below, then press the key you want sent. Hold Control/Option/Shift/Command as part of the press to include them, e.g. Control-Option-{ or Command-Shift-Q."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    let seed = current ?? KeyBinding(keyCode: kReturnKey, label: namedKeyLabels[kReturnKey] ?? "⏎ Return")
    let button = KeyCaptureButton(binding: seed)
    let width: CGFloat = 160
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 26))
    button.frame = NSRect(x: (width - 120) / 2, y: 0, width: 120, height: 26)
    container.addSubview(button)
    alert.accessoryView = container

    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    button.cancelCapture()

    return response == .alertFirstButtonReturn ? button.binding : nil
}

// MARK: - Configure Keypress Mode dialog

/// Presents the Configure Keypress Mode dialog seeded with `settings`'s current bindings.
/// Returns the updated settings if the user clicked Save or Reset to Defaults, or nil if
/// the dialog was cancelled.
@discardableResult
func showConfigureKeypressMode(for settings: AppSettings) -> AppSettings? {
    let alert = NSAlert()
    alert.messageText = "Configure Keypress Mode"
    alert.informativeText = "Set the key sent for each turn direction. Hold a modifier, or the PowerMate button, while turning to use that column instead of the plain \"Turn\" column.\n\nWhen recording a key, hold Control/Option/Shift/Command as part of the key press to include them, e.g. Control-Option-{ or Command-Shift-Q."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Reset to Defaults")

    let rowLabelWidth: CGFloat = 76
    let colWidth: CGFloat      = 96
    let colGap: CGFloat        = 8
    let rowHeight: CGFloat     = 26
    let rowGap: CGFloat        = 10
    let headerHeight: CGFloat  = 30
    let width = rowLabelWidth + colGap + CGFloat(TurnSlot.allCases.count) * (colWidth + colGap) - colGap

    func columnX(_ index: Int) -> CGFloat {
        rowLabelWidth + colGap + CGFloat(index) * (colWidth + colGap)
    }

    var captureButtons: [TurnDirection: [TurnSlot: KeyCaptureButton]] = [:]
    let gridHeight = headerHeight + rowGap + rowHeight * 2 + rowGap
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: gridHeight))

    // Rows are laid out bottom-up: Left turn, then Right turn, then the header.
    let leftY: CGFloat   = 0
    let rightY: CGFloat  = leftY + rowHeight + rowGap
    let headerY: CGFloat = rightY + rowHeight + rowGap

    for (i, slot) in TurnSlot.allCases.enumerated() {
        let label = NSTextField(wrappingLabelWithString: slot.columnTitle)
        label.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        label.alignment = .center
        label.frame = NSRect(x: columnX(i), y: headerY, width: colWidth, height: headerHeight)
        container.addSubview(label)
    }

    for (direction, y, title) in [(TurnDirection.right, rightY, "Right turn:"), (TurnDirection.left, leftY, "Left turn:")] {
        let rowLabel = NSTextField(labelWithString: title)
        rowLabel.frame = NSRect(x: 0, y: y + (rowHeight - 17) / 2, width: rowLabelWidth, height: 17)
        container.addSubview(rowLabel)

        var slotButtons: [TurnSlot: KeyCaptureButton] = [:]
        for (i, slot) in TurnSlot.allCases.enumerated() {
            let button = KeyCaptureButton(binding: settings.keypressBinding(for: direction, slot: slot))
            button.frame = NSRect(x: columnX(i), y: y, width: colWidth, height: rowHeight)
            container.addSubview(button)
            slotButtons[slot] = button
        }
        captureButtons[direction] = slotButtons
    }

    alert.accessoryView = container

    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()

    // Cancel any capture left running (e.g. Save/Cancel clicked mid-recording) so the local
    // event monitor doesn't leak and keep swallowing keystrokes after the dialog closes.
    for slots in captureButtons.values {
        for button in slots.values { button.cancelCapture() }
    }

    switch response {
    case .alertFirstButtonReturn:
        var updated = settings
        for (direction, slots) in captureButtons {
            for (slot, button) in slots {
                updated.setKeypressBinding(button.binding, for: direction, slot: slot)
            }
        }
        return updated
    case .alertThirdButtonReturn:
        var updated = settings
        updated.resetKeypressBindingsToDefaults()
        return updated
    default:
        return nil
    }
}
