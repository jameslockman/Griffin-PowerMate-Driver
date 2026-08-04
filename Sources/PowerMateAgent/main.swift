#!/usr/bin/env swift
//
//  PowerMateAgent — runs in the background and turns PowerMate input into
//  keyboard/scroll events that any application can receive.
//
//  Rotation   → scroll, or arrow keys when a menu/submenu is focused,
//               or system volume when audio controls are enabled
//  Click      → left mouse (at cursor), or Return when a menu is focused,
//               or mute/unmute when audio controls are enabled
//  Long press → right mouse button (then arrow keys until timeout or click)
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

// MARK: - Driver

let driver = PowerMateDriver()

// MARK: - Button and rotation state

var isButtonDown = false
var lastRotationTime: CFTimeInterval = 0

// Tracks whether rotation occurred while the button was held, so the subsequent
// button-up click can be suppressed (avoiding an unintended mute/click after track skip).
private var _didRotateWhileButtonDown = false
// Accumulates rotation units while button is held; a track skip fires every kTrackSkipThreshold units.
private var _trackSkipAccumulator = 0
private let kTrackSkipThreshold = 5

// MARK: - Driver callbacks

driver.onRotate = { delta, rate in
    lastRotationTime = CFAbsoluteTimeGetCurrent()
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
        let shiftHeld   = NSEvent.modifierFlags.contains(.shift)
        let optionHeld  = NSEvent.modifierFlags.contains(.option)
        let commandHeld = NSEvent.modifierFlags.contains(.command)
        let slot: TurnSlot = commandHeld ? .command : optionHeld ? .option : shiftHeld ? .shift : .plain
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

driver.onClick = {
    // Defer by one run-loop cycle so that any rotation in the same HID report is processed
    // first (the driver handles button-change before rotation within each report block).
    // This ensures _didRotateWhileButtonDown is set before we decide whether to act.
    DispatchQueue.main.async {
        guard !_didRotateWhileButtonDown else { return }
        let settings = currentSettings()
        if useMenuBehavior() {
            postKey(kReturnKey)
            // Do not exit menu mode here: a submenu may open and we need to keep sending arrow keys.
            // Menu mode will exit on the 5-second timeout when the user stops rotating.
        } else if useAudioBehavior(mode: settings.mode) {
            let shiftHeld = NSEvent.modifierFlags.contains(.shift)
            switch settings.clickAction {
            case .mute:      shiftHeld ? togglePlayPause() : toggleMute()
            case .playPause: shiftHeld ? toggleMute()      : togglePlayPause()
            }
        } else {
            exitMenuMode()
            postMouseClick(button: .left)
        }
    }
}

driver.onLongPress = {
    DispatchQueue.main.async {
        guard !_didRotateWhileButtonDown else { return }
        // The action itself is resolved per-app (frontmost app's override, or the default).
        switch currentSettings().longPressAction {
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
            let command = NSEvent.modifierFlags.contains(.shift)
                ? defaults.string(forKey: kScript2) ?? ""
                : defaults.string(forKey: kScript1) ?? ""
            runScript(command)
        }
    }
}

driver.onButtonDown = {
    isButtonDown = true
    _didRotateWhileButtonDown = false
    _trackSkipAccumulator = 0
    setLEDOffMain(255)
}

driver.onButtonUp = {
    isButtonDown = false
    if throbTimer != nil {
        lastRotationTime = CFAbsoluteTimeGetCurrent()
    } else {
        setLEDOffMain(80)
    }
}

driver.onConnect    = { updateStatusIcon(); updateDockIcon(); setLEDOffMain(80) }
driver.onDisconnect = { updateStatusIcon(); updateDockIcon() }

driver.start()

// MARK: - App setup

let appDelegate = AppDelegate()
let app = NSApplication.shared
app.delegate = appDelegate

buildMenu()

// MARK: - Startup

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
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
