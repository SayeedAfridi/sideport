// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "finder-adb",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AdbKit", targets: ["AdbKit"]),
        .executable(name: "adbctl", targets: ["adbctl"]),
    ],
    targets: [
        .target(name: "AdbKit"),
        .executableTarget(name: "adbctl", dependencies: ["AdbKit"]),
    ]
)
