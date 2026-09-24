// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HagtampKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkinKit", targets: ["SkinKit"]),
        .library(name: "ClassicUI", targets: ["ClassicUI"]),
        .library(name: "PlayerCore", targets: ["PlayerCore"]),
        .library(name: "AudioCore", targets: ["AudioCore"]),
        .library(name: "NavidromeKit", targets: ["NavidromeKit"]),
        .library(name: "LibraryKit", targets: ["LibraryKit"]),
        .executable(name: "skintool", targets: ["skintool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/sbooth/SFBAudioEngine.git", from: "0.14.0"),
    ],
    targets: [
        .target(
            name: "SkinKit",
            dependencies: ["ZIPFoundation"],
            resources: [.copy("Resources/hagtamp-base.wsz")]
        ),
        .target(name: "ClassicUI", dependencies: ["SkinKit"]),
        .target(name: "PlayerCore"),
        .target(
            name: "StreamingInput",
            dependencies: [.product(name: "SFBAudioEngine", package: "SFBAudioEngine")]
        ),
        .target(
            name: "AudioCore",
            dependencies: ["PlayerCore", "StreamingInput", .product(name: "SFBAudioEngine", package: "SFBAudioEngine")]
        ),
        .target(name: "NavidromeKit", dependencies: ["PlayerCore", "StreamingInput"]),
        .target(
            name: "LibraryKit",
            dependencies: ["PlayerCore", .product(name: "SFBAudioEngine", package: "SFBAudioEngine")]
        ),
        .executableTarget(name: "skintool", dependencies: ["SkinKit", "ClassicUI"]),
        .testTarget(
            name: "SkinKitTests",
            dependencies: ["SkinKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ClassicUITests",
            dependencies: ["ClassicUI"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PlayerCoreTests", dependencies: ["PlayerCore"], resources: [.copy("Fixtures")]),
        .testTarget(
            name: "AudioCoreTests",
            dependencies: ["AudioCore", "StreamingInput", .product(name: "SFBAudioEngine", package: "SFBAudioEngine")],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "NavidromeKitTests", dependencies: ["NavidromeKit"], resources: [.copy("Fixtures")]),
        .testTarget(
            name: "LibraryKitTests",
            dependencies: ["LibraryKit", .product(name: "SFBAudioEngine", package: "SFBAudioEngine")]),
    ]
)
