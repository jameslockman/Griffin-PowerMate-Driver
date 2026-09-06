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

/// Shared action config for both the click and double-click gestures. `leftClick` is a plain
/// left mouse click (the behavior every click had before this action became configurable);
/// `none` means "do nothing" and is only meant for double-click, so leaving it unconfigured
/// doesn't cost every single click any detection latency (see PowerMateDriver's
/// shouldWaitForDoubleClick). `custom` sends a user-recorded keystroke.
enum ClickAction: Equatable {
    case none
    case leftClick
    case rightClick
    case mute
    case playPause
    case custom(KeyBinding)
}

extension ClickAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case custom
    }

    /// Before this action became configurable, `ClickAction` was `enum ClickAction: String,
    /// Codable { case mute, playPause }`, which encodes as a bare JSON string (e.g. "mute") —
    /// not the keyed-container format Swift's synthesized Codable would use for this enum now
    /// that it has an associated-value case. Decoding that old format with the auto-synthesized
    /// implementation throws (see the migration audit that added this), silently discarding the
    /// whole settings blob. So encode/decode are hand-written: every case still round-trips as a
    /// plain string except `.custom`, which needs somewhere to put its KeyBinding — and a bare
    /// string decodes correctly whether it was written by this code or by the old enum.
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            switch raw {
            case "leftClick":  self = .leftClick
            case "rightClick": self = .rightClick
            case "mute":       self = .mute
            case "playPause":  self = .playPause
            default:           self = .none
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .custom(try container.decode(KeyBinding.self, forKey: .custom))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .none, .leftClick, .rightClick, .mute, .playPause:
            var container = encoder.singleValueContainer()
            try container.encode(rawCaseName)
        case .custom(let binding):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(binding, forKey: .custom)
        }
    }

    private var rawCaseName: String {
        switch self {
        case .none:       return "none"
        case .leftClick:  return "leftClick"
        case .rightClick: return "rightClick"
        case .mute:       return "mute"
        case .playPause:  return "playPause"
        case .custom:     return "custom"
        }
    }
}

/// Executes a configured click or double-click action. Shift swaps mute/play-pause for each
/// other, matching the original audio-mode-only behavior.
func performClickAction(_ action: ClickAction) {
    switch action {
    case .none:
        break
    case .leftClick:
        postMouseClick(button: .left)
    case .rightClick:
        postMouseClick(button: .right)
    case .mute:
        NSEvent.modifierFlags.contains(.shift) ? togglePlayPause() : toggleMute()
    case .playPause:
        NSEvent.modifierFlags.contains(.shift) ? toggleMute() : togglePlayPause()
    case .custom(let binding):
        postKey(binding.keyCode, flags: binding.flags)
    }
}

extension ClickAction {
    var customBinding: KeyBinding? {
        if case .custom(let binding) = self { return binding }
        return nil
    }
}

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
    case custom(KeyBinding)
}

extension LongPressAction {
    var customBinding: KeyBinding? {
        if case .custom(let binding) = self { return binding }
        return nil
    }
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
    var clickAction: ClickAction = .leftClick
    var doubleClickAction: ClickAction = .none
    var longPressAction: LongPressAction = .rightClick
    var keypressBindings: [TurnDirection: [TurnSlot: KeyBinding]] = defaultKeypressBindings()
    /// Per-app override for the "Run Script" long-press action. nil means "no override — use
    /// the global default script from Configure Scripts...", not "run an empty script".
    var script1: String?
    var script2: String?
    /// Key held down for as long as the PowerMate button is held, for push-to-talk style
    /// targets (e.g. dictation bound to a bare Fn). nil — the default — means the button keeps
    /// its normal click/double-click/long-press behavior. When set, a short tap still resolves
    /// as a click (or double-click); the key is pressed only once the button has stayed down
    /// past a short arming delay, after which the release gestures are suppressed. Long press
    /// is therefore never reachable while a hold key is set (see main.swift).
    var holdKey: KeyBinding?
    /// When true, a press+turn sends its "Press + Turn" key once for the whole press instead of
    /// once per detent, turning the gesture into a flick: hold, one nudge left or right, release.
    /// Meant for toggling things (a quick-note window, a palette) where repeating would undo it.
    var pressTurnOncePerPress = false
}

extension AppSettings {
    private enum CodingKeys: String, CodingKey {
        case mode, scrollReversed, fineScrollEnabled, scrollAxesSwapped, audioStepSwapped
        case clickAction, doubleClickAction, longPressAction, keypressBindings, script1, script2
        case holdKey, pressTurnOncePerPress
    }

    /// Decodes leniently: a key missing from the stored JSON (because it was saved by an older
    /// build, before that field existed — e.g. every field added after 1.0.17, when this blob
    /// format was introduced) falls back to that field's normal default, exactly as if this were
    /// a freshly created AppSettings(). The auto-synthesized Decodable this replaces requires
    /// every key to be present and throws otherwise, which — combined with `try?` at the call
    /// site in AppOverrides.swift — silently discards the *entire* stored blob (all per-app
    /// overrides, or the global default) the moment any single field is added or changed. That's
    /// exactly the failure mode this initializer exists to avoid; keep decoding this way for any
    /// future field additions too.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()

        mode              = try container.decodeIfPresent(RotationMode.self, forKey: .mode) ?? fallback.mode
        scrollReversed    = try container.decodeIfPresent(Bool.self, forKey: .scrollReversed) ?? fallback.scrollReversed
        fineScrollEnabled = try container.decodeIfPresent(Bool.self, forKey: .fineScrollEnabled) ?? fallback.fineScrollEnabled
        scrollAxesSwapped = try container.decodeIfPresent(Bool.self, forKey: .scrollAxesSwapped) ?? fallback.scrollAxesSwapped
        audioStepSwapped  = try container.decodeIfPresent(Bool.self, forKey: .audioStepSwapped) ?? fallback.audioStepSwapped

        // doubleClickAction didn't exist before 1.0.18, so its absence marks this as a
        // pre-1.0.18 blob. Before 1.0.18, clickAction was only ever exercised in Audio mode —
        // the stored value (usually just the compiled-in default, "mute") was never actually
        // chosen by the user for any other mode. Now that click is mode-independent, decoding
        // that value at face value would make it suddenly start firing for non-audio-mode
        // users. So for old blobs outside Audio mode, use the plain-left-click behavior they
        // actually had instead of whatever click action happens to be stored.
        let isPre1_0_18 = !container.contains(.doubleClickAction)
        let decodedClickAction = try container.decodeIfPresent(ClickAction.self, forKey: .clickAction) ?? fallback.clickAction
        clickAction = (isPre1_0_18 && mode != .audio) ? .leftClick : decodedClickAction

        doubleClickAction = try container.decodeIfPresent(ClickAction.self, forKey: .doubleClickAction) ?? fallback.doubleClickAction
        longPressAction   = try container.decodeIfPresent(LongPressAction.self, forKey: .longPressAction) ?? fallback.longPressAction
        keypressBindings  = try container.decodeIfPresent([TurnDirection: [TurnSlot: KeyBinding]].self, forKey: .keypressBindings) ?? fallback.keypressBindings
        script1 = try container.decodeIfPresent(String.self, forKey: .script1)
        script2 = try container.decodeIfPresent(String.self, forKey: .script2)
        holdKey = try container.decodeIfPresent(KeyBinding.self, forKey: .holdKey)
        pressTurnOncePerPress = try container.decodeIfPresent(Bool.self, forKey: .pressTurnOncePerPress) ?? fallback.pressTurnOncePerPress
    }
}
