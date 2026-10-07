import XCTest

/// The App must not poll the relay (regression list 0108 item 12): 8cce660 removed a fallback that read the topic
/// every 5 s from a `while !Task.isCancelled { pollTopic … sleep }` loop. A repeating loop may redraw from what is
/// already known or renew the watch, but must not read the mailbox; reads happen once (on open, on a tap).
final class NoPollingTests: XCTestCase {
    static let reads = ["pollTopic(", "readMessages(", "httpFetch(", "probeHb(", "poll=1"]

    /// Mailbox reads inside a `while` / `repeat` loop body (brace-matched, comments ignored), as "line read".
    static func loopReads(_ lines: [String]) -> [String] {
        var hits: [String] = []
        for (i, line) in lines.enumerated() {
            let code = line.components(separatedBy: "//")[0]
            guard code.range(of: #"\b(while|repeat)\b"#, options: .regularExpression) != nil, code.contains("{") else { continue }
            var depth = 0, j = i
            repeat {
                let body = lines[j].components(separatedBy: "//")[0]
                depth += body.filter { $0 == "{" }.count - body.filter { $0 == "}" }.count
                if let read = reads.first(where: { body.contains($0) }) { hits.append("\(j + 1) \(read)") }
                j += 1
            } while depth > 0 && j < lines.count
        }
        return hits
    }

    /// Every Swift file under Sources/ has no mailbox read inside a loop.
    func testNoMailboxReadInsideALoop() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 10, "Sources/ not found at \(sources.path)")
        var hits: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            hits += Self.loopReads(lines).map { "\(file.lastPathComponent):\($0)" }
        }
        XCTAssertEqual(hits, [], "a loop reads the mailbox (polling)")
    }

    /// The scan finds the loop 8cce660 removed (and not a one-shot read next to a redraw loop), so a pass above means something.
    func testTheScanCatchesTheRemovedLoop() {
        let removed = """
            private func pollLoop() async {
                while !Task.isCancelled {
                    if let events = try? await Relay.pollTopic(topics, since: from) { deliver(events) }
                    try? await Task.sleep(nanoseconds: Self.pollEvery)
                }
            }
            """.components(separatedBy: "\n")
        XCTAssertEqual(Self.loopReads(removed), ["3 pollTopic("])
        let fine = """
            func probe() async { _ = try? await Relay.pollTopic(t, since: "90s") }   // one-shot
            func start() {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self?.updateLive()
                }
            }
            """.components(separatedBy: "\n")
        XCTAssertEqual(Self.loopReads(fine), [])
    }
}
