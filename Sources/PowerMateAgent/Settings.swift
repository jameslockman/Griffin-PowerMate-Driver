import Foundation
import AppKit

// MARK: - UserDefaults

let defaults = UserDefaults.standard

// Legacy flat keys, from before per-app settings existed. Read once during migration
// in AppOverrides.swift, then superseded by the defaultAppSettings/perAppSettings blobs.
let kScrollReversed    = "scrollReversed"
let kAudioControl      = "audioControlEnabled"
let kClickAction       = "clickAction"
let kVUMeter           = "vuMeterEnabled"
let kLongPressAction   = "longPressAction"
let kScript1           = "script1"
let kScript2           = "script2"
let kAudioStepSwapped  = "audioStepSwapped"
let kScrollAxesSwapped = "scrollAxesSwapped"
let kFineScroll        = "fineScrollEnabled"
let kKeypressMode      = "keypressModeEnabled"

// MARK: - Global (not per-app) persistent state

// VU meter defaults to true for existing users; only false if explicitly disabled.
var vuMeterEnabled = defaults.object(forKey: kVUMeter) == nil ? true : defaults.bool(forKey: kVUMeter)

// MARK: - Click action

enum ClickAction: String, Codable { case mute, playPause }

// MARK: - Long press action

/// Which two modes a "Toggle Mode" long press switches between.
enum ModeTogglePair: String, Codable, CaseIterable {
    case audioScroll, audioKeypress, scrollKeypress

    var modes: (RotationMode, RotationMode) {
        switch self {
        case .audioScroll:    return (.audio, .scroll)
        case .audioKeypress:  return (.audio, .keypress)
        case .scrollKeypress: return (.scroll, .keypress)
        }
    }

    var title: String {
        switch self {
        case .audioScroll:    return "Audio/Scroll"
        case .audioKeypress:  return "Audio/Keypress"
        case .scrollKeypress: return "Scroll/Keypress"
        }
    }
}

/// Long press is per-app capable (part of AppSettings) so different apps can trigger
/// different actions on long press, same as mode and the other rotation settings.
enum LongPressAction: Codable, Equatable {
    case rightClick
    case leftClick
    case doubleClick
    case toggleMode(ModeTogglePair)
    case toggleFineScroll
    case runScript
}

// MARK: - Per-app-capable settings

/// Every setting that can vary by which application is in the foreground: which mode
/// rotation uses, the behavior details within that mode, and the long-press action.
/// See AppOverrides.swift for how the effective instance is resolved (per-app override,
/// falling back to the default).
struct AppSettings: Codable {
    var mode: RotationMode = .scroll
    var scrollReversed     = false
    var fineScrollEnabled  = false
    var scrollAxesSwapped  = false
    var audioStepSwapped   = false
    var clickAction: ClickAction = .mute
    var longPressAction: LongPressAction = .rightClick
    var keypressBindings: [TurnDirection: [TurnSlot: KeyBinding]] = defaultKeypressBindings()
}
