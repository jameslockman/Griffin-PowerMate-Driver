import Foundation
import AppKit

// MARK: - Icon loading

private let dockIconInsetRatio: CGFloat = 0.1 // macOS app icons keep roughly 10% inset per edge.

/// Load a named icon from the bundle, checking .icns first then .png.
private func loadBundleIcon(_ name: String) -> NSImage? {
    for ext in ["icns", "png"] {
        if let path = Bundle.main.path(forResource: name, ofType: ext),
           let img = NSImage(contentsOfFile: path) {
            return NSImage(size: img.size, flipped: false) { bounds in
                let inset = bounds.width * dockIconInsetRatio
                img.draw(in: bounds.insetBy(dx: inset, dy: inset))
                return true
            }
        }
    }
    return nil
}

// MARK: - Dock icon

/// Returns the dock icon image for the current connection/mode state.
/// Uses custom bundle images when available, otherwise falls back to SF Symbols.
func makeDockIcon() -> NSImage? {
    if !driver.isConnected {
        if let img = loadBundleIcon("DockIconDisconnected") { return img }
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            .applying(NSImage.SymbolConfiguration(pointSize: 96, weight: .regular))
        return NSImage(systemSymbolName: "circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    } else if defaultSettings.mode == .audio {
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

// MARK: - Status bar icon

func updateStatusIcon() {
    guard let button = statusItem.button else { return }
    button.contentTintColor = nil
    if !driver.isConnected {
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let img = NSImage(systemSymbolName: "circle", accessibilityDescription: "PowerMate Agent — Not connected")?
            .withSymbolConfiguration(config)
        img?.isTemplate = false
        button.image = img
    } else if defaultSettings.mode == .audio {
        let config = NSImage.SymbolConfiguration(paletteColors: [.labelColor, .systemBlue])
        let img = NSImage(systemSymbolName: "circle.inset.filled", accessibilityDescription: "PowerMate Agent — Audio mode")?
            .withSymbolConfiguration(config)
        img?.isTemplate = false
        button.image = img
    } else {
        let img = NSImage(systemSymbolName: "circle.inset.filled", accessibilityDescription: "PowerMate Agent")
        img?.isTemplate = true
        button.image = img
    }
}

// MARK: - Notch / dock icon visibility

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

    return inMenuBarStrip && distanceFromCenter < notchHalfWidth
}

var dockIconVisible: Bool {
    NSApp.activationPolicy() == .regular
}

private var dockVisibilityTimer: Timer?

func updateDockIconVisibility() {
    let shouldShowDock = !defaults.bool(forKey: kHideDockIcon) && isStatusItemBehindNotch()
    guard shouldShowDock != dockIconVisible else { return }
    if shouldShowDock {
        // Set image before and after the policy change; setActivationPolicy may
        // briefly reset applicationIconImage to the bundle default.
        NSApp.applicationIconImage = makeDockIcon()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: false)
        DispatchQueue.main.async { updateDockIcon() }
    } else {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = nil  // restore default when hidden
    }
}

func updateDockIconVisibilityAndTimer() {
    dockVisibilityTimer?.invalidate()
    dockVisibilityTimer = nil
    updateDockIconVisibility()
    guard !defaults.bool(forKey: kHideDockIcon) else { return }

    dockVisibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
        updateDockIconVisibility()
    }
    dockVisibilityTimer?.tolerance = 0.2
}
