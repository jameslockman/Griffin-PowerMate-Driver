import Foundation
import AppKit

// MARK: - UserDefaults

let defaults = UserDefaults.standard

let kScrollReversed   = "scrollReversed"
let kAudioControl     = "audioControlEnabled"
let kClickAction      = "clickAction"
let kVUMeter          = "vuMeterEnabled"
let kLongPressAction  = "longPressAction"
let kScript1          = "script1"
let kScript2          = "script2"
let kAudioStepSwapped  = "audioStepSwapped"
let kScrollAxesSwapped = "scrollAxesSwapped"
let kFineScroll        = "fineScrollEnabled"

// MARK: - Persistent state

var scrollReversed      = defaults.bool(forKey: kScrollReversed)
// The knob is a volume controller by default. Users can still toggle scroll mode.
var audioControlEnabled = defaults.object(forKey: kAudioControl) == nil ? true : defaults.bool(forKey: kAudioControl)
// VU meter defaults to true for existing users; only false if explicitly disabled.
var vuMeterEnabled      = defaults.object(forKey: kVUMeter) == nil ? true : defaults.bool(forKey: kVUMeter)
// When true, the default turn is fine step and Shift is standard step (swapped from default).
var audioStepSwapped    = defaults.bool(forKey: kAudioStepSwapped)
// When true, the default turn scrolls horizontally and Shift+turn scrolls vertically.
var scrollAxesSwapped   = defaults.bool(forKey: kScrollAxesSwapped)
// When true, each tick scrolls by 1 pixel instead of the default coarse step.
var fineScrollEnabled   = defaults.bool(forKey: kFineScroll)

// MARK: - Click action

enum ClickAction { case mute, playPause }
var clickAction: ClickAction = {
    switch defaults.string(forKey: kClickAction) {
    case "playPause": return .playPause
    default:          return .mute
    }
}()

// MARK: - Long press action

enum LongPressAction { case rightClick, doubleClick, toggleAudioMode, toggleFineScroll, runScript }
var longPressAction: LongPressAction = {
    switch defaults.string(forKey: kLongPressAction) {
    case "doubleClick":      return .doubleClick
    case "toggleAudioMode":  return .toggleAudioMode
    case "toggleFineScroll": return .toggleFineScroll
    case "runScript":        return .runScript
    default:                 return .rightClick
    }
}()
