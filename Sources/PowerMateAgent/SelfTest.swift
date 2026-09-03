import Foundation
import AppKit
import ApplicationServices

// MARK: - Headless self-tests
//
// Two verbs that exercise the hold-key primitives without a PowerMate attached and without
// starting the agent proper. They run before the driver seizes the device or the status item
// is built, so they work while the normally-installed agent is quit but everything else about
// the machine (the stored settings blob, the Accessibility grant) is untouched.
//
//   PowerMateAgent --selftest-hold <seconds>   press the configured hold key, wait, release
//   PowerMateAgent --selftest-decode           decode the live settings blob and report holdKey
//
// Both print what they did and exit 0; anything else returns and startup continues as usual.

/// Runs a `--selftest-*` verb if one was passed and exits the process. Returns normally when
/// the agent was launched without one.
func runSelfTestIfRequested() {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let verb = args.first else { return }
    switch verb {
    case "--selftest-hold":
        runHoldSelfTest(seconds: args.dropFirst().first.flatMap(Double.init) ?? 5)
    case "--selftest-decode":
        runDecodeSelfTest()
    default:
        return
    }
    exit(0)
}

private func runHoldSelfTest(seconds: Double) {
    // The global default, not currentSettings(): a self-test run from a terminal would
    // otherwise resolve against whatever app happens to be frontmost, which is not what the
    // operator configured and makes the measurement non-reproducible.
    guard let binding = defaultSettings.holdKey else {
        print("selftest-hold: no hold key configured (defaultAppSettings.holdKey is nil) — nothing to press.")
        exit(1)
    }
    let isModifier = modifierFlag(forKeyCode: binding.keyCode) != nil
    print("selftest-hold: AXIsProcessTrusted=\(AXIsProcessTrusted())")
    print("selftest-hold: key=\(binding.label) keyCode=0x\(String(binding.keyCode, radix: 16, uppercase: true)) "
          + "flags=0x\(String(binding.modifierFlags, radix: 16, uppercase: true)) "
          + "eventType=\(isModifier ? ".flagsChanged" : ".keyDown/.keyUp")")
    print("selftest-hold: DOWN at \(Date())")
    postKeyDown(binding.keyCode, flags: binding.flags)
    Thread.sleep(forTimeInterval: seconds)
    postKeyUp(binding.keyCode, flags: binding.flags)
    print("selftest-hold: UP at \(Date()) (held \(seconds)s)")
}

private func runDecodeSelfTest() {
    // Reads the same UserDefaults key AppOverrides.swift reads, and decodes it with the same
    // AppSettings.init(from:). The point is to prove that a blob written before holdKey existed
    // still decodes — as itself, not as a silently discarded default instance.
    guard let data = defaults.data(forKey: "defaultAppSettings") else {
        print("selftest-decode: no stored defaultAppSettings blob (fresh install) — nothing to check.")
        exit(1)
    }
    print("selftest-decode: stored blob = \(data.count) bytes")
    print("selftest-decode: contains \"holdKey\" key = \(String(data: data, encoding: .utf8)?.contains("holdKey") ?? false)")
    do {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        print("selftest-decode: decoded OK")
        print("selftest-decode:   holdKey           = \(decoded.holdKey.map { "\($0.label) (0x\(String($0.keyCode, radix: 16, uppercase: true)))" } ?? "nil")")
        // Fields that prove the rest of the blob survived rather than falling back wholesale.
        print("selftest-decode:   mode              = \(decoded.mode.rawValue)")
        print("selftest-decode:   clickAction       = \(decoded.clickAction)")
        print("selftest-decode:   longPressAction   = \(decoded.longPressAction)")
        print("selftest-decode:   keypressBindings  = \(decoded.keypressBindings.count) directions")
    } catch {
        print("selftest-decode: FAILED — \(error)")
        exit(1)
    }
}
