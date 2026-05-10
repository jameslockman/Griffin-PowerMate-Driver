#!/usr/bin/env swift
//
//  PowerMateDemo — shows events from the Griffin PowerMate (button + rotation).
//  LED: throbs while turning the knob, full on while button held, dim when idle.
//  Run: swift run PowerMateDemo
//

import Foundation
import PowerMateDriver

let driver = PowerMateDriver()

// Coalesce rotation: accumulate deltas and print one line per burst
var rotationAccum = 0
var lastRotationRate: Double?
var rotationWorkItem: DispatchWorkItem?
let coalesceInterval: DispatchTimeInterval = .milliseconds(80)

func flushRotation() {
    let acc = rotationAccum
    rotationAccum = 0
    let rate = lastRotationRate
    lastRotationRate = nil
    if acc != 0 {
        let dir = acc > 0 ? "CW" : "CCW"
        let rateStr = rate.map { String(format: " @ %.0f/s", $0) } ?? ""
        print("[EVENT] Rotate \(dir) \(acc > 0 ? "+" : "")\(acc)\(rateStr)")
    }
}

// LED throb while user is turning the knob (smoothed so it’s not jumpy)
var isButtonDown = false
var lastRotationTime: CFTimeInterval = 0
var throbTimer: DispatchSourceTimer?
var smoothedThrobBrightness: Double = 80
let throbPeriod: CFTimeInterval = 1.5
let throbIdleTimeout: CFTimeInterval = 0.5
let throbTick: CFTimeInterval = 0.025   // 25 ms for smoother animation
let throbSmooth: Double = 0.22         // ease toward target (lower = smoother, slower response)

func startThrob() {
    lastRotationTime = CFAbsoluteTimeGetCurrent()
    guard throbTimer == nil else { return }
    throbTimer = DispatchSource.makeTimerSource(queue: .main)
    throbTimer?.schedule(deadline: .now(), repeating: throbTick)
    throbTimer?.setEventHandler { [weak driver] in
        guard let driver = driver, driver.isConnected else { return }
        if isButtonDown {
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastRotationTime > throbIdleTimeout {
            throbTimer?.cancel()
            throbTimer = nil
            _ = driver.setLEDBrightness(80)
            smoothedThrobBrightness = 80
            return
        }
        let t = now.truncatingRemainder(dividingBy: throbPeriod) / throbPeriod
        let target = 80 + 175 * (0.5 + 0.5 * sin(t * 2 * .pi))  // 80–255 for a brighter throb
        smoothedThrobBrightness += (target - smoothedThrobBrightness) * throbSmooth
        _ = driver.setLEDBrightness(UInt8(max(0, min(255, smoothedThrobBrightness.rounded()))))
    }
    throbTimer?.resume()
}

driver.onRotate = { delta, rate in
    rotationAccum += delta
    if let r = rate { lastRotationRate = r }
    startThrob()
    rotationWorkItem?.cancel()
    rotationWorkItem = DispatchWorkItem { flushRotation() }
    DispatchQueue.main.asyncAfter(deadline: .now() + coalesceInterval, execute: rotationWorkItem!)
}

driver.onButtonDown = {
    rotationWorkItem?.cancel()
    flushRotation()
    print("[EVENT] Button DOWN")
    isButtonDown = true
    _ = driver.setLEDBrightness(255)
}
driver.onButtonUp = {
    print("[EVENT] Button UP")
    isButtonDown = false
    if throbTimer != nil {
        lastRotationTime = CFAbsoluteTimeGetCurrent()
    } else {
        _ = driver.setLEDBrightness(80)
    }
}
driver.onClick = {
    print("[EVENT] Click (short press)")
}
driver.onLongPress = {
    print("[EVENT] Long press")
}

driver.start()

print("PowerMate demo — turn the knob (LED throbs), short press = click, long press = long press. Ctrl+C to exit.\n")

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    if driver.isConnected {
        _ = driver.setLEDBrightness(80)
    }
}

RunLoop.main.run()
