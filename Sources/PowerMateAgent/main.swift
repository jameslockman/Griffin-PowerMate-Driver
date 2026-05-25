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
//  work in submenus without leaving “menu mode”. Enable Accessibility for that.
//  Requires Input Monitoring (System Settings → Privacy & Security).
//

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import CoreAudio
import PowerMateDriver

let driver = PowerMateDriver()

// Scroll: pixels per knob delta unit; user can reverse direction via menu.
// Pixel units + isContinuous = 1 produces trackpad-style smooth scrolling rather
// than the discrete line jumps that .line units give.
let scrollPixelsPerStep: Int32 = 20

// Persistent settings via UserDefaults
private let defaults = UserDefaults.standard
private let kScrollReversed    = "scrollReversed"
private let kAudioControl      = "audioControlEnabled"
private let kLongPressAction   = "longPressAction"
private let kScript1           = "script1"
private let kScript2           = "script2"

var scrollReversed     = defaults.bool(forKey: kScrollReversed)
var audioControlEnabled = defaults.bool(forKey: kAudioControl)

func postScroll(delta: Int) {
    var pixels = Int32(delta) * scrollPixelsPerStep
    if scrollReversed { pixels = -pixels }
    guard let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 1,
        wheel1: pixels,
        wheel2: 0,
        wheel3: 0
    ) else { return }
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.post(tap: .cghidEventTap)
}

// Key codes (HIToolbox): Up = 0x7E, Down = 0x7D, Return = 0x24
private let kUpArrow: CGKeyCode = 0x7E
private let kDownArrow: CGKeyCode = 0x7D
private let kReturnKey: CGKeyCode = 0x24

/// Post one key press (down + up).
func postKey(_ keyCode: CGKeyCode) {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

/// Convert Cocoa screen point (bottom-left origin) to Quartz (top-left origin).
func cocoaToQuartz(_ cocoa: NSPoint) -> CGPoint {
    let screen = NSScreen.screens.first { NSMouseInRect(cocoa, $0.frame, false) } ?? NSScreen.main
    let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    return CGPoint(x: cocoa.x, y: frame.maxY - cocoa.y)
}

/// Post a mouse click at the given Quartz location.
func postMouseClick(at location: CGPoint, button: CGMouseButton = .left) {
    let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
    let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
    if let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: location, mouseButton: button),
       let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: location, mouseButton: button) {
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// Post a proper double-click at the given Quartz location using kCGMouseEventClickState = 2
/// so the system treats it as one double-click, not two single clicks.
func postDoubleClick(at location: CGPoint) {
    guard let down1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
          let up1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left),
          let down2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
          let up2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left) else { return }
    down1.post(tap: .cghidEventTap)
    up1.post(tap: .cghidEventTap)
    down2.setIntegerValueField(.mouseEventClickState, value: 2)
    up2.setIntegerValueField(.mouseEventClickState, value: 2)
    down2.post(tap: .cghidEventTap)
    up2.post(tap: .cghidEventTap)
}

/// Post a left or right mouse click at the current cursor position (like a trackpad tap or mouse click).
func postMouseClick(button: CGMouseButton = .left) {
    DispatchQueue.main.async {
        let cocoa = NSEvent.mouseLocation
        let location = cocoaToQuartz(cocoa)
        postMouseClick(at: location, button: button)
    }
}

// Menu behavior: use arrow keys + Return when a menu (or submenu) is focused.
// We use the Accessibility API so submenus are detected; long-press timeout is fallback.
var isMenuMode = false
var menuModeTimeout: DispatchWorkItem?
let menuModeTimeoutInterval: TimeInterval = 5.0

// Cached system-wide AX element (reused; creating it per call is wasteful).
private let axSystemWide = AXUIElementCreateSystemWide()
// isMenuFocused result cache: AX IPC is expensive and the menu state rarely changes
// between knob ticks. A 150 ms TTL caps IPC calls to ~7/sec even during fast spinning.
private var cachedMenuFocused = false
private var menuFocusCacheTime: CFAbsoluteTime = 0
private let menuFocusCacheTTL: CFAbsoluteTime = 0.15

