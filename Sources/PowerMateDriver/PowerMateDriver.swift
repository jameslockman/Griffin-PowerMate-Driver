//
//  PowerMateDriver.swift
//  PowerMateDriver
//
//  macOS driver for Griffin PowerMate (VID 0x077d, PID 0x0410).
//  Reads 6-byte HID reports: byte 0 = button (0/1), byte 1 = signed rotation delta.
//

import Foundation
import IOKit
import IOKit.hid
import CPowerMateLED

// MARK: - Constants (from Linux powermate.c and HID docs)

private let kPowerMateVendorID: Int = 0x077d   // Griffin Technology
private let kPowerMateProductID: Int = 0x0410  // PowerMate
private let kPowerMateReportLength: Int = 6    // 6-byte input report

// MARK: - Event types

/// Rotation rate is derived from report timing (deltas per second); device only reports delta per poll.
public enum PowerMateEvent {
    case buttonDown
    case buttonUp
    /// Short press and release (under longPressThreshold).
    case buttonClick
    /// Press held for at least longPressThreshold, then release.
    case buttonLongPress
    case rotate(delta: Int, rate: Double?)  // delta: + = clockwise, - = counter-clockwise; rate: deltas per second (nil on first report)
}

// MARK: - Delegate

public protocol PowerMateDriverDelegate: AnyObject {
    func powerMate(_ driver: PowerMateDriver, didReceive event: PowerMateEvent)
}

// MARK: - Driver

public final class PowerMateDriver {

    public weak var delegate: PowerMateDriverDelegate?

    /// Optional closures for mapping events (set these or use delegate).
    public var onButtonDown: (() -> Void)?
    public var onButtonUp: (() -> Void)?
    /// Fired on release after a short press (duration < longPressThreshold).
    public var onClick: (() -> Void)?
    /// Fired on release after a long press (duration >= longPressThreshold).
    public var onLongPress: (() -> Void)?
    /// Hold duration in seconds that separates click from long press. Default 0.4.
    public var longPressThreshold: TimeInterval = 0.4
    /// delta: + = clockwise, - = counter-clockwise; rate: approximate deltas per second (nil on first report).
    public var onRotate: ((Int, Double?) -> Void)?

