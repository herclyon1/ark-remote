import XCTest
@testable import ArkRemote

/// Gzip.inflate decodes what the relay's gzip.compress wrote. The fixture is synthetic (the repo is public, so no real
/// state goes in): a JSON object shaped like a COS state (`at`, `config`, rows of Chinese text and numbers), compressed
/// with Python's gzip.compress(mtime=0) as the relay does; the expected bytes are that JSON text.
final class GzipTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: dir.appendingPathComponent("Fixtures").appendingPathComponent(name))
    }

    func testCosStateMatchesPythonByteForByte() throws {
        let gz = try fixture("cos-state.gz")
        let expected = try fixture("cos-state.json")
        XCTAssertEqual(gz.count, 3014)
        XCTAssertEqual(expected.count, 54308)
        let out = try Gzip.inflate(gz)
        XCTAssertEqual(out.count, expected.count)
        XCTAssertTrue(out == expected, "inflated bytes differ from Python's gzip.decompress")
    }

    /// The same object through Relay.unwrap, as cosState decodes it (base64 `gz` → JSON).
    func testCosStateThroughUnwrap() throws {
        let gz = try fixture("cos-state.gz")
        let state = try Relay.unwrap(.object(["gz": .string(gz.base64EncodedString())]))
        XCTAssertNotNil(state?["config"])
        XCTAssertNotNil(state?["at"])
    }

    /// The header fields the relay does not write but gzip(1) does: FNAME (flag 0x08) is skipped.
    func testNamedMemberHeaderIsSkipped() throws {
        let gz = Data(base64Encoded: "H4sICAAAAAAC/3N0YXRlLmpzb24Aezaj79n0pc+m7XzRMV/hede2Zw2NCs9GxQZMDAA3ZEAOkAEAAA==")!
        XCTAssertEqual(String(decoding: try Gzip.inflate(gz), as: UTF8.self), String(repeating: "明日方舟 状态 ", count: 20))
    }

    /// compresslevel=0: one stored block.
    func testStoredBlock() throws {
        let gz = Data(base64Encoded: "H4sIAAAAAAAA/wESAO3/aGVsbG8gc3RvcmVkIGJsb2NrCrWkphIAAAA=")!
        XCTAssertEqual(String(decoding: try Gzip.inflate(gz), as: UTF8.self), "hello stored block")
    }

    func testEmptyMember() throws {
        let gz = Data(base64Encoded: "H4sIAAAAAAAC/wMAAAAAAAAAAAA=")!
        XCTAssertEqual(try Gzip.inflate(gz), Data())
    }

    func testNotGzipAndCorruptThrow() throws {
        XCTAssertThrowsError(try Gzip.inflate(Data("{\"a\":1} not gzip data".utf8)))
        var bad = [UInt8](try fixture("cos-state.gz"))
        for i in 10..<60 { bad[i] = 0xff }
        XCTAssertThrowsError(try Gzip.inflate(Data(bad)))
    }

    /// A body cut short (a lost ntfy slice) is an error, not a shorter result.
    func testTruncatedThrows() throws {
        let gz = try fixture("cos-state.gz")
        XCTAssertThrowsError(try Gzip.inflate(gz.prefix(gz.count / 2)))
    }
}
