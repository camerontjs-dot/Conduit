import XCTest
@testable import ConduitCore

final class OpenCodeSSELineDecoderTests: XCTestCase {
    func testBoundBeforeDecodeAndStickyFailure() throws {
        var decoder = OpenCodeSSELineDecoder()
        for _ in 0..<2_097_152 { XCTAssertNil(try decoder.append(0x61)) }
        XCTAssertEqual(decoder.bufferedByteCount, 2_097_152)
        XCTAssertThrowsError(try decoder.append(0x61))
        XCTAssertEqual(decoder.bufferedByteCount, 0)
        XCTAssertThrowsError(try decoder.append(10))
    }

    func testSSEFramingUnicodeAndFinalLine() throws {
        var decoder = OpenCodeSSELineDecoder()
        var lines: [String] = []
        let input = "data: é🙂\r\n\rdata: two\ndata: end"
        for byte in input.utf8 { if let line = try decoder.append(byte) { lines.append(line) } }
        if let final = try decoder.finish() { lines.append(final) }
        XCTAssertEqual(lines, ["data: é🙂", "", "data: two", "data: end"])
    }

    func testExactLimitAndCRLFAreAccepted() throws {
        var decoder = OpenCodeSSELineDecoder(maximumLineBytes: 3)
        for byte in "abc".utf8 { XCTAssertNil(try decoder.append(byte)) }
        XCTAssertEqual(try decoder.append(13), "abc")
        XCTAssertNil(try decoder.append(10))
        XCTAssertNil(try decoder.finish())
    }
}
