import XCTest

final class AreaCodeTests: XCTestCase {
    func testAcceptsRealPrefixes() {
        for text in ["844", "877", "800", "212", "305", "999", "200"] {
            XCTAssertNotNil(AreaCode(text), text)
            XCTAssertNil(AreaCode.validationError(for: text), text)
        }
    }

    func testRejectsInvalidPrefixes() {
        // Wrong length, not digits, leading 0 or 1, service codes, non-ASCII digits.
        for text in ["", "8", "84", "8444", "84a", " 84", "044", "144", "911", "411", "811", "８４４", "٨٤٤"] {
            XCTAssertNil(AreaCode(text), text)
            XCTAssertNotNil(AreaCode.validationError(for: text), text)
        }
    }

    func testRangeIsEveryRealNumberOfThePrefix() throws {
        let code = try XCTUnwrap(AreaCode("844"))
        XCTAssertEqual(code.range.lower, 1_844_200_0000)
        XCTAssertEqual(code.range.upper, 1_844_999_9999)
        XCTAssertEqual(code.range.count, 8_000_000)

        XCTAssertTrue(code.contains(1_844_200_0000))
        XCTAssertTrue(code.contains(1_844_555_0123))
        XCTAssertTrue(code.contains(1_844_999_9999))
        // Exchanges 0XX and 1XX don't exist; neighbours and other formats aren't covered.
        XCTAssertFalse(code.contains(1_844_199_9999))
        XCTAssertFalse(code.contains(1_844_000_0000))
        XCTAssertFalse(code.contains(1_845_000_0000))
        XCTAssertFalse(code.contains(1_843_999_9999))
        XCTAssertFalse(code.contains(844_555_0123))
    }

    func testShardsCutTheRangeIntoMillions() throws {
        for text in ["844", "877", "212"] {
            let code = try XCTUnwrap(AreaCode(text))
            let shards = code.shards

            XCTAssertEqual(shards.count, 8)
            XCTAssertEqual(shards.count, AppConstants.shardsPerPrefix)
            XCTAssertEqual(shards.first?.lower, code.range.lower)
            XCTAssertEqual(shards.last?.upper, code.range.upper)
            for (index, shard) in shards.enumerated() {
                XCTAssertEqual(shard.count, 1_000_000)
                // Shard k is exactly the exchanges that start with digit 2 + k.
                let npa = try XCTUnwrap(Int64(text))
                XCTAssertEqual(shard.lower, 1_000_000_0000 + npa * 1_000_0000 + Int64(index + 2) * 100_0000)
                if index > 0 {
                    XCTAssertEqual(shard.lower, shards[index - 1].upper + 1, "shards must be contiguous")
                }
            }
        }
    }

    func testDifferentPrefixesNeverOverlap() {
        let codes = AreaCode.tollFree
        XCTAssertEqual(codes.count, 7)
        let shards = codes.flatMap(\.shards).sorted { $0.lower < $1.lower }
        for (previous, next) in zip(shards, shards.dropFirst()) {
            XCTAssertLessThan(previous.upper, next.lower)
        }
    }

    func testCodableRoundTripAndValidation() throws {
        let codes = [try XCTUnwrap(AreaCode("844")), try XCTUnwrap(AreaCode("877"))]
        let data = try JSONEncoder().encode(codes)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["844","877"]"#)
        XCTAssertEqual(try JSONDecoder().decode([AreaCode].self, from: data), codes)
        XCTAssertThrowsError(try JSONDecoder().decode([AreaCode].self, from: Data(#"["911"]"#.utf8)))
    }

    func testCapacityConstants() {
        XCTAssertEqual(AppConstants.slotCount, 64)
        XCTAssertEqual(AppConstants.maxPrefixes, 8)
        XCTAssertEqual(AppConstants.slotLabel(0), "01")
        XCTAssertEqual(AppConstants.slotLabel(31), "32")
        XCTAssertEqual(AppConstants.slotLabel(63), "64")
        XCTAssertEqual(AppConstants.extensionIdentifier(slot: 6), "com.example.prefixblocker.shard07")
    }
}
