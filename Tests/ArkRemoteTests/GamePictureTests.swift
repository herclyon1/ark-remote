import XCTest

/// Regression 0108 #21: the 10-07 01:04–01:18 rewrite lost the games' pictures (被指出.txt:80, :96). On this base the
/// pictures are Module.xcassets imagesets: the game tab icons (tab-*), the stamina tiles' resource icons (res-*), the
/// 月卡 rows' game icons (tab-*) and the 鸣潮 echo sets (echo-set-*). Every picture the code names must be an imageset
/// whose files are there, and the pages that show the games must still name them.
final class GamePictureTests: XCTestCase {
    static let assets = "Sources/ArkRemote/Resources/Module.xcassets"
    /// Where each game picture is used on this base (ContentView tab bar, 状态 stamina tiles, 月卡 rows).
    static let required: [(file: String, names: [String])] = [
        ("Sources/ArkRemote/ContentView.swift", ["tab-arknights", "tab-endfield", "tab-wuwa"]),
        ("Sources/ArkRemote/Pages/Status/StatusPage.swift", ["res-ak", "res-ef", "res-ww"]),
        ("Sources/ArkRemote/Pages/Status/MonthCardRows.swift", ["tab-arknights", "tab-endfield", "tab-wuwa"]),
    ]

    /// The picture names in string literals: "tab-…", "res-…", "echo-set-…".
    static func pictureNames(_ lines: [String]) -> Set<String> {
        let re = try! NSRegularExpression(pattern: #""((?:tab|res|echo-set)-[a-z0-9-]+)""#)
        var out = Set<String>()
        for line in lines.map(RepoFiles.code) {
            let ns = line as NSString
            for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                out.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        return out
    }

    /// The image files an imageset's Contents.json lists that are missing (or the reason it cannot be read).
    static func missingFiles(_ name: String) -> [String] {
        let dir = RepoFiles.url("\(assets)/\(name).imageset")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("Contents.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [[String: Any]] else { return ["\(name).imageset/Contents.json"] }
        let files = images.compactMap { $0["filename"] as? String }
        if files.isEmpty { return ["\(name).imageset has no image file"] }
        return files.filter { !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    func testEveryNamedPictureIsThere() throws {
        var named = Set<String>()
        for (_, lines) in try RepoFiles.swiftSources() { named.formUnion(Self.pictureNames(lines)) }
        XCTAssertTrue(named.isSuperset(of: ["tab-arknights", "res-ak", "echo-set-1"]), "the scan found \(named.sorted())")
        for name in named.sorted() {
            XCTAssertEqual(Self.missingFiles(name), [], "picture \(name)")
        }
    }

    func testTheGamePagesStillShowThem() throws {
        for (file, names) in Self.required {
            let found = Self.pictureNames(try RepoFiles.lines(file))
            for name in names { XCTAssertTrue(found.contains(name), "\(file) no longer shows \(name)") }
        }
    }

    func testTheCheckSeesAMissingImageset() {
        XCTAssertEqual(Self.missingFiles("tab-nothing"), ["tab-nothing.imageset/Contents.json"])
        XCTAssertEqual(Self.pictureNames(["Image(\"tab-x\", bundle: b) // \"res-y\""]), ["tab-x"])
    }
}