/// Returns true if the currently focused UI element is a menu or menu item (or inside one, e.g. submenu).
/// Requires Accessibility permission. Runs on main thread.
func isMenuFocused() -> Bool {
    guard Thread.isMainThread else { return false }
    let now = CFAbsoluteTimeGetCurrent()
    if now - menuFocusCacheTime < menuFocusCacheTTL { return cachedMenuFocused }
    menuFocusCacheTime = now
    var appRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axSystemWide, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
          let app = appRef, CFGetTypeID(app) == AXUIElementGetTypeID() else { return false }
    let appElement = (app as! AXUIElement)
    var focusRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusRef) == .success,
          let focus = focusRef, CFGetTypeID(focus) == AXUIElementGetTypeID() else { return false }
    var element: AXUIElement? = (focus as! AXUIElement)
    var count = 0
    let maxAncestors = 20
    while let el = element, count < maxAncestors {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            if role == "AXMenu" || role == "AXMenuItem" {
                cachedMenuFocused = true
                return true
            }
        }
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success,
              let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
        element = (parent as! AXUIElement)
        count += 1
    }
    cachedMenuFocused = false
    return false
}

/// True when we should send arrow keys / Return (menu or submenu active).
func useMenuBehavior() -> Bool {
    isMenuMode || isMenuFocused()
}

func enterMenuMode() {
    isMenuMode = true
    menuModeTimeout?.cancel()
    let work = DispatchWorkItem { isMenuMode = false }
    menuModeTimeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + menuModeTimeoutInterval, execute: work)
}

func exitMenuMode() {
    isMenuMode = false
    menuModeTimeout?.cancel()
    menuModeTimeout = nil
}

// Audio controls: when enabled, knob adjusts system volume and button toggles mute,
// replacing scroll/click entirely (menu behavior still takes priority).
// Holding Fn temporarily flips the mode: enables audio when off, restores scroll when on.
func useAudioBehavior() -> Bool {
    let fnHeld = NSEvent.modifierFlags.contains(.function)
    let wantAudio = audioControlEnabled != fnHeld   // XOR: Fn flips whatever the setting is
    return wantAudio && !useMenuBehavior()
}

// Accumulator so the knob requires multiple ticks per volume step.
// Raise volumeTicksPerStep to slow the rate of change; lower it to speed it up.
private var volumeAccumulator = 0
private let volumeTicksPerStep = 4

/// Load a sound by name, checking the app bundle Resources first, then falling back to system sounds.
/// Place custom files named e.g. "ToAudio.aiff" / "ToScroll.aiff" in scripts/Sounds/ and they will
/// be bundled into the app automatically by build-app.sh.
private func loadSound(_ name: String) -> NSSound? {
    if let url = Bundle.main.url(forResource: name, withExtension: nil)
        ?? Bundle.main.url(forResource: name, withExtension: "aiff")
        ?? Bundle.main.url(forResource: name, withExtension: "wav")
        ?? Bundle.main.url(forResource: name, withExtension: "mp3") {
        return NSSound(contentsOf: url, byReference: false)
    }
    return NSSound(named: NSSound.Name(name))
}

/// Flash the LED twice and play a sound to confirm a mode switch.
/// toAudio: true  → switching into audio mode ("ToAudio" bundle sound or "Tink" fallback)
/// toAudio: false → switching back to scroll mode ("ToScroll" bundle sound or "Glass" fallback)
func signalModeChange(toAudio: Bool) {
    ledQueue.async {
        for _ in 0..<2 {
            _ = driver.setLEDBrightness(255)
            Thread.sleep(forTimeInterval: 0.055)
            _ = driver.setLEDBrightness(0)
            Thread.sleep(forTimeInterval: 0.055)
        }
        _ = driver.setLEDBrightness(80)
    }
    DispatchQueue.main.async {
        let sound = toAudio ? loadSound("ToAudio") ?? NSSound(named: "Tink")
                            : loadSound("ToScroll") ?? NSSound(named: "Glass")
        sound?.play()
    }
}

