import Foundation
import AppKit
import ApplicationServices

// MARK: - Headless self-tests
//
// Verbs that exercise the hold-key primitives without a PowerMate attached and without
// starting the agent proper. They run before the driver seizes the device or the status item
// is built, so they work while the normally-installed agent is quit but everything else about
// the machine (the stored settings blob, the Accessibility grant) is untouched.
//
//   PowerMateAgent --selftest-hold <seconds>       press the configured hold key, wait, release
//   PowerMateAgent --selftest-decode               decode the live settings blob and report holdKey
//   PowerMateAgent --selftest-overrides            resolve a per-app override against the default
//                                                   and check that holdKey/pressTurnOncePerPress
//                                                   are inherited
//   PowerMateAgent --selftest-capture              exercises ModifierCaptureState (the bare-
//                                                   modifier-vs-prefix disambiguation behind the
//                                                   hold-key capture dialog) against synthetic
//                                                   transitions — this can be checked from a bare
//                                                   `swift build` binary without a real keyboard
//                                                   or a running run loop, unlike the dialog
//                                                   itself, whose local NSEvent monitor only
//                                                   fires for genuinely-dispatched events
//   PowerMateAgent --selftest-capture-button       drives the real KeyCaptureButton decision
//                                                   code (not just the ModifierCaptureState
//                                                   sub-piece) with synthetic NSEvents, to check
//                                                   whether a modifier-held-then-combo report is
//                                                   this app's logic or something in how AppKit
//                                                   dispatches real events to a local monitor
//
// All print what they did and exit 0; anything else returns and startup continues as usual.

/// Runs a `--selftest-*` verb if one was passed and exits the process. Returns normally when
/// the agent was launched without one.
func runSelfTestIfRequested() {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let verb = args.first else { return }
    switch verb {
    case "--selftest-hold":
        runHoldSelfTest(seconds: args.dropFirst().first.flatMap(Double.init) ?? 5)
    case "--selftest-decode":
        runDecodeSelfTest()
    case "--selftest-overrides":
        runOverridesSelfTest()
    case "--selftest-capture-button":
        runCaptureButtonSelfTest()
    case "--selftest-capture":
        runCaptureSelfTest()
    default:
        return
    }
    exit(0)
}

private func runHoldSelfTest(seconds: Double) {
    // The global default, not currentSettings(): a self-test run from a terminal would
    // otherwise resolve against whatever app happens to be frontmost, which is not what the
    // operator configured and makes the measurement non-reproducible.
    guard let binding = defaultSettings.holdKey else {
        print("selftest-hold: no hold key configured (defaultAppSettings.holdKey is nil) — nothing to press.")
        exit(1)
    }
    let isModifier = modifierFlag(forKeyCode: binding.keyCode) != nil
    print("selftest-hold: AXIsProcessTrusted=\(AXIsProcessTrusted())")
    print("selftest-hold: key=\(binding.label) keyCode=0x\(String(binding.keyCode, radix: 16, uppercase: true)) "
          + "flags=0x\(String(binding.modifierFlags, radix: 16, uppercase: true)) "
          + "eventType=\(isModifier ? ".flagsChanged" : ".keyDown/.keyUp")")
    print("selftest-hold: DOWN at \(Date())")
    postKeyDown(binding.keyCode, flags: binding.flags)
    Thread.sleep(forTimeInterval: seconds)
    postKeyUp(binding.keyCode, flags: binding.flags)
    print("selftest-hold: UP at \(Date()) (held \(seconds)s)")
}

