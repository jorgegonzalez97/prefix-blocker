import XCTest

final class NumberCheckTests: XCTestCase {
    func testAcceptsTheUsualWaysOfWritingANumber() {
        let expected = NumberCheck.Parsed.number(1_844_555_0123)
        for text in ["8445550123", "(844) 555-0123", "844-555-0123", "844.555.0123",
                     "+1 844 555 0123", "1 (844) 555-0123", "18445550123", " +1(844)555 0123 "] {
            XCTAssertEqual(NumberCheck.parse(text), expected, text)
        }
    }

    func testWaitsForAllTheDigits() {
        for text in ["", "8", "844", "844555012", "+1", "1844555012", "+1 (844) 555-012"] {
            XCTAssertEqual(NumberCheck.parse(text), .incomplete, text)
        }
    }

    func testExplainsNumbersThatCannotExist() {
        func isInvalid(_ text: String) -> Bool {
            if case .invalid = NumberCheck.parse(text) { return true }
            return false
        }
        XCTAssertTrue(isInvalid("0445550123"), "area codes don't start with 0")
        XCTAssertTrue(isInvalid("9115550123"), "service code")
        XCTAssertTrue(isInvalid("8441550123"), "exchanges don't start with 1")
        XCTAssertTrue(isInvalid("8440550123"), "exchanges don't start with 0")
        XCTAssertTrue(isInvalid("84455501234"), "11 digits without a leading 1")
        XCTAssertTrue(isInvalid("184455501234"), "too long even with the country code")
        XCTAssertTrue(isInvalid("+44 20 7946 0958 1"), "another country")
    }

    func testEveryParsedNumberIsOneAPrefixWouldBlock() {
        // The lowest and highest numbers of a prefix are valid, and belong to it.
        let prefix = AreaCode("877")!
        for number in [prefix.range.lower, prefix.range.upper] {
            let text = NumberCheck.formatted(number)
            XCTAssertEqual(NumberCheck.parse(text), .number(number), text)
            XCTAssertEqual(NumberCheck.areaCode(of: number), prefix)
            XCTAssertTrue(prefix.contains(number))
        }
    }

    func testFormatting() {
        XCTAssertEqual(NumberCheck.formatted(1_844_555_0123), "+1 (844) 555-0123")
        XCTAssertEqual(NumberCheck.formatted(1_212_200_0000), "+1 (212) 200-0000")
        XCTAssertEqual(NumberCheck.formatted(1_877_999_9999), "+1 (877) 999-9999")
        XCTAssertEqual(NumberCheck.formatted(1_305_201_0007), "+1 (305) 201-0007")
    }

    func testRegions() {
        XCTAssertEqual(AreaCodeDirectory.region(for: AreaCode("844")!), "Toll-free")
        XCTAssertEqual(AreaCodeDirectory.region(for: AreaCode("800")!), "Toll-free")
        XCTAssertEqual(AreaCodeDirectory.region(for: AreaCode("900")!), "Premium-rate")
        XCTAssertEqual(AreaCodeDirectory.region(for: AreaCode("212")!), "New York")
        XCTAssertEqual(AreaCodeDirectory.region(for: AreaCode("214")!), "Texas")
        XCTAssertEqual(AreaCodeDirectory.region(for: AreaCode("304")!), "West Virginia")
        XCTAssertEqual(AreaCodeDirectory.region(for: AreaCode("202")!), "Washington, D.C.")
        XCTAssertEqual(AreaCodeDirectory.region(for: AreaCode("206")!), "Washington")
        XCTAssertEqual(AreaCodeDirectory.region(for: AreaCode("416")!), "Ontario")
        XCTAssertEqual(AreaCodeDirectory.region(for: AreaCode("876")!), "Jamaica")
        XCTAssertNil(AreaCodeDirectory.region(for: AreaCode("200")!), "not in use")
        // Every toll-free prefix the app suggests is labelled as such.
        for prefix in AreaCode.tollFree {
            XCTAssertEqual(AreaCodeDirectory.region(for: prefix), "Toll-free", prefix.digits)
        }
    }
}