// Volume and mute via NX system-defined media key events — same path as F11/F12/F10.
// One event per knob tick = one hardware volume step (~4% per step, finer than F11/F12).
// NX_KEYTYPE_SOUND_UP = 0, NX_KEYTYPE_SOUND_DOWN = 1, NX_KEYTYPE_MUTE = 7
private func postMediaKey(_ keyType: Int32, keyDown: Bool) {
    let flags = NSEvent.ModifierFlags(rawValue: keyDown ? 0xa00 : 0xb00)
    let data1 = Int(keyType) << 16 | (keyDown ? 0x0a00 : 0x0b00)
    guard let event = NSEvent.otherEvent(
        with: .systemDefined,
        location: .zero,
        modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        subtype: 8,
        data1: data1,
        data2: -1
    ) else { return }
    event.cgEvent?.post(tap: .cghidEventTap)
}

func toggleMute() {
    postMediaKey(7, keyDown: true)
    postMediaKey(7, keyDown: false)
}

driver.onRotate = { delta, _ in
    lastRotationTime = CFAbsoluteTimeGetCurrent()
    startThrob()
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
        volumeAccumulator += delta
        let steps = volumeAccumulator / volumeTicksPerStep
        if steps != 0 {
            volumeAccumulator -= steps * volumeTicksPerStep
            let keyType: Int32 = steps > 0 ? 0 : 1
            for _ in 0..<abs(steps) {
                postMediaKey(keyType, keyDown: true)
                postMediaKey(keyType, keyDown: false)
            }
        }
    } else {
        postScroll(delta: delta)
    }
}

driver.onClick = {
    if useMenuBehavior() {
        postKey(kReturnKey)
        // Do not exit menu mode here: a submenu may open and we need to keep sending arrow keys.
        // Menu mode will exit on the 5-second timeout when the user stops rotating.
    } else if useAudioBehavior() {
        toggleMute()
    } else {
        exitMenuMode()
        postMouseClick(button: .left)
    }
}

// Long-press action: right-click, double-click, toggle audio mode, or run a script (chosen in menu)
enum LongPressAction { case rightClick, doubleClick, toggleAudioMode, runScript }
var longPressAction: LongPressAction = {
    switch defaults.string(forKey: kLongPressAction) {
    case "doubleClick":      return .doubleClick
    case "toggleAudioMode":  return .toggleAudioMode
    case "runScript":        return .runScript
    default:                 return .rightClick
    }
}()

/// Run a shell command in the background via /bin/sh -c.
func runScript(_ command: String) {
    let trimmed = command.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", trimmed]
        try? process.run()
    }
}

/// Show the Configure Scripts sheet with two text fields.
/// Long press runs script 1; shift + long press runs script 2.
func showConfigureScripts() {
    let alert = NSAlert()
    alert.messageText = "Configure Scripts"
    alert.informativeText = "Enter shell commands to run on long press.\nHold Shift while pressing to run the second command."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 84))

    let label1 = NSTextField(labelWithString: "Long press:")
    label1.frame = NSRect(x: 0, y: 60, width: 420, height: 17)
    let field1 = NSTextField(frame: NSRect(x: 0, y: 36, width: 420, height: 22))
    field1.placeholderString = "e.g.  open -a Safari"
    field1.stringValue = defaults.string(forKey: kScript1) ?? ""

    let label2 = NSTextField(labelWithString: "Shift + long press:")
    label2.frame = NSRect(x: 0, y: 14, width: 420, height: 17)
    let field2 = NSTextField(frame: NSRect(x: 0, y: -10, width: 420, height: 22))
    field2.placeholderString = "e.g.  open -a Terminal"
    field2.stringValue = defaults.string(forKey: kScript2) ?? ""

    container.addSubview(label1)
    container.addSubview(field1)
    container.addSubview(label2)
    container.addSubview(field2)
    alert.accessoryView = container

    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn {
        defaults.set(field1.stringValue, forKey: kScript1)
        defaults.set(field2.stringValue, forKey: kScript2)
    }
}

