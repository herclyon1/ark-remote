import Foundation
import XCTest

/// Files of this repository, for the regression checks that read the code or the build settings rather than run them
/// (one check per defect in App-回归清单-0108). Paths are relative to the repository root.
enum RepoFiles {
    /// The repository root (the iOS run builds the tests from a folder of symlinks, hence resolvingSymlinksInPath).
    static let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().resolvingSymlinksInPath()

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    static func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    static func lines(_ path: String) throws -> [String] {
        try text(path).components(separatedBy: "\n")
    }

    /// Every Swift file under Sources/, as (path relative to the root, lines).
    static func swiftSources() throws -> [(path: String, lines: [String])] {
        let dir = url("Sources")
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 10, "Sources/ not found at \(dir.path)")
        return try files.sorted { $0.path < $1.path }.map { f in
            let rel = String(f.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            return (rel, try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n"))
        }
    }

    /// The code of a line, without a trailing `//` comment (good enough for these scans: no check looks for `//` in a string).
    static func code(_ line: String) -> String {
        line.components(separatedBy: "//")[0]
    }

    /// The lines of the brace-matched body that starts on the first line containing `marker`, comments dropped.
    static func body(after marker: String, in lines: [String]) -> [String]? {
        guard let start = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
        var depth = 0, opened = false, out: [String] = []
        for line in lines[start...] {
            let c = code(line)
            out.append(c)
            depth += c.filter { $0 == "{" }.count - c.filter { $0 == "}" }.count
            if c.contains("{") { opened = true }
            if opened && depth <= 0 { break }
        }
        return out
    }

    /// Which platform a line is compiled for, as far as these scans need it.
    enum Platform { case android, apple, either }

    /// The platform of each line, from the `#if` stack: `#if os(Android)` and the `#else` of `#if !os(Android)…` are
    /// Android; `#if !os(Android)…` and the `#else` of `#if os(Android)` are Apple; any other condition is either.
    /// The `#else` of `#if !os(Android) && canImport(UIKit)` also builds for macOS; it counts as Android here, because
    /// the scans that use this ask what the Android build draws. Directive lines get the platform around them.
    static func platforms(_ lines: [String]) -> [Platform] {
        func kind(_ cond: String) -> Platform {
            let c = cond.trimmingCharacters(in: .whitespaces)
            if c == "os(Android)" { return .android }
            if c == "!os(Android)" || c.hasPrefix("!os(Android) &&") { return .apple }
            return .either
        }
        func flip(_ p: Platform) -> Platform { p == .android ? .apple : p == .apple ? .android : .either }
        var stack: [(cond: Platform, now: Platform)] = []
        var out: [Platform] = []
        for raw in lines {
            let c = code(raw).trimmingCharacters(in: .whitespaces)
            if c.hasPrefix("#if ") {
                let k = kind(String(c.dropFirst(4)))
                stack.append((k, k))
            } else if c.hasPrefix("#elseif ") {
                if !stack.isEmpty { stack[stack.count - 1].now = kind(String(c.dropFirst(8))) }
            } else if c.hasPrefix("#else") {
                if !stack.isEmpty { stack[stack.count - 1].now = flip(stack[stack.count - 1].cond) }
            } else if c.hasPrefix("#endif") {
                _ = stack.popLast()
            }
            out.append(stack.last(where: { $0.now != .either })?.now ?? .either)
        }
        return out
    }

    /// Whether some line of `lines` compiled for `platform` contains `text` (comments dropped).
    static func contains(_ text: String, on platform: Platform, in lines: [String]) -> Bool {
        zip(lines, platforms(lines)).contains { line, p in p == platform && code(line).contains(text) }
    }
}
