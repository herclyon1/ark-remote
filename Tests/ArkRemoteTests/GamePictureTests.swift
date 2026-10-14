import XCTest

/// Regression 0108 #21. Defect guarded: the game pictures disappear (the 10-07 rewrite removed them), or code names an
/// image whose imageset or files are missing, which draws a blank picture. On this base the pictures are
/// Module.xcassets imagesets: the game icons (tab-*), the stamina tiles' resource icons (res-*) and the 鸣潮 echo sets
/// (echo-set-*). Every picture the code names must be an imageset whose files are there, and each game's icon and
/// resource icon must still be named somewhere in Sources/ (where the tab icons sit is TabIconTests').
final class GamePictureTests: XCTestCase {
    static let assets = "Sources/ArkRemote/Resources/Module.xcassets"
    /// The pictures of the three games: their icons and their stamina resources.
    static let gamePictures: Set<String> = ["tab-arknights", "tab-endfield", "tab-wuwa", "res-ak", "res-ef", "res-ww"]

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

    func testTheGamePicturesAreStillUsed() throws {
        var named = Set<String>()
        for (_, lines) in try RepoFiles.swiftSources() { named.formUnion(Self.pictureNames(lines)) }
        XCTAssertEqual(Self.gamePictures.subtracting(named), [], "no file under Sources/ shows these pictures any more")
    }

    func testTheCheckSeesAMissingImageset() {
        XCTAssertEqual(Self.missingFiles("tab-nothing"), ["tab-nothing.imageset/Contents.json"])
        XCTAssertEqual(Self.pictureNames(["Image(\"tab-x\", bundle: b) // \"res-y\""]), ["tab-x"])
    }
}