driver.onLongPress = {
    switch longPressAction {
    case .rightClick:
        enterMenuMode()
        postMouseClick(button: .right)
    case .doubleClick:
        enterMenuMode()
        DispatchQueue.main.async {
            let cocoa = NSEvent.mouseLocation
            let location = cocoaToQuartz(cocoa)
            postDoubleClick(at: location)
        }
    case .toggleAudioMode:
        DispatchQueue.main.async {
            audioControlEnabled.toggle()
            defaults.set(audioControlEnabled, forKey: kAudioControl)
            volumeAccumulator = 0
            if audioControlEnabled {
                if #available(macOS 14.2, *) { startAudioMeter() }
            } else {
                stopAudioMeter()
            }
            signalModeChange(toAudio: audioControlEnabled)
            menuHandler.updateMenuState()
        }
    case .runScript:
        let command = NSEvent.modifierFlags.contains(.shift)
            ? defaults.string(forKey: kScript2) ?? ""
            : defaults.string(forKey: kScript1) ?? ""
        runScript(command)
    }
}

// Audio amplitude metering — drives the LED as a VU meter when audio control mode is on.
// Uses CATapDescription (macOS 14.2+) to tap the system stereo output mix without requiring
// Screen Recording permission. Only active when audioControlEnabled (not just Fn-held).
// Audio amplitude metering — drives the LED as a VU meter when audio control mode is on.
// Uses CATapDescription + AudioHardwareCreateProcessTap (macOS 14.2+) to tap the system
// stereo output mix via a direct CoreAudio IOProc. No AVAudioEngine, no extra permissions.
private var audioMeterActive = false
private var audioTapID: AudioObjectID = 0
private var audioAggDeviceID: AudioDeviceID = 0
private var audioTapProcID: AudioDeviceIOProcID?
// LED update throttle for the audio VU meter.
// The IOProc fires at the hardware buffer rate (~86–172 Hz) but the LED only needs
// to update at ~25 Hz for a smooth-looking VU effect. The RMS calculation and LED
// dispatch are both skipped entirely on calls that arrive before the interval elapses,
// so the float sample loop doesn't run on those callbacks at all.
// kLEDUpdateInterval: minimum seconds between LED updates (0.04 = 25 Hz).
// kLEDUpdateThreshold: minimum brightness change required to send a USB command,
//   avoiding redundant writes when amplitude is steady.
private var lastLEDBrightness: UInt8 = 0
private var lastLEDUpdateTime: CFAbsoluteTime = 0
private let kLEDUpdateInterval: CFAbsoluteTime = 0.04   // 25 Hz
private let kLEDUpdateThreshold: Int = 4

@available(macOS 14.2, *)
func startAudioMeter() {
    guard !audioMeterActive else { return }

    // 1. Create the process tap (AudioTap object, NOT an AudioDevice).
    let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    var tapID: AudioObjectID = 0
    guard AudioHardwareCreateProcessTap(tapDesc, &tapID) == noErr else { return }

    // 2. Retrieve the tap's UID string so we can reference it in the aggregate device.
    var tapUID: Unmanaged<CFString>? = nil
    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var uidAddr = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, &tapUID)
    guard let tapUIDString = tapUID?.takeRetainedValue() as String? else {
        AudioHardwareDestroyProcessTap(tapID)
        return
    }

    // 3. Wrap the tap in a private aggregate device — that IS an AudioDevice and accepts IOProcs.
    let composition: NSDictionary = [
        kAudioAggregateDeviceNameKey:      "PowerMate Meter" as NSString,
        kAudioAggregateDeviceUIDKey:       "com.powermate.agent.meter.\(UUID().uuidString)" as NSString,
        kAudioAggregateDeviceIsPrivateKey: 1 as NSNumber,
        kAudioAggregateDeviceTapListKey:   [[kAudioSubTapUIDKey: tapUIDString as NSString]] as NSArray,
    ]
    var aggDeviceID: AudioDeviceID = 0
    guard AudioHardwareCreateAggregateDevice(composition, &aggDeviceID) == noErr else {
        AudioHardwareDestroyProcessTap(tapID)
        return
    }

    // 4. Register an IOProc on the aggregate device; tap audio arrives in inInputData.
    var procID: AudioDeviceIOProcID?
    guard AudioDeviceCreateIOProcIDWithBlock(&procID, aggDeviceID, nil, {
        _, inInputData, _, _, _ in
        guard audioMeterActive, !isButtonDown else { return }
        // Gate: skip the RMS calculation entirely until the update interval has elapsed.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLEDUpdateTime >= kLEDUpdateInterval else { return }
        lastLEDUpdateTime = now
        let buf = inInputData.pointee.mBuffers
        guard let raw = buf.mData else { return }
        let samples = raw.assumingMemoryBound(to: Float32.self)
        let count = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size
        guard count > 0 else { return }
        var sum: Float32 = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = sqrtf(sum / Float32(count))
        let brightness = max(UInt8(20), UInt8(clamping: Int((rms * 1200).rounded())))
        guard abs(Int(brightness) - Int(lastLEDBrightness)) > kLEDUpdateThreshold else { return }
        lastLEDBrightness = brightness
        setLEDOffMain(brightness)
    }) == noErr, let procID else {
        AudioHardwareDestroyAggregateDevice(aggDeviceID)
        AudioHardwareDestroyProcessTap(tapID)
        return
    }

    guard AudioDeviceStart(aggDeviceID, procID) == noErr else {
        AudioDeviceDestroyIOProcID(aggDeviceID, procID)
        AudioHardwareDestroyAggregateDevice(aggDeviceID)
        AudioHardwareDestroyProcessTap(tapID)
        return
    }

    audioTapID = tapID
    audioAggDeviceID = aggDeviceID
    audioTapProcID = procID
    audioMeterActive = true
}

