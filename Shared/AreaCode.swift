import Foundation

/// A run of consecutive phone numbers in the format CallKit uses
/// (`CXCallDirectoryPhoneNumber`): country code followed by the national
/// number, as an `Int64`. For example 1_844_200_0000 is +1 (844) 200-0000.
struct NumberRange: Codable, Hashable, Sendable {
    var lower: Int64
    var count: Int64

    /// Last number in the range.
    var upper: Int64 { lower + count - 1 }

    func contains(_ number: Int64) -> Bool { number >= lower && number <= upper }
}

/// A 3-digit North American prefix (area code), e.g. 844 or 877.
///
/// Blocking it means blocking every number `+1 NPA NXX XXXX`. Exchanges (`NXX`)
/// never start with 0 or 1 in the North American Numbering Plan, so the real
/// numbers are `NPA-200-0000 … NPA-999-9999`: 8,000,000 of them.
struct AreaCode: Hashable, Sendable, Comparable {
    static let numbersPerAreaCode: Int64 = 8_000_000

    /// Toll-free prefixes, the usual source of robocalls.
    static let tollFree: [AreaCode] = ["800", "833", "844", "855", "866", "877", "888"].compactMap(AreaCode.init)

    let digits: String

    init?(_ text: String) {
        guard Self.validationError(for: text) == nil else { return nil }
        digits = text
    }

    /// `nil` when `text` is a prefix that can be blocked; otherwise a message for the user.
    static func validationError(for text: String) -> String? {
        let characters = Array(text)
        guard characters.count == 3, characters.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return "Enter exactly 3 digits."
        }
        guard characters[0] != "0", characters[0] != "1" else {
            return "Prefixes can't start with 0 or 1."
        }
        guard !(characters[1] == "1" && characters[2] == "1") else {
            return "\(text) is a service code (like 911), not a calling prefix."
        }
        return nil
    }

    var isTollFree: Bool { Self.tollFree.contains(self) }

    /// Every number this prefix covers, lowest to highest.
    var range: NumberRange {
        // "844" is valid by construction, so the conversion can't fail.
        let npa = Int64(digits) ?? 0
        return NumberRange(lower: 1_000_000_0000 + npa * 1_000_0000 + 200_0000,
                           count: Self.numbersPerAreaCode)
    }

    /// The range cut into pieces of `AppConstants.shardSize`, one per extension.
    var shards: [NumberRange] {
        let whole = range
        var result: [NumberRange] = []
        var lower = whole.lower
        while lower <= whole.upper {
            let count = min(AppConstants.shardSize, whole.upper - lower + 1)
            result.append(NumberRange(lower: lower, count: count))
            lower += count
        }
        return result
    }

    func contains(_ number: Int64) -> Bool { range.contains(number) }

    /// For display, e.g. "+1 (844) XXX-XXXX".
    var pattern: String { "+1 (\(digits)) XXX-XXXX" }

    static func < (lhs: AreaCode, rhs: AreaCode) -> Bool { lhs.digits < rhs.digits }
}

extension AreaCode: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let code = AreaCode(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid prefix \(text)")
        }
        self = code
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(digits)
    }
}