private func runCaptureSelfTest() {
    // Drives ModifierCaptureState with the exact sequences a real capture session produces,
    // catching the bug a previous version of this feature shipped with: finalizing a bare
    // modifier (e.g. Fn) the instant it went down, tearing down the event monitor before a
    // key pressed while it was held (e.g. F5, to record Fn+F5) ever arrived. Every case here
    // is checkable without AppKit event dispatch, which is the point — that bug shipped
    // because the equivalent logic previously lived inside the NSEvent monitor closure, where
    // it could only be exercised by a human pressing real keys in the live dialog.
    var anyFailed = false

    func check(_ name: String, _ actual: KeyBinding?, expected: KeyBinding?) {
        if actual == expected {
            print("selftest-capture: PASS \(name) — expected \(String(describing: expected)), got \(String(describing: actual))")
        } else {
            print("selftest-capture: FAIL \(name) — expected \(String(describing: expected)), got \(String(describing: actual))")
            anyFailed = true
        }
    }

    let fn = (keyCode: CGKeyCode(0x3F), label: "Fn")
    let shift = (keyCode: CGKeyCode(0x38), label: "Shift")
    let command = (keyCode: CGKeyCode(0x37), label: "Command")

    // Case 1: modifier down, then its own up with nothing in between -- a bare modifier alone.
    do {
        var state = ModifierCaptureState()
        let r1 = state.handleModifierTransition(keyCode: fn.keyCode, label: fn.label, isDown: true)
        check("Fn down alone", r1, expected: nil)
        let r2 = state.handleModifierTransition(keyCode: fn.keyCode, label: fn.label, isDown: false)
        check("Fn up alone -> finalizes bare Fn", r2, expected: KeyBinding(keyCode: fn.keyCode, label: fn.label))
    }

    // Case 2: modifier down, a real key interrupts, then the modifier's up arrives late --
    // must NOT retroactively finalize as a bare modifier. This is the exact bug: previously
    // the down transition alone finalized and tore down the monitor, so F5 (or any other key)
    // pressed next never had a chance to be seen at all.
    do {
        var state = ModifierCaptureState()
        _ = state.handleModifierTransition(keyCode: fn.keyCode, label: fn.label, isDown: true)
        state.interruptWithRealKey() // a real .keyDown arrived, e.g. F5
        let r = state.handleModifierTransition(keyCode: fn.keyCode, label: fn.label, isDown: false)
        check("Fn up after a real key interrupted -> no bare-Fn binding", r, expected: nil)
    }

    // Case 3: a different modifier (Shift), same shape as case 1 -- not special-cased to Fn.
    do {
        var state = ModifierCaptureState()
        _ = state.handleModifierTransition(keyCode: shift.keyCode, label: shift.label, isDown: true)
        let r = state.handleModifierTransition(keyCode: shift.keyCode, label: shift.label, isDown: false)
        check("Shift up alone -> finalizes bare Shift", r, expected: KeyBinding(keyCode: shift.keyCode, label: shift.label))
    }

    // Case 4: switching which modifier is held before releasing -- the most recently pressed
    // one is the candidate; releasing a stale one that's no longer pending doesn't finalize.
    do {
        var state = ModifierCaptureState()
        _ = state.handleModifierTransition(keyCode: fn.keyCode, label: fn.label, isDown: true)
        _ = state.handleModifierTransition(keyCode: command.keyCode, label: command.label, isDown: true)
        let staleUp = state.handleModifierTransition(keyCode: fn.keyCode, label: fn.label, isDown: false)
        check("stale Fn-up after switching to Command -> no binding", staleUp, expected: nil)
        let realUp = state.handleModifierTransition(keyCode: command.keyCode, label: command.label, isDown: false)
        check("Command up (the actually-pending one) -> finalizes bare Command", realUp, expected: KeyBinding(keyCode: command.keyCode, label: command.label))
    }

    // Case 5: an up transition with nothing ever pending (e.g. a monitor that just started
    // while a modifier happened to already be held) must not finalize anything.
    do {
        var state = ModifierCaptureState()
        let r = state.handleModifierTransition(keyCode: shift.keyCode, label: shift.label, isDown: false)
        check("up with nothing pending -> no binding", r, expected: nil)
    }

    if anyFailed {
        exit(1)
    }
}

