#!/usr/bin/env swift
//
//  PowerMateAgent — runs in the background and turns PowerMate input into
//  keyboard/scroll events that any application can receive.
//
//  Rotation     → scroll, or arrow keys when a menu/submenu is focused,
//                 or system volume when audio controls are enabled
//  Click        → configurable (left mouse, mute/unmute, play/pause, or a custom keypress),
//                 or Return when a menu is focused. Same behavior in every rotation mode.
//  Double-click → configurable the same way as click (off by default).
//  Long press   → right mouse button by default, but also configurable (left-click,
//                 double-click, toggle mode, toggle fine scroll, run script, custom keypress)
//
//  Menu and submenu detection uses the Accessibility API so rotation and click
//  work in submenus without leaving "menu mode". Enable Accessibility for that.
//  Requires Input Monitoring (System Settings → Privacy & Security).
//

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import CoreAudio
import PowerMateDriver

// MARK: - Self-test verbs

// Handled before anything else so `--selftest-hold` / `--selftest-decode` never seize the HID
// device or build a status item; returns immediately for a normal launch.
runSelfTestIfRequested()

// MARK: - Driver

let driver = PowerMateDriver()

// MARK: - Button and rotation state

var isButtonDown = false
var lastRotationTime: CFTimeInterval = 0

// Tracks whether rotation occurred while the button was held, so the subsequent
// button-up click can be suppressed (avoiding an unintended mute/click after track skip).
private var _didRotateWhileButtonDown = false

// MARK: - Hold key

// The binding onButtonDown actually pressed, so onButtonUp releases exactly that key. Resolving
// currentSettings() again on release would read the frontmost app's settings, and the frontmost
// app routinely changes during a hold (a dictation target takes focus) — that path leaves the
// originally pressed key down forever.
private var _heldKeyBinding: KeyBinding?

// Whether the press being resolved right now became a hold-key press. The driver reports click,
// double-click and long press only AFTER release, so without this they would all fire on top of
// the hold. Rewritten on every button-down (false until the hold key actually arms), which also
// keeps it correct for a double-click, resolved after the second press.
private var _holdKeySuppressesGestures = false

// The scheduled press of the hold key. Non-nil only during the arming delay; cancelled by a
// button-up that arrives first, which is what turns that press into an ordinary click.
private var _holdKeyArmWorkItem: DispatchWorkItem?

/// How long the button must stay down before the hold key is pressed, when a click or
/// double-click action is configured alongside it. Anything released sooner is a tap and
/// resolves through the driver's normal click path; anything held longer is a hold. Well under
/// the driver's 0.4 s long-press threshold, so a long press is always a hold and never both.
/// With click and double-click both set to None there is nothing to tell apart, and the key
/// is pressed immediately — no delay on push-to-talk for anyone who doesn't need it.
private let kHoldKeyArmDelay: TimeInterval = 0.2

/// Schedules (or, when no tap could be pending, immediately performs) the press of the
/// configured hold key. Does nothing when no hold key is set.
private func beginHoldKey() {
    let settings = currentSettings()
    _holdKeySuppressesGestures = false
    guard let binding = settings.holdKey else { return }
    guard settings.clickAction != .none || settings.doubleClickAction != .none else {
        armHoldKey(binding)
        return
    }
    let work = DispatchWorkItem { armHoldKey(binding) }
    _holdKeyArmWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + kHoldKeyArmDelay, execute: work)
}

/// Presses the hold key and remembers it for the matching release. From here on the press in
/// progress is a hold, so the gestures the driver reports on release are suppressed.
private func armHoldKey(_ binding: KeyBinding) {
    _holdKeyArmWorkItem = nil
    _holdKeySuppressesGestures = true
    _heldKeyBinding = binding
    postKeyDown(binding.keyCode, flags: binding.flags)
}

/// Releases the key armHoldKey pressed, or cancels the press if it was still pending. Safe to
/// call when no hold is in flight, which is what makes it usable as the disconnect cleanup — a
/// yanked cable must not leave Fn stuck down.
func endHoldKey() {
    _holdKeyArmWorkItem?.cancel()
    _holdKeyArmWorkItem = nil
    guard let binding = _heldKeyBinding else { return }
    _heldKeyBinding = nil
    postKeyUp(binding.keyCode, flags: binding.flags)
}

