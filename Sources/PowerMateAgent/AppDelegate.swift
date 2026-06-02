import Foundation
import AppKit

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
