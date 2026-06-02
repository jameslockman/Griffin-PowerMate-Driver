import Foundation
import AppKit
import ApplicationServices

// MARK: - Menu mode state

// Menu behavior: use arrow keys + Return when a menu (or submenu) is focused.
// We use the Accessibility API so submenus are detected; long-press timeout is fallback.
var isMenuMode = false
var menuModeTimeout: DispatchWorkItem?
let menuModeTimeoutInterval: TimeInterval = 5.0

// MARK: - Accessibility menu detection

// Cached system-wide AX element (reused; creating it per call is wasteful).
private let axSystemWide = AXUIElementCreateSystemWide()
// isMenuFocused result cache: AX IPC is expensive and the menu state rarely changes
// between knob ticks. A 150 ms TTL caps IPC calls to ~7/sec even during fast spinning.
private var cachedMenuFocused = false
private var menuFocusCacheTime: CFAbsoluteTime = 0
private let menuFocusCacheTTL: CFAbsoluteTime = 0.15

/// Returns true if the currently focused UI element is a menu or menu item (or inside one,
/// e.g. a submenu). Requires Accessibility permission. Runs on main thread.
func isMenuFocused() -> Bool {
    guard Thread.isMainThread else { return false }
    let now = CFAbsoluteTimeGetCurrent()
    if now - menuFocusCacheTime < menuFocusCacheTTL { return cachedMenuFocused }
    menuFocusCacheTime = now
    var appRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axSystemWide, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
          let app = appRef, CFGetTypeID(app) == AXUIElementGetTypeID() else {
        cachedMenuFocused = false
        return false
    }
    let appElement = (app as! AXUIElement)
    var focusRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusRef) == .success,
          let focus = focusRef, CFGetTypeID(focus) == AXUIElementGetTypeID() else {
        cachedMenuFocused = false
        return false
    }
    var element: AXUIElement? = (focus as! AXUIElement)
    var count = 0
    let maxAncestors = 20
    while let el = element, count < maxAncestors {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role == "AXMenu" || role == "AXMenuItem" {
            cachedMenuFocused = true
            return true
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

// MARK: - Mode selection

/// True when rotation and clicks should send arrow keys / Return (menu or submenu active).
func useMenuBehavior() -> Bool {
    isMenuMode || isMenuFocused()
}

/// True when rotation and clicks should control audio (XOR with Fn to momentarily flip).
func useAudioBehavior() -> Bool {
    let fnHeld = NSEvent.modifierFlags.contains(.function)
    let wantAudio = audioControlEnabled != fnHeld   // XOR: Fn flips whatever the setting is
    return wantAudio && !useMenuBehavior()
}

// MARK: - Menu mode lifecycle

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