    /// Called with every raw report from the device (6 bytes). Use for debugging or custom parsing.
    public var onRawReport: (([UInt8]) -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var lastButtonState: Int = 0
    private var lastButtonDownTime: CFAbsoluteTime?
    private var lastReportTime: CFAbsoluteTime = 0
    private var deviceLocationID: UInt64?
    private let queue = DispatchQueue(label: "com.powermate.driver", qos: .userInteractive)

    public init() {}

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Start matching and opening the PowerMate. Call from main thread or before run loop.
    public func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    /// Stop the driver and release the device.
    public func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    /// Whether the device is currently opened and receiving events.
    public private(set) var isConnected: Bool = false

    // MARK: - LED (blue LED in base; uses USB vendor control requests)

    /// Set static LED brightness (0–255). Call after device is connected. Returns true if the command was sent successfully.
    public func setLEDBrightness(_ value: UInt8) -> Bool {
        guard let loc = deviceLocationID else { return false }
        return PowerMateLEDSetBrightness(UInt32(kPowerMateVendorID), UInt32(kPowerMateProductID), loc, value) == 0
    }

    /// Turn pulse when asleep on (true) or off (false).
    public func setLEDPulseAsleep(_ on: Bool) -> Bool {
        guard let loc = deviceLocationID else { return false }
        return PowerMateLEDSetPulseAsleep(UInt32(kPowerMateVendorID), UInt32(kPowerMateProductID), loc, on ? 1 : 0) == 0
    }

    /// Turn pulse when awake on (true) or off (false).
    public func setLEDPulseAwake(_ on: Bool) -> Bool {
        guard let loc = deviceLocationID else { return false }
        return PowerMateLEDSetPulseAwake(UInt32(kPowerMateVendorID), UInt32(kPowerMateProductID), loc, on ? 1 : 0) == 0
    }

    /// Set pulse mode: table 0–2, op 0=slower 1=normal 2=faster, arg 1–255 for op 0/2.
    public func setLEDPulseMode(table: UInt8, op: UInt8, arg: UInt8) -> Bool {
        guard let loc = deviceLocationID else { return false }
        return PowerMateLEDSetPulseMode(UInt32(kPowerMateVendorID), UInt32(kPowerMateProductID), loc, table, op, arg) == 0
    }

    // MARK: - Private

    private func startOnQueue() {
        guard manager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: kPowerMateVendorID,
            kIOHIDProductIDKey as String: kPowerMateProductID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, sender, device in
            guard let context = context else { return }
            let driver = Unmanaged<PowerMateDriver>.fromOpaque(context).takeUnretainedValue()
            driver.deviceAdded(device)
        }, selfPtr)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, result, sender, device in
            guard let context = context else { return }
            let driver = Unmanaged<PowerMateDriver>.fromOpaque(context).takeUnretainedValue()
            driver.deviceRemoved(device)
        }, selfPtr)

        if IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
            NSLog("PowerMateDriver: IOHIDManagerOpen failed (device may be in use)")
            return
        }

        NSLog("PowerMateDriver: Manager opened, matching VID=0x%04x PID=0x%04x. Waiting for device...", kPowerMateVendorID, kPowerMateProductID)

        // Enumerate already-connected devices (matching callback may not fire for them on all macOS versions)
        if let deviceSet = IOHIDManagerCopyDevices(manager), let devices = (deviceSet as NSSet).allObjects as? [IOHIDDevice] {
            for d in devices {
                deviceAdded(d)
                if self.device != nil { break }
            }
        }
    }

    private func stopOnQueue() {
        deviceRemoved(nil)
        if let manager = manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            self.manager = nil
        }
        if let buf = reportBuffer {
            buf.deallocate()
            reportBuffer = nil
        }
    }

    private func deviceAdded(_ deviceRef: IOHIDDevice?) {
        let dev = deviceRef ?? self.device
        guard let d = dev, self.device == nil else { return }

        NSLog("PowerMateDriver: Device matched, attempting to open...")

        // Open with seize so we get exclusive access and input reports (macOS won't consume the device)
        let openResult = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if openResult != kIOReturnSuccess {
            NSLog("PowerMateDriver: IOHIDDeviceOpen failed with result %d (try unplugging and replugging, or close other apps using the device)", openResult)
            return
        }

        NSLog("PowerMateDriver: Device opened successfully, registering for input reports (%d bytes)...", kPowerMateReportLength)

        if let locNum = IOHIDDeviceGetProperty(d, kIOHIDLocationIDKey as CFString) as? NSNumber {
            self.deviceLocationID = locNum.uint64Value
        } else {
            self.deviceLocationID = nil
        }

        self.device = d
        reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: kPowerMateReportLength)
        reportBuffer?.initialize(repeating: 0, count: kPowerMateReportLength)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            d,
            reportBuffer!,
            kPowerMateReportLength,
            { context, result, sender, type, reportID, report, reportLength in
                guard let context = context, reportLength >= 2 else { return }
                let driver = Unmanaged<PowerMateDriver>.fromOpaque(context).takeUnretainedValue()
                driver.handleReport(report, length: Int(reportLength))
            },
            selfPtr
        )

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = true
        }
    }

    private func deviceRemoved(_ deviceRef: IOHIDDevice?) {
        guard device != nil else { return }
        NSLog("PowerMateDriver: Device removed")
        if let d = device {
            IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        if let buf = reportBuffer {
            buf.deallocate()
            reportBuffer = nil
        }
        lastButtonState = 0
        lastButtonDownTime = nil
        lastReportTime = 0
        deviceLocationID = nil
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
        }
    }

    private func handleReport(_ report: UnsafeMutablePointer<UInt8>, length: Int) {
        let bytes = (0..<length).map { report[$0] }
        let now = CFAbsoluteTimeGetCurrent()

        let button = Int(report[0] & 0x01)
        let rotation = Int(Int8(bitPattern: report[1]))

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.onRawReport?(bytes)

            if button != self.lastButtonState {
                self.lastButtonState = button
                if button == 1 {
                    self.lastButtonDownTime = now
                    self.emit(.buttonDown)
                    self.onButtonDown?()
                } else {
                    let duration: TimeInterval
                    if let down = self.lastButtonDownTime {
                        duration = now - down
                    } else {
                        duration = 0
                    }
                    self.lastButtonDownTime = nil
                    if duration >= self.longPressThreshold {
                        self.emit(.buttonLongPress)
                        self.onLongPress?()
                    } else {
                        self.emit(.buttonClick)
                        self.onClick?()
                    }
                    self.emit(.buttonUp)
                    self.onButtonUp?()
                }
            }

            if rotation != 0 {
                let interval = self.lastReportTime > 0 ? now - self.lastReportTime : 0
                let rate: Double? = interval > 0 ? Double(abs(rotation)) / interval : nil
                self.emit(.rotate(delta: rotation, rate: rate))
                self.onRotate?(rotation, rate)
            }

            self.lastReportTime = now
        }
    }

    private func emit(_ event: PowerMateEvent) {
        delegate?.powerMate(self, didReceive: event)
    }
}
