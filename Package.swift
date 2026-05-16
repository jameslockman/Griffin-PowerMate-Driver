// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PowerMateUSB",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "PowerMateDriver", targets: ["PowerMateDriver"]),
        .executable(name: "PowerMateDemo", targets: ["PowerMateDemo"]),
        .executable(name: "PowerMateAgent", targets: ["PowerMateAgent"]),
    ],
    targets: [
        .target(
            name: "CPowerMateLED",
            path: "Sources/CPowerMateLED",
            publicHeadersPath: ".",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "PowerMateDriver",
            dependencies: ["CPowerMateLED"],
            path: "Sources/PowerMateDriver"
        ),
        .executableTarget(
            name: "PowerMateDemo",
            dependencies: ["PowerMateDriver"],
            path: "Sources/PowerMateDemo"
        ),
        .executableTarget(
            name: "PowerMateAgent",
            dependencies: ["PowerMateDriver"],
            path: "Sources/PowerMateAgent",
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("AppKit"), .linkedFramework("ApplicationServices"), .linkedFramework("CoreAudio")]
        ),
    ]
)
