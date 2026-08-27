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

// MARK: - Dock icon visibility

var dockIconVisible: Bool {
    NSApp.activationPolicy() == .regular
}

func updateDockIconVisibility() {
    let shouldShowDock = !defaults.bool(forKey: kHideDockIcon)
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
