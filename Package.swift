// swift-tools-version:5.9
import PackageDescription

// AlwaysOnCore is platform-neutral (Foundation + POSIX) so its logic is unit-tested
// on macOS and on Linux CI. Everything that touches IOKit, AppKit, Network.framework
// or SwiftUI lives in AlwaysOnPlatform and the executables, which only build on macOS.

var targets: [Target] = [
    .target(name: "AlwaysOnCore"),
    .target(name: "AlwaysOnPlatform", dependencies: ["AlwaysOnCore"]),
    .testTarget(name: "AlwaysOnCoreTests", dependencies: ["AlwaysOnCore"]),
]

var products: [Product] = [
    .library(name: "AlwaysOnCore", targets: ["AlwaysOnCore"]),
]

#if os(macOS)
targets += [
    .executableTarget(
        name: "alwaysond",
        dependencies: ["AlwaysOnCore", "AlwaysOnPlatform"]
    ),
    .executableTarget(
        name: "alwaysonhelper",
        dependencies: ["AlwaysOnCore", "AlwaysOnPlatform"]
    ),
    .executableTarget(
        name: "MacAlwaysOn",
        dependencies: ["AlwaysOnCore", "AlwaysOnPlatform"]
    ),
]
products += [
    .executable(name: "alwaysond", targets: ["alwaysond"]),
    .executable(name: "alwaysonhelper", targets: ["alwaysonhelper"]),
    .executable(name: "MacAlwaysOn", targets: ["MacAlwaysOn"]),
]
#endif

let package = Package(
    name: "MacAlwaysOn",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