func stopAudioMeter() {
    guard audioMeterActive else { return }
    audioMeterActive = false
    lastLEDBrightness = 0
    lastLEDUpdateTime = 0
    if audioAggDeviceID != 0 {
        if let procID = audioTapProcID {
            AudioDeviceStop(audioAggDeviceID, procID)
            AudioDeviceDestroyIOProcID(audioAggDeviceID, procID)
            audioTapProcID = nil
        }
        AudioHardwareDestroyAggregateDevice(audioAggDeviceID)
        audioAggDeviceID = 0
    }
    if audioTapID != 0 {
        if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(audioTapID) }
        audioTapID = 0
    }
    if !isButtonDown { setLEDOffMain(80) }
}

// Optional: LED feedback (dim when idle, throb while turning, full on when button held).
// LED updates run on a background queue so they never block the main run loop (where HID
// reports are delivered); blocking the main loop was causing scroll to pause then resume.
private let ledQueue = DispatchQueue(label: "com.powermate.agent.led", qos: .utility)
func setLEDOffMain(_ value: UInt8) {
    ledQueue.async { _ = driver.setLEDBrightness(value) }
}

var isButtonDown = false
var lastRotationTime: CFTimeInterval = 0
var throbTimer: DispatchSourceTimer?
var smoothedThrobBrightness: Double = 80
let throbPeriod: CFTimeInterval = 1.5
let throbIdleTimeout: CFTimeInterval = 0.5
let throbTick: CFTimeInterval = 0.025
let throbSmooth: Double = 0.22

func startThrob() {
    lastRotationTime = CFAbsoluteTimeGetCurrent()
    guard throbTimer == nil, !audioMeterActive else { return }
    throbTimer = DispatchSource.makeTimerSource(queue: .main)
    throbTimer?.schedule(deadline: .now(), repeating: throbTick)
    throbTimer?.setEventHandler {
        guard driver.isConnected, !isButtonDown else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastRotationTime > throbIdleTimeout {
            throbTimer?.cancel()
            throbTimer = nil
            setLEDOffMain(80)
            smoothedThrobBrightness = 80
            return
        }
        let t = now.truncatingRemainder(dividingBy: throbPeriod) / throbPeriod
        let target = 80 + 175 * (0.5 + 0.5 * sin(t * 2 * .pi))
        smoothedThrobBrightness += (target - smoothedThrobBrightness) * throbSmooth
        let value = UInt8(max(0, min(255, smoothedThrobBrightness.rounded())))
        setLEDOffMain(value)
    }
    throbTimer?.resume()
}

