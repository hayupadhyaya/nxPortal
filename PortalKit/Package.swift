// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PortalKit",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [
        .library(name: "PortalKit", targets: ["PortalKit"]),
        .library(name: "PortalHostCore", targets: ["PortalHostCore"]),
        .library(name: "PortalHostModel", targets: ["PortalHostModel"]),
        .library(name: "PortalClientCore", targets: ["PortalClientCore"]),
        .library(name: "PortalPlayer", targets: ["PortalPlayer"]),
        .library(name: "PortalTestSupport", targets: ["PortalTestSupport"]),
        .executable(name: "portal-fakegame", targets: ["portal-fakegame"]),
        .executable(name: "portal-fakeclient", targets: ["portal-fakeclient"]),
        .executable(name: "portal-hostd", targets: ["portal-hostd"]),
    ],
    targets: [
        .target(name: "PortalKit"),
        .target(name: "PortalHostCore", dependencies: ["PortalKit"]),
        // macOS only: its sources are `#if os(macOS)`, and PortalHostCore is not built for iOS / tvOS
        .target(name: "PortalHostModel", dependencies: ["PortalKit", .target(name: "PortalHostCore", condition: .when(platforms: [.macOS]))]),
        .target(name: "PortalClientCore", dependencies: ["PortalKit"]),
        .target(name: "PortalPlayer", dependencies: ["PortalKit", "PortalClientCore"]),
        .target(name: "PortalTestSupport", dependencies: ["PortalKit", "PortalHostCore", "PortalClientCore"]),
        .executableTarget(name: "portal-fakegame", dependencies: ["PortalKit", "PortalTestSupport"]),
        .executableTarget(name: "portal-fakeclient", dependencies: ["PortalKit", "PortalClientCore", "PortalPlayer", "PortalTestSupport"]),
        .executableTarget(name: "portal-hostd", dependencies: ["PortalKit", "PortalHostCore", "PortalTestSupport"]),
        .testTarget(name: "PortalKitTests", dependencies: ["PortalKit"]),
        .testTarget(name: "PortalHostCoreTests", dependencies: ["PortalKit", "PortalHostCore", "PortalTestSupport"]),
        .testTarget(name: "PortalHostModelTests",
                    dependencies: ["PortalKit", "PortalHostCore", "PortalHostModel", "PortalClientCore", "PortalTestSupport"]),
        .testTarget(name: "PortalClientCoreTests", dependencies: ["PortalKit", "PortalClientCore", "PortalHostCore", "PortalTestSupport"]),
        .testTarget(name: "PortalPlayerTests", dependencies: ["PortalPlayer", "PortalHostCore", "PortalTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