private func runCaptureButtonSelfTest() {
    // Drives KeyCaptureButton.processCaptureEvent directly with synthetic NSEvents (built via
    // NSEvent.keyEvent(with:...), which needs no run loop or real keyboard) instead of just the
    // ModifierCaptureState sub-piece --selftest-capture covers. This is the actual code path
    // the live dialog runs, so a bug here (as opposed to in the pure state machine) would show
    // up here too. Exists because a modifier-held-then-combo report ("Option+T only records
    // Option") needs to be triaged: is the bug in this app's decision logic, or somewhere in
    // how AppKit dispatches real hardware events to a local monitor (which this test cannot
    // exercise, since it calls the decision function directly, bypassing NSEvent dispatch)?
    var anyFailed = false

    func check(_ name: String, _ actual: KeyBinding, expectedKeyCode: CGKeyCode, expectedFlags: CGEventFlags) {
        if actual.keyCode == expectedKeyCode && actual.flags == expectedFlags {
            print("selftest-capture-button: PASS \(name) — got keyCode=0x\(String(actual.keyCode, radix: 16, uppercase: true)) label=\(actual.label) flags=0x\(String(actual.flags.rawValue, radix: 16))")
        } else {
            print("selftest-capture-button: FAIL \(name) — expected keyCode=0x\(String(expectedKeyCode, radix: 16, uppercase: true)) flags=0x\(String(expectedFlags.rawValue, radix: 16)), "
                  + "got keyCode=0x\(String(actual.keyCode, radix: 16, uppercase: true)) label=\(actual.label) flags=0x\(String(actual.flags.rawValue, radix: 16))")
            anyFailed = true
        }
    }

    func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, chars: String = "") -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifierFlags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: keyCode)!
    }

    // Case: hold Option, press T while it's held, release both -- the exact shape of the
    // "option-t" report. Must produce a combo (keyCode 0x11 "T", .maskAlternate), not a bare
    // "Option" binding.
    do {
        let button = KeyCaptureButton(binding: KeyBinding(keyCode: 0, label: "seed"))
        button.capturesModifiersAlone = true
        _ = button.processCaptureEvent(keyEvent(.flagsChanged, keyCode: 0x3A, modifierFlags: .option))
        _ = button.processCaptureEvent(keyEvent(.keyDown, keyCode: 0x11, modifierFlags: .option, chars: "t"))
        check("Option+T -> combo, not bare Option", button.binding, expectedKeyCode: 0x11, expectedFlags: .maskAlternate)
        // The later releases (T up isn't in the mask at all; Option up arrives after capture
        // already finalized) must not retroactively change anything.
        _ = button.processCaptureEvent(keyEvent(.flagsChanged, keyCode: 0x3A, modifierFlags: []))
        check("Option+T -> unchanged by late Option-up", button.binding, expectedKeyCode: 0x11, expectedFlags: .maskAlternate)
    }

    // Case: bare Option alone (no other key), for contrast with the combo case above -- both
    // must be reachable from the same button/state, just via a different event sequence.
    do {
        let button = KeyCaptureButton(binding: KeyBinding(keyCode: 0, label: "seed"))
        button.capturesModifiersAlone = true
        _ = button.processCaptureEvent(keyEvent(.flagsChanged, keyCode: 0x3A, modifierFlags: .option))
        _ = button.processCaptureEvent(keyEvent(.flagsChanged, keyCode: 0x3A, modifierFlags: []))
        check("bare Option alone -> Option binding", button.binding, expectedKeyCode: 0x3A, expectedFlags: [])
    }

    if anyFailed {
        exit(1)
    }
}

