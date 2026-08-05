import Foundation
import AppKit
import CoreGraphics

// MARK: - Rotation mode

enum RotationMode: String, Codable, CaseIterable {
    case scroll, audio, keypress
}

// MARK: - Default settings (global fallback) and per-app overrides

private let kDefaultAppSettings = "defaultAppSettings"
private let kPerAppSettings     = "perAppSettings"

/// The global fallback settings, used for any app without its own override.
var defaultSettings: AppSettings = loadDefaultSettings()

/// Per-app overrides, keyed by bundle identifier.
var perAppSettings: [String: AppSettings] = loadPerAppSettings()

/// Loads the persisted default settings, migrating from the individual flat UserDefaults
/// keys used before per-app settings existed if this is the first run on this build.
/// AppSettings.init(from:) is written to decode leniently (falling back to defaults for any
/// field that didn't exist in an older build), so the branch below only runs for installs from
/// before per-app settings existed at all (pre-1.0.17) — anyone with a 1.0.17+ blob, however old
/// its shape, decodes it directly instead of falling through here.
private func loadDefaultSettings() -> AppSettings {
    if let data = defaults.data(forKey: kDefaultAppSettings),
       let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
        return decoded
    }
    var settings = AppSettings()
    settings.scrollReversed    = defaults.bool(forKey: kScrollReversed)
    settings.fineScrollEnabled = defaults.bool(forKey: kFineScroll)
    settings.scrollAxesSwapped = defaults.bool(forKey: kScrollAxesSwapped)
    settings.audioStepSwapped  = defaults.bool(forKey: kAudioStepSwapped)
    // clickAction used to only apply in audio mode; preserve that for existing users instead of
    // migrating a stored mute/playPause value that was never actually exercised outside audio mode.
    if defaults.bool(forKey: kAudioControl) {
        settings.clickAction = defaults.string(forKey: kClickAction) == "playPause" ? .playPause : .mute
    } else {
        settings.clickAction = .leftClick
    }
    switch defaults.string(forKey: kLongPressAction) {
    case "doubleClick":      settings.longPressAction = .doubleClick
    case "toggleAudioMode":  settings.longPressAction = .toggleMode(.audioScroll)
    case "toggleFineScroll": settings.longPressAction = .toggleFineScroll
    case "runScript":        settings.longPressAction = .runScript
    default:                 settings.longPressAction = .rightClick
    }
    if defaults.bool(forKey: kKeypressMode) {
        settings.mode = .keypress
    } else if defaults.bool(forKey: kAudioControl) {
        settings.mode = .audio
    } else {
        settings.mode = .scroll
    }
    settings.keypressBindings = migrateLegacyKeypressBindings()
    return settings
}

private func loadPerAppSettings() -> [String: AppSettings] {
    guard let data = defaults.data(forKey: kPerAppSettings),
          let decoded = try? JSONDecoder().decode([String: AppSettings].self, from: data) else { return [:] }
    return decoded
}

func saveDefaultSettings() {
    guard let data = try? JSONEncoder().encode(defaultSettings) else { return }
    defaults.set(data, forKey: kDefaultAppSettings)
}

func savePerAppSettings() {
    guard let data = try? JSONEncoder().encode(perAppSettings) else { return }
    defaults.set(data, forKey: kPerAppSettings)
}

// MARK: - Resolution

/// The bundle identifier of the currently frontmost application, if any. Cheap, in-process
/// lookup — unlike menu detection, this needs no Accessibility permission.
func frontmostBundleID() -> String? {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
}

/// The effective settings for whatever app is currently frontmost: its override if one is
/// configured, otherwise the global default.
func currentSettings() -> AppSettings {
    guard let bundleID = frontmostBundleID(), let override = perAppSettings[bundleID] else {
        return defaultSettings
    }
    return override
}

/// Mutates whichever settings are currently in effect for the frontmost app — its per-app
/// override if one exists, else the global default — and persists the change. Used so
/// runtime actions like a "Toggle Mode" long press affect the app you're actually in,
/// rather than always silently editing the global default underneath it.
func mutateCurrentSettings(_ mutate: (inout AppSettings) -> Void) {
    if let bundleID = frontmostBundleID(), perAppSettings[bundleID] != nil {
        mutate(&perAppSettings[bundleID]!)
        savePerAppSettings()
    } else {
        mutate(&defaultSettings)
        saveDefaultSettings()
    }
}

/// The other mode in `pair` from `current`, or the pair's first mode if `current` isn't
/// either one of them (e.g. toggling Audio/Scroll while actually in Keypress mode).
func toggledMode(current: RotationMode, pair: ModeTogglePair) -> RotationMode {
    let (a, b) = pair.modes
    if current == a { return b }
    if current == b { return a }
    return a
}

// MARK: - App display helpers

func displayName(forBundleID bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
    let name = FileManager.default.displayName(atPath: url.path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
}

func icon(forBundleID bundleID: String) -> NSImage? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path)
}
