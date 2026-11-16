import Foundation

/// Turns slots into the names shown in Settings: [0, 1, 2, 8] → "01–03, 09".
enum SlotFormatter {
    static func ranges(_ slots: [Int]) -> String {
        var parts: [String] = []
        var start: Int?
        var previous: Int?
        func flush() {
            guard let start, let previous else { return }
            parts.append(start == previous
                         ? AppConstants.slotLabel(start)
                         : "\(AppConstants.slotLabel(start))–\(AppConstants.slotLabel(previous))")
        }
        for slot in slots.sorted() {
            if let last = previous, slot == last + 1 {
                previous = slot
            } else {
                flush()
                start = slot
                previous = slot
            }
        }
        flush()
        return parts.joined(separator: ", ")
    }
}
