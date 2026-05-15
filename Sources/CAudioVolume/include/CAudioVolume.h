#pragma once

/// Get the macOS virtual main volume (0.0–1.0), which maps linearly to the
/// system volume display and is what F11/F12 and the volume slider control.
/// Returns -1.0 on failure.
float caudio_get_volume(void);

/// Set the macOS virtual main volume (0.0–1.0).
void caudio_set_volume(float volume);