driver.onButtonDown = {
    isButtonDown = true
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

driver.onConnect = {
    updateStatusIcon()
    updateDockIcon()
    setLEDOffMain(80)
}
driver.onDisconnect = { updateStatusIcon(); updateDockIcon() }

driver.start()

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

// MARK: - App delegate (Dock icon fallback when status item is hidden by notch/overflow)

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Hide the dock icon as early as possible. Without LSUIElement in Info.plist, macOS would
    /// show a dock icon by default; calling setActivationPolicy here suppresses it before the
    /// launch sequence completes. The dock icon is shown dynamically when the status item is
    /// hidden behind the camera notch.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Right-click (or click-and-hold) on the Dock icon shows the same menu as the menu bar.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return menu
    }

    /// Left-click on the Dock icon also pops the menu at the cursor.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        let location = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: location, in: nil)
        return false
    }
}

let appDelegate = AppDelegate()

// Menu bar: status item and menu with Reverse scroll / Long press options
let app = NSApplication.shared
app.delegate = appDelegate

final class MenuHandler: NSObject, NSMenuDelegate {
    var reverseScrollItem: NSMenuItem!
    var audioControlItem: NSMenuItem!
    var longPressRightItem: NSMenuItem!
    var longPressDoubleItem: NSMenuItem!
    var longPressToggleAudioItem: NSMenuItem!
    var longPressRunScriptItem: NSMenuItem!

    func updateMenuState() {
        reverseScrollItem.state = scrollReversed ? .on : .off
        audioControlItem.state = audioControlEnabled ? .on : .off
        longPressRightItem.state = (longPressAction == .rightClick) ? .on : .off
        longPressDoubleItem.state = (longPressAction == .doubleClick) ? .on : .off
        longPressToggleAudioItem.state = (longPressAction == .toggleAudioMode) ? .on : .off
        longPressRunScriptItem.state = (longPressAction == .runScript) ? .on : .off
        updateStatusIcon()
        updateDockIcon()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
    }

    @objc func toggleScrollReversed() {
        scrollReversed.toggle()
        defaults.set(scrollReversed, forKey: kScrollReversed)
        updateMenuState()
    }

    @objc func toggleAudioControl() {
        audioControlEnabled.toggle()
        defaults.set(audioControlEnabled, forKey: kAudioControl)
        volumeAccumulator = 0
        if audioControlEnabled {
            if #available(macOS 14.2, *) { startAudioMeter() }
        } else {
            stopAudioMeter()
        }
        signalModeChange(toAudio: audioControlEnabled)
        updateMenuState()
    }

    @objc func setLongPressRightClick() {
        longPressAction = .rightClick
        defaults.set("rightClick", forKey: kLongPressAction)
        updateMenuState()
    }

    @objc func setLongPressDoubleClick() {
        longPressAction = .doubleClick
        defaults.set("doubleClick", forKey: kLongPressAction)
        updateMenuState()
    }

    @objc func setLongPressToggleAudio() {
        longPressAction = .toggleAudioMode
        defaults.set("toggleAudioMode", forKey: kLongPressAction)
        updateMenuState()
    }

    @objc func setLongPressRunScript() {
        longPressAction = .runScript
        defaults.set("runScript", forKey: kLongPressAction)
        updateMenuState()
    }

    @objc func configureScripts() {
        showConfigureScripts()
    }