private func runDecodeSelfTest() {
    // Reads the same UserDefaults key AppOverrides.swift reads, and decodes it with the same
    // AppSettings.init(from:). The point is to prove that a blob written before holdKey existed
    // still decodes — as itself, not as a silently discarded default instance.
    guard let data = defaults.data(forKey: "defaultAppSettings") else {
        print("selftest-decode: no stored defaultAppSettings blob (fresh install) — nothing to check.")
        exit(1)
    }
    print("selftest-decode: stored blob = \(data.count) bytes")
    print("selftest-decode: contains \"holdKey\" key = \(String(data: data, encoding: .utf8)?.contains("holdKey") ?? false)")
    do {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        print("selftest-decode: decoded OK")
        print("selftest-decode:   holdKey           = \(decoded.holdKey.map { "\($0.label) (0x\(String($0.keyCode, radix: 16, uppercase: true)))" } ?? "nil")")
        // Fields that prove the rest of the blob survived rather than falling back wholesale.
        print("selftest-decode:   mode              = \(decoded.mode.rawValue)")
        print("selftest-decode:   clickAction       = \(decoded.clickAction)")
        print("selftest-decode:   longPressAction   = \(decoded.longPressAction)")
        print("selftest-decode:   keypressBindings  = \(decoded.keypressBindings.count) directions")
    } catch {
        print("selftest-decode: FAILED — \(error)")
        exit(1)
    }
}

private func runOverridesSelfTest() {
    // Constructed entirely in memory — no `defaults` or `NSWorkspace` reads. That's the point
    // of extracting resolvedSettings(override:base:) as a pure function: this verb can prove
    // the independent-snapshot rule from a bare `swift build` binary, where --selftest-decode
    // and --selftest-hold legitimately cannot (they depend on the installed app's UserDefaults
    // domain).
    var base = AppSettings()
    base.holdKey = KeyBinding(keyCode: 0x3F, label: "Fn")
    base.pressTurnOncePerPress = true
    base.mode = .scroll

    var override = AppSettings()
    override.mode = .keypress
    // Deliberately different from base's values, to prove the override's own values survive
    // rather than being silently replaced by the base's.
    override.holdKey = KeyBinding(keyCode: 0x38, label: "Shift")
    override.pressTurnOncePerPress = false

    var anyFailed = false

    func check(_ name: String, _ actual: Bool, expected: String, actualDescription: String) {
        if actual {
            print("selftest-overrides: PASS \(name) — expected \(expected), got \(actualDescription)")
        } else {
            print("selftest-overrides: FAIL \(name) — expected \(expected), got \(actualDescription)")
            anyFailed = true
        }
    }

    // Test 1: holdKey and pressTurnOncePerPress each have their own per-app control now (the
    // Long press pop-up's "Hold Key While Pressed..." item and "Press + Turn Fires Once Per
    // Press" checkbox, in AppOverridesWindow.swift), so both follow the same
    // independent-snapshot rule as every other AppSettings field — the override's own values
    // must survive, not the base's.
    let resolved1 = resolvedSettings(override: override, base: base)
    check("override-owned holdKey preserved", resolved1.holdKey == override.holdKey,
          expected: "\(String(describing: override.holdKey))", actualDescription: "\(String(describing: resolved1.holdKey))")
    check("override-owned pressTurnOncePerPress preserved", resolved1.pressTurnOncePerPress == override.pressTurnOncePerPress,
          expected: "\(override.pressTurnOncePerPress)", actualDescription: "\(resolved1.pressTurnOncePerPress)")

    // Test 2: a field the override genuinely owns (mode) is still respected — the base must
    // not clobber it.
    check("override-owned mode preserved", resolved1.mode == .keypress,
          expected: ".keypress", actualDescription: "\(resolved1.mode)")

    // Test 3: a nil override returns the base unchanged.
    let resolved2 = resolvedSettings(override: nil, base: base)
    check("nil override -> base.mode", resolved2.mode == base.mode,
          expected: "\(base.mode)", actualDescription: "\(resolved2.mode)")
    check("nil override -> base.holdKey", resolved2.holdKey == base.holdKey,
          expected: "\(String(describing: base.holdKey))", actualDescription: "\(String(describing: resolved2.holdKey))")
    check("nil override -> base.pressTurnOncePerPress", resolved2.pressTurnOncePerPress == base.pressTurnOncePerPress,
          expected: "\(base.pressTurnOncePerPress)", actualDescription: "\(resolved2.pressTurnOncePerPress)")

    if anyFailed {
        exit(1)
    }
}
