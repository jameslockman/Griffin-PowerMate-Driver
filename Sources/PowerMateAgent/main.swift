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
    if isButtonDown {
        _didRotateWhileButtonDown = true
        _trackSkipAccumulator += delta
        while abs(_trackSkipAccumulator) >= kTrackSkipThreshold {
            if _trackSkipAccumulator > 0 {
                if !controlForegroundPlayer(nextTrack: true) {
                    postMediaKey(17, keyDown: true); postMediaKey(17, keyDown: false)
                }
            } else if !controlForegroundPlayer(previousTrack: true) {
                postMediaKey(18, keyDown: true); postMediaKey(18, keyDown: false)
            }
            _trackSkipAccumulator -= _trackSkipAccumulator > 0 ? kTrackSkipThreshold : -kTrackSkipThreshold
        }
        return
    }
    if NSEvent.modifierFlags.contains(.option) {
        let keyType: Int32 = delta > 0 ? 2 : 3  // display brightness up/down
        for _ in 0 ..< abs(delta) {
            postMediaKey(keyType, keyDown: true)
            postMediaKey(keyType, keyDown: false)
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
    } else if useAudioBehavior() {
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        // audioStepSwapped flips the default: normally no-modifier=standard, Shift=fine;
        // when swapped, no-modifier=fine, Shift=standard.
        let fine = audioStepSwapped ? !shiftHeld : shiftHeld
        let up = delta > 0
        // fine mode: one fine step per tick regardless of velocity.
        // standard mode: abs(delta) presses so faster spinning moves volume faster.
        let presses = fine ? 1 : abs(delta)
        adjustVolume(up: up, fine: fine, presses: presses)
    } else {
        let shiftHeld  = NSEvent.modifierFlags.contains(.shift)
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        // Option toggles fine/coarse; fineScrollEnabled sets the default.
        let fine = fineScrollEnabled != optionHeld
        // Shift toggles horizontal/vertical; scrollAxesSwapped sets the default.
        // Shift+Option: switch axis AND force fine mode.
        let horizontal = scrollAxesSwapped ? !shiftHeld : shiftHeld
        let effectiveFine = (shiftHeld && optionHeld) ? true : fine
        postScroll(delta: delta, horizontal: horizontal, fine: effectiveFine)
    }
}

private var pendingClickResolution: DispatchWorkItem?
private var clickCount = 0
private let multiClickInterval: TimeInterval = 0.28
private var buttonDownStartedAt: CFAbsoluteTime?
private let veryLongPressInterval: TimeInterval = 1.5

driver.onClick = {
    DispatchQueue.main.async {
        guard !_didRotateWhileButtonDown else { return }
        pendingClickResolution?.cancel()
        clickCount += 1
        if clickCount >= 3 {
            clickCount = 0
            pendingClickResolution = nil
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Music.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
            return
        }

        let resolution = DispatchWorkItem {
            let resolvedCount = clickCount
            clickCount = 0
            pendingClickResolution = nil
            if resolvedCount == 1 {
                if !controlForegroundPlayer(nextTrack: false) { togglePlayPause() }
            } else if resolvedCount == 2, !controlForegroundPlayer(nextTrack: true) {
                postMediaKey(17, keyDown: true)
                postMediaKey(17, keyDown: false)
            }
        }
        pendingClickResolution = resolution
        DispatchQueue.main.asyncAfter(deadline: .now() + multiClickInterval, execute: resolution)
    }
}

driver.onLongPress = {
    DispatchQueue.main.async {
        guard !_didRotateWhileButtonDown else { return }
        pendingClickResolution?.cancel()
        pendingClickResolution = nil
        clickCount = 0
        let duration = CFAbsoluteTimeGetCurrent() - (buttonDownStartedAt ?? CFAbsoluteTimeGetCurrent())
        if duration >= veryLongPressInterval {
            toggleMicrophoneMute()
            return
        }
        let siriURL = URL(fileURLWithPath: "/System/Applications/Siri.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: siriURL, configuration: configuration) { _, error in
            if let error { NSLog("PowerMate: could not open Siri: %@", error.localizedDescription) }
        }
    }
}

driver.onButtonDown = {
    isButtonDown = true
    buttonDownStartedAt = CFAbsoluteTimeGetCurrent()
    _didRotateWhileButtonDown = false
    _trackSkipAccumulator = 0
    setLEDOffMain(255)
}

driver.onButtonUp = {
    isButtonDown = false
    buttonDownStartedAt = nil
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
    if audioControlEnabled {
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
    if audioControlEnabled {
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
