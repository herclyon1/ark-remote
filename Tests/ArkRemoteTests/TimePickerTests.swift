import XCTest

/// Regression 0108 #17. Defect guarded: 刷到几点 and 改成刷到几点 go back to typed HH:MM text, which takes invalid input
/// such as 25:70 or a missing colon; the value is mailed to the PC (StatusPage startEchoFarm). A time picker cannot
/// produce an invalid time. d390f0c replaced the typed fields (`TextField("08:30", text: $echoUntil)`,
/// `TextField(ef.until, text: $echoNewUntil)`) with the system time picker. Turning the wheels is the replay's job
/// (status.until.2330 / 0005, farm.pick); this check finds each picker by the value it writes, not by its title: a
/// DatePicker call that binds the value and shows hours and minutes, and no TextField writing either value.
final class TimePickerTests: XCTestCase {
    static let times = [("刷到几点", "$echoUntil"), ("改成刷到几点", "$echoNewUntil")]

    /// The argument text of every `DatePicker(…)` call, matched across lines by its parentheses (comments dropped).
    static func datePickerCalls(_ lines: [String]) -> [String] {
        let code = Array(lines.map(RepoFiles.code).joined(separator: "\n"))
        let mark = Array("DatePicker(")
        var out: [String] = []
        var i = 0
        while i + mark.count <= code.count {
            guard Array(code[i..<(i + mark.count)]) == mark else { i += 1; continue }
            var depth = 0, j = i + mark.count - 1
            repeat {
                if code[j] == "(" { depth += 1 } else if code[j] == ")" { depth -= 1 }
                j += 1
            } while depth > 0 && j < code.count
            out.append(String(code[(i + mark.count)..<(j - 1)]))
            i = j
        }
        return out
    }

    /// Whether `text` names `binding` as a whole word (`$echoUntil` is not `$echoUntilX`).
    static func names(_ text: String, _ binding: String) -> Bool {
        text.range(of: NSRegularExpression.escapedPattern(for: binding) + #"\b"#, options: .regularExpression) != nil
    }

    /// Problems found: a value no DatePicker with `.hourAndMinute` binds, or a TextField bound to one of the two values.
    static func problems(_ lines: [String]) -> [String] {
        let calls = datePickerCalls(lines)
        let code = lines.map(RepoFiles.code)
        var out: [String] = []
        for (title, binding) in times {
            if !calls.contains(where: { names($0, binding) && $0.contains(".hourAndMinute") }) { out.append("\(title) is not a time picker") }
            if code.contains(where: { $0.contains("TextField(") && names($0, "text: \(binding)") }) { out.append("\(title) is typed") }
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

    /// A picker split over lines, with any title, counts; one without `.hourAndMinute` (a date picker) does not.
    func testTheScanReadsTheCallAcrossLines() {
        let split = ["DatePicker(\"收工\",", "           selection: hhmmBinding($echoUntil, else: \"08:30\"),",
                     "           displayedComponents: .hourAndMinute)",
                     "DatePicker(\"改\", selection: hhmmBinding($echoNewUntil, else: ef.until), displayedComponents: .date)"]
        XCTAssertEqual(Self.problems(split), ["改成刷到几点 is not a time picker"])
    }
}
