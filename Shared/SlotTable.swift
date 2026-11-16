import Foundation

/// What the user configured, plus which extension blocks which numbers.
///
/// `slots[i]` is the range assigned to extension `i`, or `nil` if that
/// extension has nothing to block. A paused prefix keeps its slots, so the
/// switches the user turned on for it stay reserved, but its extensions hand
/// iOS nothing: what an extension actually provides is `activeRange(slot:)`.
/// The app writes this file; extensions only read it.
struct SharedConfig: Equatable, Sendable {
    var prefixes: [AreaCode] = []
    /// Prefixes kept in the list but not blocked right now.
    var paused: Set<AreaCode> = []
    var slots: [NumberRange?] = Array(repeating: nil, count: AppConstants.slotCount)

    /// The same configuration with `slots` recomputed for `prefixes`.
    func withSlotsAssigned() -> SharedConfig {
        var copy = self
        copy.paused = paused.intersection(prefixes)
        copy.slots = SlotTable.assign(prefixes: prefixes, current: slots, slotCount: AppConstants.slotCount)
        return copy
    }

    /// What extension `slot` hands to iOS: its range, unless the prefix it belongs to is paused.
    func activeRange(slot: Int) -> NumberRange? {
        guard slots.indices.contains(slot), let range = slots[slot] else { return nil }
        return paused.contains { $0.contains(range.lower) } ? nil : range
    }

    /// `activeRange(slot:)` for every slot.
    var activeSlots: [NumberRange?] {
        guard !paused.isEmpty else { return slots }
        return slots.indices.map(activeRange(slot:))
    }
}

extension SharedConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case prefixes, paused, slots
    }

    /// Hand-written so a file saved by an earlier version, without `paused`, still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prefixes = try container.decode([AreaCode].self, forKey: .prefixes)
        paused = try container.decodeIfPresent(Set<AreaCode>.self, forKey: .paused) ?? []
        slots = try container.decode([NumberRange?].self, forKey: .slots)
    }
}

enum SlotTable {
    /// Gives every shard of every prefix a slot.
    ///
    /// The assignment is stable: a shard that already has a slot keeps it, so
    /// adding or removing one prefix never makes iOS reload the others. New
    /// shards fill the lowest free slots, which keeps the switches the user has
    /// to turn on at the top of the list in Settings.
    ///
    /// Shards that don't fit are left out; callers check `canAdd` first.
    static func assign(prefixes: [AreaCode], current: [NumberRange?], slotCount: Int) -> [NumberRange?] {
        var wanted: [NumberRange] = []
        var seen = Set<NumberRange>()
        for prefix in prefixes {
            for shard in prefix.shards where seen.insert(shard).inserted {
                wanted.append(shard)
            }
        }

        var slots = [NumberRange?](repeating: nil, count: slotCount)
        var placed = Set<NumberRange>()
        for (index, shard) in current.prefix(slotCount).enumerated() {
            if let shard, seen.contains(shard), placed.insert(shard).inserted {
                slots[index] = shard
            }
        }

        var free = slots.indices.filter { slots[$0] == nil }.makeIterator()
        for shard in wanted where !placed.contains(shard) {
            guard let index = free.next() else { break }
            slots[index] = shard
        }
        return slots
    }

    /// `slots` with every shard of `old` swapped for the matching shard of
    /// `new`, in place. Changing a prefix this way reuses the extensions, and
    /// so the switches, the old prefix was already using.
    static func replacing(_ old: AreaCode, with new: AreaCode, in slots: [NumberRange?]) -> [NumberRange?] {
        let replacements = Dictionary(uniqueKeysWithValues: zip(old.shards, new.shards))
        return slots.map { slot in
            guard let slot else { return nil }
            return replacements[slot] ?? slot
        }
    }

    /// How many more prefixes fit next to `existing`.
    static func room(after existing: [AreaCode], slotCount: Int = AppConstants.slotCount) -> Int {
        max(0, slotCount / AppConstants.shardsPerPrefix - existing.count)
    }

    /// Whether one more prefix fits next to `existing`.
    static func canAdd(to existing: [AreaCode], slotCount: Int = AppConstants.slotCount) -> Bool {
        room(after: existing, slotCount: slotCount) >= 1
    }

    /// Slots that hold the shards of `prefix`, in ascending order.
    static func slots(of prefix: AreaCode, in slots: [NumberRange?]) -> [Int] {
        let shards = Set(prefix.shards)
        return slots.indices.filter { index in
            slots[index].map(shards.contains) ?? false
        }
    }
}