// Keypress Mode modifier-slot debounce: realModifierFlags occasionally still misreads a held
// modifier as released for a single tick (a residual timing race — see its doc comment), most
// noticeably right at a direction reversal. Since that corruption can only produce a false
// negative (looks released when it's actually still held), never a false positive, a freshly
// *detected* modifier is always honored immediately, but a sudden drop back to "no modifier"
// only takes effect after it's read absent for a couple of consecutive ticks in a row — a
// genuine release stays released; a transient glitch doesn't.
private var _stickyKeypressSlot: TurnSlot = .plain
private var _keypressModifierAbsentStreak = 0
private let kKeypressModifierDebounceTicks = 2
/// A gap longer than this between rotation events means turning actually stopped (continuous
/// turning generates reports far more often than this, even slowly) — treated as the start of a
/// new gesture, resetting _stickyKeypressSlot rather than carrying it over from before the pause.
private let kKeypressGestureGapThreshold: CFTimeInterval = 0.3
// Accumulates rotation units while button is held; a track skip fires every kTrackSkipThreshold units.
private var _trackSkipAccumulator = 0
private let kTrackSkipThreshold = 5

// MARK: - Driver callbacks

driver.onRotate = { delta, rate in
    let now = CFAbsoluteTimeGetCurrent()
    if lastRotationTime > 0 && now - lastRotationTime > kKeypressGestureGapThreshold {
        _stickyKeypressSlot = .plain
        _keypressModifierAbsentStreak = 0
    }
    lastRotationTime = now
    startThrob()
    // Resolved once per event: the frontmost app's override, or the global default.
    let settings = currentSettings()
    if isButtonDown {
        _didRotateWhileButtonDown = true
        // In Keypress mode, holding the button while turning sends the configured
        // "Press + Turn" key instead of the default track-skip behavior.
        if settings.mode == .keypress {
            postTurnKeypress(delta: delta, slot: .press, settings: settings)
            return
        }
        _trackSkipAccumulator += delta
        while abs(_trackSkipAccumulator) >= kTrackSkipThreshold {
            let keyType: Int32 = _trackSkipAccumulator > 0 ? 17 : 18  // NX_KEYTYPE_NEXT / NX_KEYTYPE_PREVIOUS
            postMediaKey(keyType, keyDown: true)
            postMediaKey(keyType, keyDown: false)
            _trackSkipAccumulator -= _trackSkipAccumulator > 0 ? kTrackSkipThreshold : -kTrackSkipThreshold
        }
        return
    }
    if useMenuBehavior() {
        let arrowKey: CGKeyCode = delta > 0 ? kDownArrow : kUpArrow
        for _ in 0 ..< abs(delta) {
            postKey(arrowKey)
        }
        if isMenuMode {
            menuModeTimeout?.cancel()
            let work = DispatchWorkItem { isMenuMode = false }
            menuModeTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + menuModeTimeoutInterval, execute: work)
        }
    } else if useAudioBehavior(mode: settings.mode) {
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        // audioStepSwapped flips the default: normally no-modifier=standard, Shift=fine;
        // when swapped, no-modifier=fine, Shift=standard.
        let fine = settings.audioStepSwapped ? !shiftHeld : shiftHeld
        let up = delta > 0
        // fine mode: one fine step per tick regardless of velocity.
        // standard mode: abs(delta) presses so faster spinning moves volume faster.
        let presses = fine ? 1 : abs(delta)
        adjustVolume(up: up, fine: fine, presses: presses)
    } else if useKeypressBehavior(mode: settings.mode) {
        // realModifierFlags (not NSEvent.modifierFlags) — immune to the modifier state our own
        // postTurnKeypress calls below can otherwise corrupt; see its doc comment.
        let flags       = realModifierFlags
        let shiftHeld   = flags.contains(.maskShift)
        let optionHeld  = flags.contains(.maskAlternate)
        let commandHeld = flags.contains(.maskCommand)
        let freshSlot: TurnSlot = commandHeld ? .command : optionHeld ? .option : shiftHeld ? .shift : .plain

        // Debounce a drop back to .plain — see _stickyKeypressSlot's comment above. Any freshly
        // detected modifier is trusted immediately regardless.
        let slot: TurnSlot
        if freshSlot != .plain {
            slot = freshSlot
            _stickyKeypressSlot = freshSlot
            _keypressModifierAbsentStreak = 0
        } else if _stickyKeypressSlot != .plain && _keypressModifierAbsentStreak < kKeypressModifierDebounceTicks {
            slot = _stickyKeypressSlot
            _keypressModifierAbsentStreak += 1
        } else {
            slot = .plain
            _stickyKeypressSlot = .plain
            _keypressModifierAbsentStreak = 0
        }
        postTurnKeypress(delta: delta, slot: slot, settings: settings)
    } else {
        let shiftHeld  = NSEvent.modifierFlags.contains(.shift)
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        // Option toggles fine/coarse; fineScrollEnabled sets the default.
        let fine = settings.fineScrollEnabled != optionHeld
        // Shift toggles horizontal/vertical; scrollAxesSwapped sets the default.
        // Shift+Option: switch axis AND force fine mode.
        let horizontal = settings.scrollAxesSwapped ? !shiftHeld : shiftHeld
        let effectiveFine = (shiftHeld && optionHeld) ? true : fine
        postScroll(delta: delta, horizontal: horizontal, fine: effectiveFine, reversed: settings.scrollReversed)
    }
}

