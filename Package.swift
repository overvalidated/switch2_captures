// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwitchCaptures",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SwitchCaptures", targets: ["SwitchCaptures"])],
    targets: [
        .target(name: "SwitchUSB", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "CaptureTransfer", dependencies: ["SwitchUSB"]),
        .executableTarget(name: "SwitchCaptures", dependencies: ["CaptureTransfer"]),
        .testTarget(name: "CaptureTransferTests", dependencies: ["CaptureTransfer"])
    ]
)
