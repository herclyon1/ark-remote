import XCTest

/// Regression list 0108 item 12. Defect guarded: the App reads the relay mailbox or COS in a repeating loop. That drains
/// the battery and spends ntfy's daily quota, which is what made the machine look off (HTTP 429). 8cce660 removed a
/// fallback that read the topic every 5 s from a `while !Task.isCancelled { pollTopic … sleep }` loop. A repeating
/// loop (`while`, `repeat`, `for await`, a Timer closure) may redraw from what is already known, but must not read;
/// reads happen once (on open, on a tap). Two sites are allowed, each with its reason, in `allowed`.
final class NoPollingTests: XCTestCase {
    /// Mailbox / COS reads, and the wrappers that make them.
    static let reads = ["pollTopic(", "readMessages(", "httpFetch(", "probeHb(", "poll=1",
                        "latestState(", "cosState(", "readCosState(", "readCosHb(", "fetchHb(", "askWatch("]

    /// The loop reads that are allowed: (file name, trimmed line that is the read or opens the block holding it, why).
    static let allowed: [(file: String, line: String, reason: String)] = [
        ("Live.swift", "if !polled && nowMs() - t0 > 8000 {",
         "Live.ping's wait loop reads the mailbox and COS once per tap (polled turns true at once), not on every turn"),
        ("Live.swift", "if let self, self.foreground { self.askWatch() }",
         "Live.start's watch renewal: one watch every 8 minutes in the foreground, with at most three COS reads after it"),
    ]

    static let loopHead = try! NSRegularExpression(pattern: #"\b(while|repeat)\b|\bfor\s+(try\s+)?await\b|\bTimer\b"#)

    /// Reads inside a loop body (brace-matched, comments ignored) that `allowed` does not cover, as "line read".
    static func loopReads(_ lines: [String], file: String = "") -> [String] {
        let ok = Set(allowed.filter { $0.file == file }.map(\.line))
        var hits: [String] = []
        var seen = Set<Int>()
        for (i, line) in lines.enumerated() {
            let code = RepoFiles.code(line)
            guard loopHead.firstMatch(in: code, range: NSRange(location: 0, length: (code as NSString).length)) != nil,
                  code.contains("{") else { continue }
            var depth = 0, j = i
            var openers: [String] = []
            repeat {
                let body = RepoFiles.code(lines[j])
                let trimmed = body.trimmingCharacters(in: .whitespaces)
                if let read = reads.first(where: { body.contains($0) }), !seen.contains(j),
                   !ok.contains(trimmed), !openers.contains(where: ok.contains) {
                    hits.append("\(j + 1) \(read)")
                    seen.insert(j)
                }
                for ch in body {
                    if ch == "{" { depth += 1; openers.append(trimmed) } else if ch == "}" { depth -= 1; _ = openers.popLast() }
                }
                j += 1
            } while depth > 0 && j < lines.count
        }
        return hits
    }

    /// Every Swift file under Sources/ has no read inside a loop beyond the allowed ones.
    func testNoMailboxReadInsideALoop() throws {
        var hits: [String] = []
        for (path, lines) in try RepoFiles.swiftSources() {
            let name = (path as NSString).lastPathComponent
            hits += Self.loopReads(lines, file: name).map { "\(name):\($0)" }
        }
        XCTAssertEqual(hits, [], "a loop reads the mailbox or COS (polling)")
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

    /// A loop through a wrapper, a `for await` and a Timer are caught; the allowed sites only in their own file.
    func testTheScanCatchesWrappersAndOtherLoops() {
        XCTAssertEqual(Self.loopReads([
            "while !Task.isCancelled { _ = try? await relay.latestState(); try? await Task.sleep(nanoseconds: 5_000_000_000) }"]),
                       ["1 latestState("])
        XCTAssertEqual(Self.loopReads(["for await _ in ticks {", "    await live.readCosHb()", "}"]), ["2 readCosHb("])
        XCTAssertEqual(Self.loopReads(["Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in", "    Task { _ = await r.cosState() }",
                                       "}"]), ["2 cosState("])
        let ping = ["while nowMs() - t0 < 11000 && !Task.isCancelled {", "    if !polled && nowMs() - t0 > 8000 {", "        polled = true",
                    "        if let s = try? await relay.latestState(since: \"2h\") { best = s }", "    }", "}"]
        XCTAssertEqual(Self.loopReads(ping, file: "Live.swift"), [])
        XCTAssertEqual(Self.loopReads(ping, file: "Other.swift"), ["4 latestState("])
    }
}
