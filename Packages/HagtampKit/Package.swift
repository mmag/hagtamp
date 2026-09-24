// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HagtampKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkinKit", targets: ["SkinKit"]),
        .library(name: "SkinRenderer", targets: ["SkinRenderer"]),
        .executable(name: "skintool", targets: ["skintool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "SkinKit",
            dependencies: ["ZIPFoundation"],
            resources: [.copy("Resources/base-2.91.wsz")]
        ),
        .target(name: "SkinRenderer", dependencies: ["SkinKit"]),
        .executableTarget(name: "skintool", dependencies: ["SkinKit", "SkinRenderer"]),
        .testTarget(
            name: "SkinKitTests",
            dependencies: ["SkinKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SkinRendererTests",
            dependencies: ["SkinRenderer"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
