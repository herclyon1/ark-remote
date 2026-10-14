import XCTest

/// Regression 0108 #3. Defect guarded: the name under the icon is wrong. The App's name is 「遥控」 on both phones (owner
/// decision G3). On 10-08 the iOS line in ArkRemote.xcconfig was commented out, so iOS showed the target name; on
/// Android a manifest label or a values-* strings.xml can override app_name.
/// Read from the build settings that make the installed name: the xcconfig's generated Info.plist key on iOS (with no
/// InfoPlist.xcstrings translation over it), strings.xml app_name and every android:label in the manifest on Android.
final class AppNameTests: XCTestCase {
    static let name = "遥控"

    /// The value of the last uncommented `key = value` line of an xcconfig, nil when there is none.
    static func xcconfigValue(_ key: String, in lines: [String]) -> String? {
        lines.compactMap { line -> String? in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//") else { return nil }
            let parts = code.components(separatedBy: "=")
            guard parts.count >= 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { return nil }
            return parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
        }.last
    }

    func testIOSDisplayName() throws {
        let lines = try RepoFiles.lines("Darwin/ArkRemote.xcconfig")
        XCTAssertEqual(Self.xcconfigValue("INFOPLIST_KEY_CFBundleDisplayName", in: lines), Self.name)
        // a translation of CFBundleDisplayName / CFBundleName in InfoPlist.xcstrings would replace it on the phone
        let strings = try RepoFiles.text("Darwin/InfoPlist.xcstrings")
        XCTAssertFalse(strings.contains("CFBundleDisplayName"), "InfoPlist.xcstrings translates the display name")
        XCTAssertFalse(strings.contains("\"CFBundleName\""), "InfoPlist.xcstrings translates the bundle name")
        let plist = try RepoFiles.text("Darwin/Info.plist")
        XCTAssertFalse(plist.contains("CFBundleDisplayName"), "Info.plist sets its own display name")
    }

    func testAndroidLauncherLabel() throws {
        let strings = try RepoFiles.text("Android/app/src/main/res/values/strings.xml")
        XCTAssertTrue(strings.contains("<string name=\"app_name\">\(Self.name)</string>"), "strings.xml app_name is not \(Self.name)")
        let manifest = try RepoFiles.text("Android/app/src/main/AndroidManifest.xml")
        let labels = manifest.components(separatedBy: "android:label=\"").dropFirst()
            .map { String($0.prefix { $0 != "\"" }) }
        XCTAssertFalse(labels.isEmpty, "the manifest has no android:label")
        XCTAssertEqual(Set(labels), ["@string/app_name"], "an activity or the application has a label of its own")
        // no other resource folder (values-zh, values-en …) giving app_name another value
        let res = RepoFiles.url("Android/app/src/main/res")
        let others = try FileManager.default.contentsOfDirectory(atPath: res.path).filter { $0.hasPrefix("values-") }
        for dir in others {
            let other = try? String(contentsOf: res.appendingPathComponent(dir).appendingPathComponent("strings.xml"), encoding: .utf8)
            if let other, other.contains("name=\"app_name\"") {
                XCTAssertTrue(other.contains("<string name=\"app_name\">\(Self.name)</string>"), "\(dir)/strings.xml renames the App")
            }
        }
    }

    /// The xcconfig reader skips the commented line the 10-08 audit found (xcconfig:18 `//INFOPLIST_KEY_…`).
    func testReaderSkipsACommentedLine() {
        XCTAssertNil(Self.xcconfigValue("INFOPLIST_KEY_CFBundleDisplayName", in: ["//INFOPLIST_KEY_CFBundleDisplayName = 遥控"]))
        XCTAssertEqual(Self.xcconfigValue("INFOPLIST_KEY_CFBundleDisplayName", in: ["INFOPLIST_KEY_CFBundleDisplayName = 遥控"]), "遥控")
    }
}
