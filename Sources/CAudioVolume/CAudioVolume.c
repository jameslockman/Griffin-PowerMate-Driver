// CAudioVolume.c — thin C wrapper for VirtualMainVolume volume control.
//
// AudioHardwareService.h was removed from the public SDK in macOS 15, but the
// underlying symbols remain in AudioToolbox. We declare what we need manually
// so the linker can resolve them without any deprecated-declaration warnings.

#include "include/CAudioVolume.h"
#include <CoreAudio/CoreAudio.h>

// --- Manual declarations (symbols still present in AudioToolbox) ---

// kAudioHardwareServiceDeviceProperty_VirtualMainVolume = 'vmvl'
#define kVMVL ((AudioObjectPropertySelector)0x766d766cu)

extern OSStatus AudioHardwareServiceGetPropertyData(
    AudioObjectID inObjectID,
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 *ioDataSize,
    void *outData);

extern OSStatus AudioHardwareServiceSetPropertyData(
    AudioObjectID inObjectID,
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 inDataSize,
    const void *inData);

// --- Implementation ---

static AudioDeviceID default_output_device(void) {
    AudioDeviceID id = 0;
    UInt32 size = sizeof(id);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &id);
    return id;
}

float caudio_get_volume(void) {
    AudioDeviceID dev = default_output_device();
    if (!dev) return -1.f;
    AudioObjectPropertyAddress addr = { kVMVL, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    Float32 vol = 0.f;
    UInt32 size = sizeof(vol);
    return AudioHardwareServiceGetPropertyData(dev, &addr, 0, NULL, &size, &vol) == noErr
        ? (float)vol : -1.f;
}

void caudio_set_volume(float volume) {
    AudioDeviceID dev = default_output_device();
    if (!dev) return;
    AudioObjectPropertyAddress addr = { kVMVL, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    Float32 vol = volume < 0.f ? 0.f : volume > 1.f ? 1.f : (Float32)volume;
    UInt32 size = sizeof(vol);
    AudioHardwareServiceSetPropertyData(dev, &addr, 0, NULL, size, &vol);
}
