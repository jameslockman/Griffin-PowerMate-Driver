# Griffin PowerMate driver for modern MacOS

This small driver enables the Griffin PowerMate, a nifty little device from days gone by. What does the PowerMate do? It is a knob that you can twist or that you can press. That's it. It also has a blue LED in the base that can change intensity based on what you're doing.

When it was released, it was intended to assist video and audio production by adding a scrollable knob to your desktop. Of course, modern controllers exist that offer many more literal bells and whistles, but there is something... quaint... about this early device.

To install, download the latest release from the [releases tab](https://github.com/jameslockman/Griffin-PowerMate-Driver/releases). Download and open the DMG, and then drag **PowerMate Agent** to your Applications folder. Then, launch **PowerMate Agent**.  Of course, it won't do anything without a PowerMate, so go dig around in your junk USB drawer and dust it off! You will see a new item in your top menu to control the behavior of the PowerMate. If you want it to launch when you start your Mac, add it to your startup items.



The PowerMate acts as a scroll control, so if the active window or control has a scroll option, turning the dial will scroll the window or increase/decrease selected value. You can reverse the scroll direction if you don't like the default scroll direction.

The PowerMate can also act as a mouse button. A momentary push of the button acts as a mouse click when in scroll mode. A long-press of the button acts as a right-click. You can also change the behavior so that a long-press acts as a double-click or switches between scroll and audio mode.

**Audio mode**: Enable "Audio mode" in the menu and the knob adjusts system volume while the button toggles mute. When audio mode is active, the LED brightens and dims in sync with the amplitude of whatever is playing through your speakers. A short sound cue confirms the switch — up when entering audio mode, and down when returning to scroll. The menu bar icon's ring turns blue while audio mode is active so you can tell at a glance which mode you're in.

Holding the **Fn key** temporarily flips the current mode — if audio is off, Fn switches to audio; if audio is on, Fn switches back to scrolling. **Long press** can also be configured to toggle between modes directly, which is handy if you switch often and prefer not to use the Fn key.

All configuration choices (scroll direction, audio controls, long-press action) are saved automatically and restored the next time the app launches.

On first launch, PowerMate Agent will prompt you to grant **Accessibility** permission. When you first enable audio controls, it will also prompt for **Audio Capture** permission. Both are required for full functionality.







Pretty simple, eh?

## Technical details if you want to fork this repo and build your own.

A small macOS driver that opens the **Griffin PowerMate** (VID `0x077d`, PID `0x0410`) over USB HID, reads its 6-byte reports, and exposes **button** and **rotation** events so you can map them to actions (e.g. scroll, click, media keys).

The device reports on the bus but does nothing by default on macOS; this library **seizes** the device and delivers events to your app.

## Report format (from device)

- **Byte 0**: Button state — `0` = released, `1` = pressed  
- **Byte 1**: Rotation delta — signed; positive = clockwise, negative = counter‑clockwise (typically ±1 to ±7 per report). The device does not report speed directly; the driver derives **rotation rate** (deltas per second) from the time between reports.

## Build and run

```bash
cd /path/to/USB
swift build
swift run PowerMateDemo
```

With the PowerMate plugged in, turn the knob or press the button; the demo prints events. Stop with Ctrl+C.

## System-wide driver (PowerMate Agent)

**PowerMateAgent** turns the knob and button into keyboard/scroll events that **any application** receives (browser, editor, etc.):

- **Rotation** → vertical scroll, or **Up/Down arrow keys** when a menu (or submenu) is focused, or **system volume** in audio control mode.
- **Click** (short press) → **left mouse button** (at cursor), or **Return** when a menu is focused (chooses the highlighted item), or **mute/unmute** in audio control mode.
- **Long press** → **right mouse button**, or configurable to double-click or **toggle audio/scroll mode**.

**Menu detection** uses the Accessibility API: when the focused UI element is a menu or submenu, rotation sends arrow keys and click sends Return. A long-press also enters a fallback “menu mode” (arrow keys until click or 5-second timeout) if Accessibility is not enabled.

**Audio mode** — enable “Audio mode” in the menu, hold **Fn** to temporarily flip, or configure long press to toggle. A “Tink” plays when entering audio mode; a “Pop” plays when returning to scroll. Fn always XORs the current mode without a sound cue since it's held, not toggled.

**LED VU meter** — when audio control mode is active, the LED brightness tracks the RMS amplitude of the system audio output in real time using `AudioHardwareCreateProcessTap`.

**Persistent settings** — scroll direction, audio mode, and long-press action are remembered across launches.

The LED throbs while you turn and goes dim when idle; full brightness while the button is held.

```bash
swift run PowerMateAgent
```

On first run, macOS will prompt for **Input Monitoring** permission. Grant it in **System Settings → Privacy & Security → Input Monitoring** and add (or enable) the Terminal or the built executable, then run the agent again.

To run in the background: `swift run PowerMateAgent &` or run the built binary `./.build/debug/PowerMateAgent` and add it to **Login Items** if you want it to start when you log in.

To create a **signed, notarized app** (or installer) so others can use it without security warnings, see **[DISTRIBUTION.md](DISTRIBUTION.md)**. You’ll need an Apple Developer account; users will need to grant **Input Monitoring**, **Accessibility**, and (if using audio controls) **Audio Capture** once on first use.

## Use in your app

### 1. Add the package

In your app’s `Package.swift` (or Xcode: File → Add Package Dependencies):

```swift
dependencies: [
    .package(path: "/path/to/USB"),  // or your clone URL
],
targets: [
    .target(name: "YourApp", dependencies: ["PowerMateDriver"]),
]
```

### 2. Start the driver and map events

```swift
import PowerMateDriver

let driver = PowerMateDriver()

// Optional: use closures for simple mapping
driver.onRotate = { delta, rate in
    // delta > 0 = clockwise, delta < 0 = counter-clockwise
    // rate = deltas per second (nil on first report); use for speed-dependent mapping
    // e.g. scroll: CGEventCreateScrollWheelEvent(..., delta * lineHeight)
}
driver.onButtonDown = { /* e.g. simulate click or toggle */ }
driver.onButtonUp = { }

// Or use the delegate for all events
driver.delegate = self  // implement PowerMateDriverDelegate

driver.start()
// Keep run loop running (e.g. main thread in an app)
```

### 3. Event types

- `**PowerMateEvent.buttonDown**` / `**buttonUp**` — knob pressed / released  
- `**PowerMateEvent.buttonClick**` — short press and release (under `longPressThreshold`).  
- `**PowerMateEvent.buttonLongPress**` — press held at least `longPressThreshold`, then release.  
- `**PowerMateEvent.rotate(delta: Int, rate: Double?)**` — `delta` is the signed step count (e.g. +1, -2); `rate` is derived rotation speed in deltas per second (nil on first report).

Set `**longPressThreshold**` (default 0.4 seconds) to tune what counts as a long press. Use `**onClick**` and `**onLongPress**` (or the delegate) for separate handling.

Use `driver.isConnected` to see if the device is currently opened.

## LED (blue light in base)

The base has a blue LED you can use for feedback. Control it only when the device is connected (`isConnected == true`).

- `**setLEDBrightness(_ value: UInt8)**` — static brightness 0–255 (0 = off).
- `**setLEDPulseAsleep(_ on: Bool)**` / `**setLEDPulseAwake(_ on: Bool)**` — turn the built‑in pulse when “asleep” or “awake” on or off.
- `**setLEDPulseMode(table:op:arg:)**` — custom pulse: `table` 0–2, `op` 0 = slower, 1 = normal, 2 = faster, `arg` 1–255 for op 0/2.

LED commands use USB vendor control requests (same protocol as the Linux driver). They return `true` if the command was sent successfully. If the USB device is busy (e.g. another process has it open), LED calls may fail.

## Mapping to system actions

- **Scrolling**: In `onRotate`, create a scroll wheel `CGEvent` (e.g. `CGEventCreateScrollWheelEvent`) and post it, or feed the delta into your own scroll logic.  
- **Click**: In `onButtonDown` / `onButtonUp`, create and post a mouse click `CGEvent`, or call your own click handler.  
- **Media / other**: Map `onRotate` and `onButtonDown` to whatever you need (e.g. volume, key equivalents).

Posting events may require **Input Monitoring** (or **Accessibility**) in **System Settings → Privacy & Security** for your app.

## If the device doesn’t respond

1. **Unplug and replug** the PowerMate, then run your app again.
2. **Quit other software** that might be using the PowerMate (e.g. old PowerMate apps).
3. The driver uses `kIOHIDOptionsTypeSeizeDevice` so it takes exclusive access; only one process can use it at a time.

## Requirements

- macOS 13+  
- Swift 5.9+

## References

- [Linux PowerMate driver](https://gitlab.eclipse.org/eclipse/oniro-core/linux/-/blob/master/drivers/input/misc/powermate.c) (report format: byte 0 = button, byte 1 = rotation)  
- [Resurrecting the Griffin PowerMate on Linux](https://www.gilesorr.com/blog/powermate-on-linux.html)  
- Apple IOKit HID: `IOHIDManager`, `IOHIDDeviceOpen`, `IOHIDDeviceRegisterInputReportCallback`

### Versions

#### 1.0.3

Added audio cue for when mode changes.
Icon now has blue ring when in Audio Mode.
Audio Mode is now called... Audio mode.

#### 1.0.2

Added LED VU meter (tracks system audio amplitude via `AudioHardwareCreateProcessTap`), Fn-key mode flip, long-press toggle for audio/scroll mode, Audio Capture permission handling, blue menu bar icon when audio mode is active, and custom sound file support. Updated app identifier string.

#### 1.0.1

Added audio controls (volume + mute), settings persistence, and accessibility permission check. Also made scrolling smoother.

#### 1.0.0

Initial release. Includes scrolling and clicking, with optional double-click or right-click for long presses.