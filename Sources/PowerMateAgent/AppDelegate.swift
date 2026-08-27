import Foundation
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Start as an accessory while launching; the saved "Hide dock icon" preference is applied
    /// after the application enters its run loop.
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