    @objc func openReleasesPage() {
        if let url = URL(string: "https://github.com/jameslockman/Griffin-PowerMate-Driver/releases") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Update check

private let kCurrentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

/// Returns true if `version` is strictly newer than `current` (semantic comparison).
private func isNewerVersion(_ version: String, than current: String) -> Bool {
    let a = version.split(separator: ".").compactMap { Int($0) }
    let b = current.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(a.count, b.count) {
        let av = i < a.count ? a[i] : 0
        let bv = i < b.count ? b[i] : 0
        if av > bv { return true }
        if av < bv { return false }
    }
    return false
}

/// Fetch the latest GitHub release tag and show the update menu item if a newer version exists.
func checkForUpdates() {
    guard let url = URL(string: "https://api.github.com/repos/jameslockman/Griffin-PowerMate-Driver/releases/latest") else { return }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: request) { data, _, _ in
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else { return }
        let latest = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        guard isNewerVersion(latest, than: kCurrentVersion) else { return }
        DispatchQueue.main.async {
            updateAvailableItem.title = "Update available: \(latest) →"
            updateAvailableItem.isHidden = false
        }
    }.resume()
}

/// Load a named icon from the bundle using the documented path(forResource:ofType:) API.
/// Checks .icns first (preferred for dock display), then .png.
private func loadBundleIcon(_ name: String) -> NSImage? {
    for ext in ["icns", "png"] {
        if let path = Bundle.main.path(forResource: name, ofType: ext),
           let img = NSImage(contentsOfFile: path) {
            return img
        }
    }
    return nil
}

/// Returns the dock icon image for the current connection/mode state.
/// Uses custom bundle images when available, otherwise falls back to SF Symbols.
func makeDockIcon() -> NSImage? {
    if !driver.isConnected {
        if let img = loadBundleIcon("DockIconDisconnected") { return img }
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            .applying(NSImage.SymbolConfiguration(pointSize: 96, weight: .regular))
        return NSImage(systemSymbolName: "circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    } else if audioControlEnabled {
        if let img = loadBundleIcon("DockIconAudio") { return img }
        let config = NSImage.SymbolConfiguration(paletteColors: [.labelColor, .systemBlue])
            .applying(NSImage.SymbolConfiguration(pointSize: 96, weight: .regular))
        return NSImage(systemSymbolName: "circle.inset.filled", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    } else {
        if let img = loadBundleIcon("DockIconScroll") { return img }
        let config = NSImage.SymbolConfiguration(paletteColors: [.labelColor, .tertiaryLabelColor])
            .applying(NSImage.SymbolConfiguration(pointSize: 96, weight: .regular))
        return NSImage(systemSymbolName: "circle.inset.filled", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}

func updateDockIcon() {
    guard dockIconVisible else { return }
    if let img = makeDockIcon() {
        NSApp.applicationIconImage = img
        NSApp.dockTile.display()
    }
}

func updateStatusIcon() {
    guard let button = statusItem.button else { return }
    button.contentTintColor = nil
    if !driver.isConnected {
        // Disconnected: dimmed circle (no fill) to indicate nothing is connected.
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let img = NSImage(systemSymbolName: "circle", accessibilityDescription: "PowerMate Agent — Not connected")?
            .withSymbolConfiguration(config)
        img?.isTemplate = false
        button.image = img
    } else if audioControlEnabled {
        // Audio mode: blue inner dot.
        let config = NSImage.SymbolConfiguration(paletteColors: [.labelColor, .systemBlue])
        let img = NSImage(systemSymbolName: "circle.inset.filled", accessibilityDescription: "PowerMate Agent — Audio mode")?
            .withSymbolConfiguration(config)
        img?.isTemplate = false
        button.image = img
    } else {
        // Scroll mode: standard adaptive template icon.
        let img = NSImage(systemSymbolName: "circle.inset.filled", accessibilityDescription: "PowerMate Agent")
        img?.isTemplate = true
        button.image = img
    }
}

let menuHandler = MenuHandler()
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
if let button = statusItem.button {
    button.toolTip = "PowerMate Agent — Audo and scroll controls"
}
updateStatusIcon()
let menu = NSMenu()
menu.delegate = menuHandler

let audioItem = NSMenuItem(title: "Audio mode", action: #selector(MenuHandler.toggleAudioControl), keyEquivalent: "")
audioItem.target = menuHandler
menuHandler.audioControlItem = audioItem
menu.addItem(audioItem)

let reverseItem = NSMenuItem(title: "Reverse scroll direction", action: #selector(MenuHandler.toggleScrollReversed), keyEquivalent: "")
reverseItem.target = menuHandler
menuHandler.reverseScrollItem = reverseItem
menu.addItem(reverseItem)

let longPressMenu = NSMenu()
let longPressRightItem = NSMenuItem(title: "Right-click", action: #selector(MenuHandler.setLongPressRightClick), keyEquivalent: "")
longPressRightItem.target = menuHandler
menuHandler.longPressRightItem = longPressRightItem
longPressMenu.addItem(longPressRightItem)
let longPressDoubleItem = NSMenuItem(title: "Double-click", action: #selector(MenuHandler.setLongPressDoubleClick), keyEquivalent: "")
longPressDoubleItem.target = menuHandler
menuHandler.longPressDoubleItem = longPressDoubleItem
longPressMenu.addItem(longPressDoubleItem)
let longPressToggleAudioItem = NSMenuItem(title: "Toggle audio/scroll mode", action: #selector(MenuHandler.setLongPressToggleAudio), keyEquivalent: "")
longPressToggleAudioItem.target = menuHandler
menuHandler.longPressToggleAudioItem = longPressToggleAudioItem
longPressMenu.addItem(longPressToggleAudioItem)
let longPressRunScriptItem = NSMenuItem(title: "Run script", action: #selector(MenuHandler.setLongPressRunScript), keyEquivalent: "")
longPressRunScriptItem.target = menuHandler
menuHandler.longPressRunScriptItem = longPressRunScriptItem
longPressMenu.addItem(longPressRunScriptItem)

let longPressSub = NSMenuItem(title: "Long press", action: nil, keyEquivalent: "")
longPressSub.submenu = longPressMenu
menu.addItem(longPressSub)

menu.addItem(NSMenuItem.separator())
let configScriptsItem = NSMenuItem(title: "Configure Scripts...", action: #selector(MenuHandler.configureScripts), keyEquivalent: "")
configScriptsItem.target = menuHandler
menu.addItem(configScriptsItem)
let updateAvailableItem = NSMenuItem(title: "Update available", action: #selector(MenuHandler.openReleasesPage), keyEquivalent: "")
updateAvailableItem.target = menuHandler
updateAvailableItem.isHidden = true
menu.addItem(updateAvailableItem)

menu.addItem(NSMenuItem.separator())
let quitItem = NSMenuItem(title: "Quit PowerMate Agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
quitItem.target = app
menu.addItem(quitItem)
statusItem.menu = menu
menuHandler.updateMenuState()

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

// Periodically check whether the status item is visible in the menu bar.
// If it is hidden (notch overlap or overflow >>) show a Dock icon so the user
// can still access the menu. Check starts after a short delay to let the
// status item settle into its position on launch.
/// Returns true if the status item's window is positioned behind the camera notch.
/// safeAreaInsets.top > 0 confirms a notch is present; the horizontal notch extent
/// is estimated as ±6% of screen width from center (covers all current MacBook Pro models).
func isStatusItemBehindNotch() -> Bool {
    guard #available(macOS 12.0, *),
          let window = statusItem.button?.window,
          window.isVisible else { return false }

    let itemFrame = window.frame
    let screen = NSScreen.screens.first(where: { $0.frame.intersects(itemFrame) }) ?? NSScreen.main
    guard let screen else { return false }

    let insets = screen.safeAreaInsets
    guard insets.top > 0 else { return false }  // no notch on this screen

    let sf = screen.frame

    // Confirm item is in the top menu-bar strip.
    let inMenuBarStrip = itemFrame.maxY >= sf.maxY - insets.top

    // The notch occupies the horizontal center of the screen. safeAreaInsets gives
    // us the notch height but not its width. On all current MacBook Pro models the
    // notch is roughly 12% of screen width total, so ±6% from center.
    let notchHalfWidth = sf.width * 0.06

    // Use the inner edge (the edge of the item closest to screen center) so that
    // partial overlap is detected correctly.
    let innerEdgeX = itemFrame.midX > sf.midX ? itemFrame.minX : itemFrame.maxX
    let distanceFromCenter = abs(innerEdgeX - sf.midX)
    let behindNotch = inMenuBarStrip && distanceFromCenter < notchHalfWidth

    return behindNotch
}

var dockIconVisible = false
func updateDockIconVisibility() {
    let shouldShowDock = isStatusItemBehindNotch()
    guard shouldShowDock != dockIconVisible else { return }
    dockIconVisible = shouldShowDock
    if shouldShowDock {
        // Set image before and after the policy change; setActivationPolicy may
        // briefly reset applicationIconImage to the bundle default.
        NSApp.applicationIconImage = makeDockIcon()
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: false)
        DispatchQueue.main.async { updateDockIcon() }
    } else {
        app.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = nil  // restore default when hidden
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    updateDockIconVisibility()
    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
        updateDockIconVisibility()
    }
}

app.run()