// Click and double-click actions apply the same regardless of rotation mode (Scroll/Audio/
// Keypress) — only an active menu/submenu (via Accessibility) overrides them, so PowerMate can
// still confirm menu selections.
driver.onClick = {
    // Defer by one run-loop cycle so that any rotation in the same HID report is processed
    // first (the driver handles button-change before rotation within each report block).
    // This ensures _didRotateWhileButtonDown is set before we decide whether to act.
    DispatchQueue.main.async {
        guard !_didRotateWhileButtonDown, !_holdKeySuppressesGestures else { return }
        if useMenuBehavior() {
            postKey(kReturnKey)
            // Do not exit menu mode here: a submenu may open and we need to keep sending arrow keys.
            // Menu mode will exit on the 5-second timeout when the user stops rotating.
        } else {
            exitMenuMode()
            performClickAction(currentSettings().clickAction)
        }
    }
}

driver.onDoubleClick = {
    DispatchQueue.main.async {
        guard !_didRotateWhileButtonDown, !_holdKeySuppressesGestures else { return }
        exitMenuMode()
        performClickAction(currentSettings().doubleClickAction)
    }
}

// Skip the double-click detection wait unless a real double-click action is configured (so
// single clicks stay instantaneous for anyone not using this feature), and while a menu is
// focused (so PowerMate's Return-key confirmation isn't delayed by the detection window).
driver.shouldWaitForDoubleClick = {
    !useMenuBehavior() && currentSettings().doubleClickAction != .none
}

driver.onLongPress = {
    DispatchQueue.main.async {
        guard !_didRotateWhileButtonDown, !_holdKeySuppressesGestures else { return }
        // The action itself is resolved per-app (frontmost app's override, or the default).
        let settings = currentSettings()
        switch settings.longPressAction {
        case .rightClick:
            enterMenuMode()
            postMouseClick(button: .right)
        case .leftClick:
            enterMenuMode()
            postMouseClick(button: .left)
        case .doubleClick:
            enterMenuMode()
            DispatchQueue.main.async {
                let cocoa = NSEvent.mouseLocation
                let location = cocoaToQuartz(cocoa)
                postDoubleClick(at: location)
            }
        case .toggleMode(let pair):
            DispatchQueue.main.async {
                // The audio meter follows defaultSettings.mode specifically, so only touch it
                // if this mutation actually changed the default (i.e. the frontmost app has no
                // override of its own) — leave it alone when only a per-app override changed.
                let audioWasOn = defaultSettings.mode == .audio
                mutateCurrentSettings { settings in
                    settings.mode = toggledMode(current: settings.mode, pair: pair)
                }
                let audioIsOn = defaultSettings.mode == .audio
                if audioIsOn != audioWasOn {
                    if audioIsOn {
                        if #available(macOS 14.2, *) { startAudioMeter() }
                    } else {
                        stopAudioMeter()
                    }
                    signalModeChange(toAudio: audioIsOn)
                }
                menuHandler.updateMenuState()
            }
        case .toggleFineScroll:
            DispatchQueue.main.async {
                mutateCurrentSettings { $0.fineScrollEnabled.toggle() }
                menuHandler.updateMenuState()
            }
        case .runScript:
            // settings.script1/2 is a per-app override; nil means "no override", not "empty
            // script" — fall back to the global default from Configure Scripts... in that case.
            let command = NSEvent.modifierFlags.contains(.shift)
                ? (settings.script2 ?? defaults.string(forKey: kScript2) ?? "")
                : (settings.script1 ?? defaults.string(forKey: kScript1) ?? "")
            runScript(command)
        case .custom(let binding):
            postKey(binding.keyCode, flags: binding.flags)
        }
    }
}

