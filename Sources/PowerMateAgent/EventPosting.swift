import Foundation
import AppKit
import CoreGraphics

// MARK: - HID event source

// Using a HID system state source makes all synthetic events indistinguishable from
// real hardware events. Apps that inspect the event source route hardware-sourced events
// via keyboard/input focus; nil-sourced (synthetic) events may fall back to spatial
// (cursor-position) routing, causing inconsistent behaviour across applications.
let kHIDEventSource = CGEventSource(stateID: .hidSystemState)

// MARK: - Scroll

// Pixels per knob delta unit. Pixel units + isContinuous = 1 produces trackpad-style
// smooth scrolling rather than the discrete line jumps that .line units give.
private let scrollPixelsPerStep: Int32 = 20

func postScroll(delta: Int, horizontal: Bool = false, fine: Bool = false, reversed: Bool = false) {
    let step = fine ? Int32(1) : scrollPixelsPerStep
    var pixels = Int32(delta) * step
    if reversed { pixels = -pixels }
    let wheel1: Int32 = horizontal ? 0 : pixels
    let wheel2: Int32 = horizontal ? pixels : 0
    guard let event = CGEvent(
        scrollWheelEvent2Source: kHIDEventSource,
        units: .pixel,
        wheelCount: 2,
        wheel1: wheel1,
        wheel2: wheel2,
        wheel3: 0
    ) else { return }
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.post(tap: .cghidEventTap)
}

// MARK: - Keyboard

// Key codes (HIToolbox): Up = 0x7E, Down = 0x7D, Return = 0x24
let kUpArrow: CGKeyCode   = 0x7E
let kDownArrow: CGKeyCode = 0x7D
let kReturnKey: CGKeyCode = 0x24

/// Post one key press (down + up), optionally with modifier flags held (e.g. Control+Option).
func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    guard let down = CGEvent(keyboardEventSource: kHIDEventSource, virtualKey: keyCode, keyDown: true),
          let up   = CGEvent(keyboardEventSource: kHIDEventSource, virtualKey: keyCode, keyDown: false) else { return }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

// MARK: - Mouse

/// Convert Cocoa screen point (bottom-left origin) to Quartz (top-left origin).
func cocoaToQuartz(_ cocoa: NSPoint) -> CGPoint {
    let screen = NSScreen.screens.first { NSMouseInRect(cocoa, $0.frame, false) } ?? NSScreen.main
    let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    return CGPoint(x: cocoa.x, y: frame.maxY - cocoa.y)
}

/// Post a mouse click at the given Quartz location.
func postMouseClick(at location: CGPoint, button: CGMouseButton = .left) {
    let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
    let upType: CGEventType   = button == .left ? .leftMouseUp   : .rightMouseUp
    if let down = CGEvent(mouseEventSource: kHIDEventSource, mouseType: downType, mouseCursorPosition: location, mouseButton: button),
       let up   = CGEvent(mouseEventSource: kHIDEventSource, mouseType: upType,   mouseCursorPosition: location, mouseButton: button) {
        // Real clicks always carry a clickState >= 1; some apps' event routing doesn't
        // expect the field to be left at its unset default.
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// Post a proper double-click using kCGMouseEventClickState = 2 so the system treats
/// it as one double-click, not two single clicks.
func postDoubleClick(at location: CGPoint) {
    guard let down1 = CGEvent(mouseEventSource: kHIDEventSource, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
          let up1   = CGEvent(mouseEventSource: kHIDEventSource, mouseType: .leftMouseUp,   mouseCursorPosition: location, mouseButton: .left),
          let down2 = CGEvent(mouseEventSource: kHIDEventSource, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
          let up2   = CGEvent(mouseEventSource: kHIDEventSource, mouseType: .leftMouseUp,   mouseCursorPosition: location, mouseButton: .left) else { return }
    down1.setIntegerValueField(.mouseEventClickState, value: 1)
    up1.setIntegerValueField(.mouseEventClickState, value: 1)
    down1.post(tap: .cghidEventTap)
    up1.post(tap: .cghidEventTap)
    down2.setIntegerValueField(.mouseEventClickState, value: 2)
    up2.setIntegerValueField(.mouseEventClickState, value: 2)
    down2.post(tap: .cghidEventTap)
    up2.post(tap: .cghidEventTap)
}

/// Post a left or right mouse click at the current cursor position.
func postMouseClick(button: CGMouseButton = .left) {
    DispatchQueue.main.async {
        let cocoa = NSEvent.mouseLocation
        let location = cocoaToQuartz(cocoa)
        postMouseClick(at: location, button: button)
    }
}
