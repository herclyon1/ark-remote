// swift-tools-version: 6.1
// This is a Skip (https://skip.dev) package.
import PackageDescription

let package = Package(
    name: "ark-remote",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS("27.1"), .macOS("27.0")],
    products: [
        .library(name: "ArkRemote", type: .dynamic, targets: ["ArkRemote"]),
    ],
    dependencies: [
        .package(url: "https://github.com/skiptools/skip.git", from: "1.9.12"),
        .package(url: "https://github.com/skiptools/skip-fuse-ui.git", from: "1.0.0"),
        // skip-ui 1.61.0 with one patch to List's section gap on Android (Vendor/skip-ui/VENDORED.md); as a root path
        // dependency with skip-fuse-ui's identity for it, it stands in for the remote skip-ui
        .package(path: "Vendor/skip-ui")
    ],
    targets: [
        .target(name: "ArkRemote", dependencies: [
            .product(name: "SkipFuseUI", package: "skip-fuse-ui")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        // Logic unit tests, run on the Mac (`swift test`); no skipstone plugin, so not built for Android
        .testTarget(name: "ArkRemoteTests", dependencies: ["ArkRemote"]),
    ]
)
