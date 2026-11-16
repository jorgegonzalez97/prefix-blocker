import Foundation

/// Reads a phone number the way a person types or pastes it, to answer
/// "would this call be blocked?".
enum NumberCheck {
    enum Parsed: Equatable {
        /// Not enough digits yet.
        case incomplete
        /// Can't be a +1 number; the text says why.
        case invalid(String)
        /// A complete number in CallKit's format, e.g. 1_844_555_0123.
        case number(Int64)
    }

    /// Accepts any punctuation and an optional leading +1: "(844) 555-0123",
    /// "+1 844 555 0123" and "18445550123" are the same number.
    static func parse(_ text: String) -> Parsed {
        var digits = text.filter { $0.isASCII && $0.isNumber }
        if digits.first == "1" {
            // A country code, possibly with the rest still being typed.
            guard digits.count >= 11 else { return .incomplete }
            digits.removeFirst()
        }
        guard digits.count >= 10 else { return .incomplete }
        guard digits.count == 10 else {
            return .invalid("That's too many digits for a US or Canada number.")
        }

        let areaCode = String(digits.prefix(3))
        if let problem = AreaCode.validationError(for: areaCode) {
            return .invalid(problem)
        }
        let exchange = digits[digits.index(digits.startIndex, offsetBy: 3)]
        guard exchange != "0", exchange != "1" else {
            return .invalid("No real number has 0 or 1 right after the area code.")
        }
        guard let national = Int64(digits) else { return .incomplete }
        return .number(1_000_000_0000 + national)
    }

    /// The area code of a number returned by `parse`.
    static func areaCode(of number: Int64) -> AreaCode? {
        AreaCode(String((number / 1_000_0000) % 1000))
    }

    /// "+1 (844) 555-0123"
    static func formatted(_ number: Int64) -> String {
        let national = number % 1_000_000_0000
        let area = national / 1_000_0000
        let exchange = (national / 1_0000) % 1000
        let line = national % 1_0000
        return "+1 (\(area)) \(pad(exchange, 3))-\(pad(line, 4))"
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}

/// What iOS does with a call from one number, as far as the app knows.
enum NumberVerdict: Equatable {
    /// iOS has the number in its block list.
    case blocked(AreaCode)
    /// Its prefix is in the list, but iOS hasn't loaded this part of it yet.
    case notLoadedYet(AreaCode)
    /// Its prefix is in the list but paused.
    case paused(AreaCode)
    /// No prefix in the list covers it.
    case allowed
}
