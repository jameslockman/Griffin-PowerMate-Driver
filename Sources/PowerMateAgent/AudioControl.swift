import Foundation
import AppKit
import CoreAudio

// MARK: - Mute state

// Tracked in software because kAudioDevicePropertyMute is unreliable on USB/Bluetooth devices.
// Volume adjustments clear this flag (via setMuted) so it stays in sync with user intent.
private var _isMuted = false

// MARK: - NX media key events

// Posts NX system-defined media key events — the same path as physical keyboard media keys.
// NX_KEYTYPE_SOUND_UP = 0, NX_KEYTYPE_SOUND_DOWN = 1, NX_KEYTYPE_MUTE = 7,
// NX_KEYTYPE_PLAY = 16, NX_KEYTYPE_NEXT = 17, NX_KEYTYPE_PREVIOUS = 18
func postMediaKey(_ keyType: Int32, keyDown: Bool, modifiers: NSEvent.ModifierFlags = []) {
    let flags = NSEvent.ModifierFlags(rawValue: modifiers.rawValue | (keyDown ? 0xa00 : 0xb00))
    let data1 = Int(keyType) << 16 | (keyDown ? 0x0a00 : 0x0b00)
    guard let event = NSEvent.otherEvent(
        with: .systemDefined,
        location: .zero,
        modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        subtype: 8,
        data1: data1,
        data2: -1
    ) else { return }
    event.cgEvent?.post(tap: .cghidEventTap)
}

// MARK: - Volume control

private func scalarVolumeAddress(_ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                               mScope: kAudioDevicePropertyScopeOutput,
                               mElement: element)
}

private func readSystemVolume() -> Float32? {
    guard let device = outputDevice() else { return nil }
    for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
        var address = scalarVolumeAddress(element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { return value }
    }
    return nil
}

private func writeSystemVolume(_ value: Float32) -> Bool {
    guard let device = outputDevice() else { return false }
    func write(_ element: AudioObjectPropertyElement) -> Bool {
        var address = scalarVolumeAddress(element)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var next = min(1, max(0, value))
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &next) == noErr
    }
    if write(kAudioObjectPropertyElementMain) { return true }
    let left = write(1), right = write(2)
    return left || right
}

private final class SystemVolumeSmoother {
    private var timer: Timer?
    private var current: Float32 = 0
    private var target: Float32 = 0

    func add(_ delta: Float32) -> Bool {
        if timer == nil {
            guard let actual = readSystemVolume() else { return false }
            current = actual; target = actual
        }
        target = min(1, max(0, target + delta))
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common); timer = t
        }
        return true
    }

    private func tick() {
        let distance = target - current
        if abs(distance) < 0.00002 {
            current = target; _ = writeSystemVolume(current); timer?.invalidate(); timer = nil; return
        }
        current += distance * 0.28
        _ = writeSystemVolume(current)
    }
}

private let systemVolumeSmoother = SystemVolumeSmoother()

// Posts NX volume key events — identical to the physical keyboard volume keys.
// fine=false: standard step (~6.25%, same as F11/F12).
// fine=true:  shift+option step (~1.5625%, same as Shift+Option+F11/F12).
// Repeated presses for delta > 1 give velocity-proportional movement in normal mode.
func adjustVolume(up: Bool, fine: Bool, presses: Int = 1) {
    // Apple Music and Spotify have their own volume controls. If either is in
    // the foreground, change that player immediately instead of system volume.
    if adjustForegroundAppVolume(up: up, fine: fine, presses: presses) { return }
    if up && _isMuted { setMuted(false) }
    let percent = fine ? 0.001 : 0.002
    let amount = Float32(percent * Double(max(1, presses)))
    if systemVolumeSmoother.add(up ? amount : -amount) { return }
    let keyType: Int32 = up ? 0 : 1  // NX_KEYTYPE_SOUND_UP / NX_KEYTYPE_SOUND_DOWN
    let modFlags: NSEvent.ModifierFlags = fine ? [.shift, .option] : []
    for _ in 0 ..< max(1, presses) {
        postMediaKey(keyType, keyDown: true,  modifiers: modFlags)
        postMediaKey(keyType, keyDown: false, modifiers: modFlags)
    }
}

// MARK: - Mute / play-pause

func toggleMute() {
    postMediaKey(7, keyDown: true)
    postMediaKey(7, keyDown: false)
    // Toggle our software mute flag. isOutputMuted() is unreliable on USB/Bluetooth devices
    // (kAudioDevicePropertyMute may not be exposed on main element), so we track state ourselves.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        _isMuted.toggle()
    }
}

// NX_KEYTYPE_PLAY = 16 — same system-wide play/pause as the Apple keyboard media key.
func togglePlayPause() {
    postMediaKey(16, keyDown: true)
    postMediaKey(16, keyDown: false)
}

// MARK: - Hardware mute

func outputDevice() -> AudioDeviceID? {
    var deviceID: AudioDeviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var hwAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &hwAddr, 0, nil, &size, &deviceID) == noErr,
          deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

/// Write kAudioDevicePropertyMute; fire-and-forget if the device doesn't expose the property.
func setMuted(_ muted: Bool) {
    _isMuted = muted
    guard let deviceID = outputDevice() else { return }
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = muted ? 1 : 0
    let size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &value)
}
