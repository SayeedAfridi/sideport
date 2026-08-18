// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "finder-adb",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AdbKit", targets: ["AdbKit"]),
        .library(name: "AdbFinderCore", targets: ["AdbFinderCore"]),
        .executable(name: "adbctl", targets: ["adbctl"]),
    ],
    targets: [
        .target(name: "AdbKit"),
        .target(name: "AdbFinderCore", dependencies: ["AdbKit"]),
        .executableTarget(name: "adbctl", dependencies: ["AdbKit"]),
        .testTarget(name: "AdbKitTests", dependencies: ["AdbKit"]),
        .testTarget(name: "AdbFinderCoreTests", dependencies: ["AdbFinderCore"]),
    ]
)
