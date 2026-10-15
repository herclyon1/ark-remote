import XCTest

/// Regression 0108 #3 (the icon half). Defect guarded: the App's icon falls back to an old one. Since 0.5.2 both phones
/// draw the same artwork, SF Symbols gamecontroller.fill with the two arcs of wifi, white on system blue
/// (BOARD/app-work/icon-1015/sf2/final/SHIP.md): iOS from the Icon Composer file Darwin/AppIcon.icon, which actool only
/// compiles while the project lists it in the app's Resources phase; Android from the adaptive icon's vector layers.
/// If the .icon leaves the project, iOS silently takes the asset catalog's AppIcon instead; if a drawable is put back,
/// Android shows the Material sports_esports controller of 0.3.x again.
final class AppIconTests: XCTestCase {
    func testIOSBuildsTheIconComposerFile() throws {
        let pbx = try RepoFiles.text("Darwin/ArkRemote.xcodeproj/project.pbxproj")
        XCTAssertTrue(pbx.contains("/* AppIcon.icon in Resources */ = {isa = PBXBuildFile;"), "AppIcon.icon is not a build file")
        XCTAssertTrue(pbx.contains("lastKnownFileType = folder.iconcomposer.icon; path = AppIcon.icon;"), "no AppIcon.icon file reference")
        XCTAssertEqual(pbx.components(separatedBy: "/* AppIcon.icon in Resources */,").count - 1, 1, "AppIcon.icon not in the Resources phase")
        let icon = try JSONSerialization.jsonObject(with: Data(contentsOf: RepoFiles.url("Darwin/AppIcon.icon/icon.json"))) as? [String: Any]
        XCTAssertNotNil(icon?["groups"], "icon.json has no layer groups")
        for layer in ["pad.svg", "signal.svg"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: RepoFiles.url("Darwin/AppIcon.icon/Assets/\(layer)").path), layer)
        }
        // the name the build setting asks actool for is the .icon's file name
        let xc = try RepoFiles.lines("Darwin/ArkRemote.xcconfig")
        XCTAssertEqual(AppNameTests.xcconfigValue("ASSETCATALOG_COMPILER_APPICON_NAME", in: xc), "AppIcon")
    }

    func testAndroidDrawsTheSameGlyph() throws {
        let fg = try RepoFiles.text("Android/app/src/main/res/drawable/ic_launcher_foreground.xml")
        let mono = try RepoFiles.text("Android/app/src/main/res/drawable/ic_launcher_monochrome.xml")
        let bg = try RepoFiles.text("Android/app/src/main/res/drawable/ic_launcher_background.xml")
        XCTAssertTrue(fg.contains("gamecontroller.fill"), "foreground is not the SF gamecontroller.fill artwork")
        XCTAssertTrue(mono.contains("gamecontroller.fill"), "monochrome is not the SF gamecontroller.fill artwork")
        XCTAssertFalse(fg.contains("sports_esports") || mono.contains("sports_esports"), "the Material controller is back")
        XCTAssertTrue(bg.contains("#0094FF") || bg.contains("#FF0094FF"), "background is not iOS's system-blue gradient")
        // HIG review 0.5.2: at full size the glyph's farthest white reached 86.4 % of the launcher circle's radius (Google
        // Camera 75.9 %); both layers scale it 0.85 about the centre, the same factor so the themed icon matches
        for (name, xml) in [("foreground", fg), ("monochrome", mono)] {
            for attr in ["android:pivotX=\"54\"", "android:pivotY=\"54\"", "android:scaleX=\"0.85\"", "android:scaleY=\"0.85\""] {
                XCTAssertTrue(xml.contains(attr), "\(name) glyph is not scaled 0.85 about the centre: \(attr) missing")
            }
            XCTAssertLessThan(xml.range(of: "<group")?.lowerBound ?? xml.endIndex, xml.range(of: "<path")?.lowerBound ?? xml.startIndex,
                              "\(name): the paths must be inside the scaling group")
        }
        let launcher = try RepoFiles.text("Android/app/src/main/res/mipmap-anydpi/ic_launcher.xml")
        for part in ["@drawable/ic_launcher_background", "@drawable/ic_launcher_foreground", "@drawable/ic_launcher_monochrome"] {
            XCTAssertTrue(launcher.contains(part), part)
        }
    }
}