driver.onButtonDown = {
    isButtonDown = true
    _didRotateWhileButtonDown = false
    _trackSkipAccumulator = 0
    beginHoldKey()
    setLEDOffMain(255)
}

driver.onButtonUp = {
    isButtonDown = false
    endHoldKey()
    if throbTimer != nil {
        lastRotationTime = CFAbsoluteTimeGetCurrent()
    } else {
        setLEDOffMain(80)
    }
}

driver.onConnect    = { updateStatusIcon(); updateDockIcon(); setLEDOffMain(80) }
driver.onDisconnect = {
    // No button-up is coming for a press interrupted by unplug or sleep — release by hand.
    endHoldKey()
    _holdKeySuppressesGestures = false
    updateStatusIcon()
    updateDockIcon()
}

driver.start()

// MARK: - App setup

let appDelegate = AppDelegate()
let app = NSApplication.shared
app.delegate = appDelegate

buildMenu()

// MARK: - Startup

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    // Registers a global NSEvent monitor. Deferred here, after the run loop is up and the app's
    // normal Cocoa lifecycle (NSApplication.shared/app.delegate/buildMenu() above) has settled,
    // rather than run inline during startup — an earlier attempt called it before NSApp had been
    // touched at all, which broke the status-item menu from opening entirely.
    startTrackingRealModifierFlags()
    if driver.isConnected {
        setLEDOffMain(80)
    }
    // Restore audio meter if audio mode was saved as enabled from a previous session.
    if defaultSettings.mode == .audio {
        if #available(macOS 14.2, *) { startAudioMeter() }
    }
    // Check for a newer release in the background; shows a menu item if one is found.
    checkForUpdates()
}

/// Check Accessibility permission; if missing, trigger the system prompt (which registers the
/// app in Security > Accessibility) and show an alert with further instructions.
func checkAccessibilityPermission() {
    // Passing kAXTrustedCheckOptionPrompt:true causes macOS to show the system dialog and
    // add the app to the Security > Accessibility list, even if the user dismisses it.
    let prompt = [(kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String): true] as CFDictionary
    guard !AXIsProcessTrustedWithOptions(prompt) else { return }
    let alert = NSAlert()
    alert.messageText = "Accessibility Permission Required"
    alert.informativeText = "PowerMate Agent needs Accessibility access to detect menus and send keyboard events.\n\nGo to System Settings → Privacy & Security → Accessibility and enable PowerMate Agent."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Later")
    if alert.runModal() == .alertFirstButtonReturn {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    checkAccessibilityPermission()
}

// MARK: - Sleep / wake

// Fully release the HID device and stop the audio IOProc when the display sleeps.
// Holding the device open while the display is off causes the PowerMate to assert
// USB remote wake repeatedly, toggling the display on and off every few seconds.
// driver.start() re-seizes the device on wake; onConnect restores the LED.
let wsCenter = NSWorkspace.shared.notificationCenter
wsCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
    stopAudioMeter()
    setLEDOffMain(0)
    driver.stop()
}
wsCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
    driver.start()
    if defaultSettings.mode == .audio {
        if #available(macOS 14.2, *) { startAudioMeter() }
    }
}

// MARK: - Dock icon visibility

// Periodically check whether the status item is visible in the menu bar.
// If it is hidden (notch overlap or overflow >>) show a Dock icon so the user
// can still access the menu. Check starts after a short delay to let the
// status item settle into its position on launch.
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    updateDockIconVisibility()
    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
        updateDockIconVisibility()
    }
}

app.run()
