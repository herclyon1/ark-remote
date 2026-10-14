import XCTest

/// Regression 0108 #18. Defect guarded: the deployment target falls behind the newest SDK (an iOS 17 target was found on
/// 10-07), or the Xcode project sets a target that silently overrides the xcconfig. The rule: the deployment target is
/// the newest iOS / macOS SDK on this Mac, in Package.swift and in Darwin/ArkRemote.xcconfig, with no target of its own
/// in the Xcode project (it would win over the xcconfig). The same rule as ark-release.sh's gate (remote-ref/
/// tools/ark-release.sh:16-20, which compares major.minor), here so it also runs with every `swift test`.
final class DeploymentTargetTests: XCTestCase {
    /// `xcrun --sdk <sdk> --show-sdk-version`, cut to major.minor.
    static func sdkVersion(_ sdk: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--sdk", sdk, "--show-sdk-version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let v = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !v.isEmpty else { throw XCTSkip("xcrun has no \(sdk) SDK") }
        return v.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// The deployment targets that are not `want`, as "where: found".
    static func stale(package: String, xcconfig: [String], pbxproj: String, ios: String, macos: String) -> [String] {
        var out: [String] = []
        if !package.contains(".iOS(\"\(ios)\")") { out.append("Package.swift iOS") }
        if !package.contains(".macOS(\"\(macos)\")") { out.append("Package.swift macOS") }
        if !xcconfig.contains("IPHONEOS_DEPLOYMENT_TARGET = \(ios)") { out.append("xcconfig IPHONEOS_DEPLOYMENT_TARGET") }
        if !xcconfig.contains("MACOSX_DEPLOYMENT_TARGET = \(macos)") { out.append("xcconfig MACOSX_DEPLOYMENT_TARGET") }
        if pbxproj.contains("DEPLOYMENT_TARGET") { out.append("project.pbxproj sets a target of its own") }
        return out
    }

    func testTargetsAreTheNewestSDK() throws {
        let ios = try Self.sdkVersion("iphoneos"), macos = try Self.sdkVersion("macosx")
        let found = Self.stale(package: try RepoFiles.text("Package.swift"),
                               xcconfig: try RepoFiles.lines("Darwin/ArkRemote.xcconfig").map(RepoFiles.code)
                                   .map { $0.trimmingCharacters(in: .whitespaces) },
                               pbxproj: try RepoFiles.text("Darwin/ArkRemote.xcodeproj/project.pbxproj"),
                               ios: ios, macos: macos)
        XCTAssertEqual(found, [], "deployment targets other than iOS \(ios) / macOS \(macos)")
    }

    func testTheCheckCatchesIOS17() {
        XCTAssertEqual(Self.stale(package: "platforms: [.iOS(\"17.0\"), .macOS(\"27.0\")]",
                                  xcconfig: ["IPHONEOS_DEPLOYMENT_TARGET = 17.0", "MACOSX_DEPLOYMENT_TARGET = 27.0"],
                                  pbxproj: "", ios: "27.0", macos: "27.0"),
                       ["Package.swift iOS", "xcconfig IPHONEOS_DEPLOYMENT_TARGET"])
    }
}
