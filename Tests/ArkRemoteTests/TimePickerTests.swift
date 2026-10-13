import XCTest

/// Regression 0108 #17: 10-05 20:12 「「刷到几点」这个要填冒号不是有点奇怪吗？」 d390f0c replaced the typed HH:MM fields
/// (`TextField("08:30", text: $echoUntil)`, `TextField(ef.until, text: $echoNewUntil)`) with the system time picker.
/// Turning the wheels is the replay's job (status.until.2330 / 0005, farm.pick); this check stops the fields from going
/// back to text: both times are DatePickers showing hours and minutes, and no TextField writes either value.
final class TimePickerTests: XCTestCase {
    static let times = [("刷到几点", "$echoUntil"), ("改成刷到几点", "$echoNewUntil")]

    /// Problems found: a time that is not a `DatePicker("<title>", … displayedComponents: .hourAndMinute)`, or a
    /// TextField bound to one of the two values.
    static func problems(_ lines: [String]) -> [String] {
        let code = lines.map(RepoFiles.code)
        var out: [String] = []
        for (title, binding) in times {
            let picker = code.contains {
                $0.contains("DatePicker(\"\(title)\"") && $0.contains(binding) && $0.contains("displayedComponents: .hourAndMinute")
            }
            if !picker { out.append("\(title) is not a time picker") }
            if code.contains(where: { $0.contains("TextField(") && $0.contains("text: \(binding)") }) {
                out.append("\(title) is typed")
            }
        }
        return out
    }

    func testTimesArePicked() throws {
        XCTAssertEqual(Self.problems(try RepoFiles.lines("Sources/ArkRemote/Pages/Status/StatusPage.swift")), [])
    }

    func testTheScanCatchesTheTypedFields() {
        let old = ["                    TextField(ef.until, text: $echoNewUntil)",
                   "                    TextField(\"08:30\", text: $echoUntil)"]
        XCTAssertEqual(Self.problems(old), ["刷到几点 is not a time picker", "刷到几点 is typed",
                                             "改成刷到几点 is not a time picker", "改成刷到几点 is typed"])
    }
}
