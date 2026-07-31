import Foundation
import AppKit

/// Applications that expose their own player volume through Apple Events.
/// Unsupported foreground apps deliberately fall back to system volume.
private enum ForegroundAudioApp {
    case music, spotify

    init?(bundleIdentifier: String?) {
        switch bundleIdentifier {
        case "com.apple.Music": self = .music
        case "com.spotify.client": self = .spotify
        default: return nil
        }
    }

    var appleScriptName: String {
        switch self { case .music: return "Music"; case .spotify: return "Spotify" }
    }
}

private let foregroundVolumeQueue = DispatchQueue(label: "com.powermate.foreground-volume", qos: .userInteractive)

/// Adjust the active player's own volume. Returns false when the active app has
/// no supported per-app volume API, allowing the caller to control system volume.
func adjustForegroundAppVolume(up: Bool, fine: Bool, presses: Int) -> Bool {
    guard let app = ForegroundAudioApp(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else {
        return false
    }
    let step = fine ? 1 : 2
    let delta = (up ? 1 : -1) * step * max(1, presses)
    let name = app.appleScriptName
    foregroundVolumeQueue.async {
        let source = """
        tell application "\(name)"
            set newVolume to (sound volume) + (\(delta))
            if newVolume > 100 then set newVolume to 100
            if newVolume < 0 then set newVolume to 0
            set sound volume to newVolume
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("PowerMate: could not control %@ volume: %@", name, error) }
    }
    return true
}

/// Send playback commands to the player that is actually playing, even when it
/// is in the background. The foreground player is the fallback when paused.
func controlForegroundPlayer(nextTrack: Bool) -> Bool {
    let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    let candidates: [ForegroundAudioApp] = [
        runningIDs.contains("com.apple.Music") ? .music : nil,
        runningIDs.contains("com.spotify.client") ? .spotify : nil,
    ].compactMap { $0 }
    guard !candidates.isEmpty else { return false }
    let foreground = ForegroundAudioApp(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    let command = nextTrack ? "next track" : "playpause"
    foregroundVolumeQueue.async {
        var selected = foreground ?? candidates[0]
        for candidate in candidates {
            let stateSource = "tell application \"\(candidate.appleScriptName)\" to return (player state as text)"
            var stateError: NSDictionary?
            let state = NSAppleScript(source: stateSource)?.executeAndReturnError(&stateError).stringValue
            if state?.lowercased() == "playing" {
                selected = candidate
                break
            }
        }
        let name = selected.appleScriptName
        let source = "tell application \"\(name)\" to \(command)"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("PowerMate: could not send %@ to %@: %@", command, name, error) }
    }
    return true
}

/// Previous-track companion used by press-and-turn.
func controlForegroundPlayer(previousTrack: Bool) -> Bool {
    guard previousTrack else { return false }
    let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    let candidates: [ForegroundAudioApp] = [
        runningIDs.contains("com.apple.Music") ? .music : nil,
        runningIDs.contains("com.spotify.client") ? .spotify : nil,
    ].compactMap { $0 }
    guard !candidates.isEmpty else { return false }
    foregroundVolumeQueue.async {
        var selected = candidates[0]
        for candidate in candidates {
            let source = "tell application \"\(candidate.appleScriptName)\" to return (player state as text)"
            var error: NSDictionary?
            if NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue?.lowercased() == "playing" {
                selected = candidate; break
            }
        }
        let source = "tell application \"\(selected.appleScriptName)\" to previous track"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("PowerMate: could not go to previous track: %@", error) }
    }
    return true
}
