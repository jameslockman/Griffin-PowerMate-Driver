import Foundation
import AppKit
import CoreAudio

// MARK: - Mode change signaling

/// Load a sound by name, checking the app bundle Resources first, then falling back to system sounds.
/// Place custom files named e.g. "ToAudio.aiff" / "ToScroll.aiff" in scripts/Sounds/ and they will
/// be bundled into the app automatically by build-app.sh.
private func loadSound(_ name: String) -> NSSound? {
    if let url = Bundle.main.url(forResource: name, withExtension: nil)
        ?? Bundle.main.url(forResource: name, withExtension: "aiff")
        ?? Bundle.main.url(forResource: name, withExtension: "wav")
        ?? Bundle.main.url(forResource: name, withExtension: "mp3") {
        return NSSound(contentsOf: url, byReference: false)
    }
    return NSSound(named: NSSound.Name(name))
}

/// Flash the LED twice and play a sound to confirm a mode switch.
/// toAudio: true  → switching into audio mode ("ToAudio" bundle sound or "Tink" fallback)
/// toAudio: false → switching back to scroll mode ("ToScroll" bundle sound or "Glass" fallback)
func signalModeChange(toAudio: Bool) {
    ledQueue.async {
        for _ in 0..<2 {
            _ = driver.setLEDBrightness(255)
            Thread.sleep(forTimeInterval: 0.055)
            _ = driver.setLEDBrightness(0)
            Thread.sleep(forTimeInterval: 0.055)
        }
        _ = driver.setLEDBrightness(80)
    }
    DispatchQueue.main.async {
        let sound = toAudio ? loadSound("ToAudio") ?? NSSound(named: "Tink")
                            : loadSound("ToScroll") ?? NSSound(named: "Glass")
        sound?.play()
    }
}

// MARK: - VU meter state

// Audio amplitude metering — drives the LED as a VU meter when audio control mode is on.
// Uses CATapDescription + AudioHardwareCreateProcessTap (macOS 14.2+) to tap the system
// stereo output mix via a direct CoreAudio IOProc. No AVAudioEngine, no extra permissions.
var audioMeterActive = false
private var audioTapID: AudioObjectID = 0
private var audioAggDeviceID: AudioDeviceID = 0
private var audioTapProcID: AudioDeviceIOProcID?

// LED update throttle for the audio VU meter.
// The IOProc fires at the hardware buffer rate (~86–172 Hz) but the LED only needs
// to update at ~25 Hz for a smooth-looking VU effect.
// kLEDUpdateInterval: minimum seconds between LED updates (0.04 = 25 Hz).
// kLEDUpdateThreshold: minimum brightness change required to send a USB command,
//   avoiding redundant writes when amplitude is steady.
private var lastLEDBrightness: UInt8 = 0
private var lastLEDUpdateTime: CFAbsoluteTime = 0
private let kLEDUpdateInterval: CFAbsoluteTime = 0.04   // 25 Hz
private let kLEDUpdateThreshold: Int = 4

// MARK: - Meter lifecycle

@available(macOS 14.2, *)
func startAudioMeter() {
    guard !audioMeterActive, vuMeterEnabled else { return }

    // 1. Create the process tap (AudioTap object, NOT an AudioDevice).
    let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    var tapID: AudioObjectID = 0
    guard AudioHardwareCreateProcessTap(tapDesc, &tapID) == noErr else { return }

    // 2. Retrieve the tap's UID string so we can reference it in the aggregate device.
    var tapUID: Unmanaged<CFString>? = nil
    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var uidAddr = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, &tapUID)
    guard let tapUIDString = tapUID?.takeRetainedValue() as String? else {
        AudioHardwareDestroyProcessTap(tapID)
        return
    }

    // 3. Wrap the tap in a private aggregate device — that IS an AudioDevice and accepts IOProcs.
    let composition: NSDictionary = [
        kAudioAggregateDeviceNameKey:      "PowerMate Meter" as NSString,
        kAudioAggregateDeviceUIDKey:       "com.powermate.agent.meter.\(UUID().uuidString)" as NSString,
        kAudioAggregateDeviceIsPrivateKey: 1 as NSNumber,
        kAudioAggregateDeviceTapListKey:   [[kAudioSubTapUIDKey: tapUIDString as NSString]] as NSArray,
    ]
    var aggDeviceID: AudioDeviceID = 0
    guard AudioHardwareCreateAggregateDevice(composition, &aggDeviceID) == noErr else {
        AudioHardwareDestroyProcessTap(tapID)
        return
    }

    // 4. Register an IOProc on the aggregate device; tap audio arrives in inInputData.
    var procID: AudioDeviceIOProcID?
    guard AudioDeviceCreateIOProcIDWithBlock(&procID, aggDeviceID, nil, {
        _, inInputData, _, _, _ in
        guard audioMeterActive, !isButtonDown else { return }
        // Gate: skip the RMS calculation entirely until the update interval has elapsed.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLEDUpdateTime >= kLEDUpdateInterval else { return }
        lastLEDUpdateTime = now
        let buf = inInputData.pointee.mBuffers
        guard let raw = buf.mData else { return }
        let samples = raw.assumingMemoryBound(to: Float32.self)
        let count = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size
        guard count > 0 else { return }
        var sum: Float32 = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = sqrtf(sum / Float32(count))
        let brightness = max(UInt8(20), UInt8(clamping: Int((rms * 1200).rounded())))
        guard abs(Int(brightness) - Int(lastLEDBrightness)) > kLEDUpdateThreshold else { return }
        lastLEDBrightness = brightness
        setLEDOffMain(brightness)
    }) == noErr, let procID else {
        AudioHardwareDestroyAggregateDevice(aggDeviceID)
        AudioHardwareDestroyProcessTap(tapID)
        return
    }

    guard AudioDeviceStart(aggDeviceID, procID) == noErr else {
        AudioDeviceDestroyIOProcID(aggDeviceID, procID)
        AudioHardwareDestroyAggregateDevice(aggDeviceID)
        AudioHardwareDestroyProcessTap(tapID)
        return
    }

    audioTapID = tapID
    audioAggDeviceID = aggDeviceID
    audioTapProcID = procID
    audioMeterActive = true
}

func stopAudioMeter() {
    guard audioMeterActive else { return }
    audioMeterActive = false
    lastLEDBrightness = 0
    lastLEDUpdateTime = 0
    if audioAggDeviceID != 0 {
        if let procID = audioTapProcID {
            AudioDeviceStop(audioAggDeviceID, procID)
            AudioDeviceDestroyIOProcID(audioAggDeviceID, procID)
            audioTapProcID = nil
        }
        AudioHardwareDestroyAggregateDevice(audioAggDeviceID)
        audioAggDeviceID = 0
    }
    if audioTapID != 0 {
        if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(audioTapID) }
        audioTapID = 0
    }
    if !isButtonDown { setLEDOffMain(80) }
}
