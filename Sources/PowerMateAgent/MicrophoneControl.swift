import Foundation
import CoreAudio

private var microphoneMutedByPowerMate = false
private var savedMicrophoneVolume: Float32 = 0.75

private func defaultInputDevice() -> AudioDeviceID? {
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
          device != kAudioObjectUnknown else { return nil }
    return device
}

private func setInputMute(_ muted: Bool, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                             mScope: kAudioDevicePropertyScopeInput,
                                             mElement: element)
    var settable = DarwinBoolean(false)
    guard AudioObjectHasProperty(device, &address),
          AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
          settable.boolValue else { return false }
    var value: UInt32 = muted ? 1 : 0
    return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
}

private func setInputVolume(_ value: Float32, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                             mScope: kAudioDevicePropertyScopeInput,
                                             mElement: element)
    var settable = DarwinBoolean(false)
    guard AudioObjectHasProperty(device, &address),
          AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
          settable.boolValue else { return false }
    var next = min(1, max(0, value))
    return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &next) == noErr
}

private func inputVolume(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                             mScope: kAudioDevicePropertyScopeInput,
                                             mElement: element)
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func toggleMicrophoneMute() {
    guard let device = defaultInputDevice() else { return }
    let muted = !microphoneMutedByPowerMate
    var changed = setInputMute(muted, device: device, element: kAudioObjectPropertyElementMain)
    if !changed {
        if muted, let current = inputVolume(device: device, element: kAudioObjectPropertyElementMain), current > 0 {
            savedMicrophoneVolume = current
        }
        let value: Float32 = muted ? 0 : max(0.05, savedMicrophoneVolume)
        changed = setInputVolume(value, device: device, element: kAudioObjectPropertyElementMain)
        if !changed {
            let left = setInputVolume(value, device: device, element: 1)
            let right = setInputVolume(value, device: device, element: 2)
            changed = left || right
        }
    }
    if changed {
        microphoneMutedByPowerMate = muted
        setLEDOffMain(muted ? 0 : 80)
    }
}
