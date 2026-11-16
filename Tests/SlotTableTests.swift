import XCTest

final class SlotTableTests: XCTestCase {
    private let c844 = AreaCode("844")!
    private let c877 = AreaCode("877")!
    private let c855 = AreaCode("855")!
    private let c866 = AreaCode("866")!
    private let c888 = AreaCode("888")!

    private func assign(_ prefixes: [AreaCode], current: [NumberRange?] = []) -> [NumberRange?] {
        SlotTable.assign(prefixes: prefixes, current: current, slotCount: 32)
    }

    func testFirstPrefixTakesTheFirstEightSlotsInOrder() {
        let slots = assign([c844])
        XCTAssertEqual(slots.count, 32)
        XCTAssertEqual(Array(slots[0..<8]), c844.shards.map(Optional.some))
        XCTAssertTrue(slots[8...].allSatisfy { $0 == nil })
        XCTAssertEqual(SlotTable.slots(of: c844, in: slots), Array(0..<8))
    }

    func testAddingAPrefixLeavesExistingSlotsAlone() {
        let before = assign([c844])
        let after = assign([c844, c877], current: before)
        XCTAssertEqual(Array(after[0..<8]), Array(before[0..<8]))
        XCTAssertEqual(SlotTable.slots(of: c877, in: after), Array(8..<16))
    }

    func testRemovingAPrefixFreesItsSlotsWithoutMovingOthers() {
        let both = assign([c844, c877])
        let onlySecond = assign([c877], current: both)
        XCTAssertTrue(onlySecond[0..<8].allSatisfy { $0 == nil })
        XCTAssertEqual(SlotTable.slots(of: c877, in: onlySecond), Array(8..<16))

        // The next prefix reuses the freed slots at the top of the list.
        let reused = assign([c877, c855], current: onlySecond)
        XCTAssertEqual(SlotTable.slots(of: c855, in: reused), Array(0..<8))
        XCTAssertEqual(SlotTable.slots(of: c877, in: reused), Array(8..<16))
    }

    func testFourPrefixesFillEverySlotExactlyOnce() {
        let slots = assign([c844, c877, c855, c866])
        let ranges = slots.compactMap { $0 }
        XCTAssertEqual(ranges.count, 32)
        XCTAssertEqual(Set(ranges).count, 32)
        XCTAssertEqual(ranges.reduce(0) { $0 + $1.count }, 32_000_000)
    }

    func testCapacity() {
        XCTAssertTrue(SlotTable.canAdd(to: [], slotCount: 32))
        XCTAssertTrue(SlotTable.canAdd(to: [c844, c877, c855], slotCount: 32))
        XCTAssertFalse(SlotTable.canAdd(to: [c844, c877, c855, c866], slotCount: 32))
        XCTAssertEqual(SlotTable.room(after: [c844], slotCount: 32), 3)
        XCTAssertEqual(SlotTable.room(after: [c844, c877, c855, c866, c888], slotCount: 32), 0)

        // The shipping app: 64 extensions, 8 prefixes.
        XCTAssertTrue(SlotTable.canAdd(to: [c844, c877, c855, c866]))
        XCTAssertEqual(SlotTable.room(after: [c844, c877, c855]), 5)

        // Even if asked, a fifth prefix never displaces or duplicates anything.
        let four = assign([c844, c877, c855, c866])
        let five = assign([c844, c877, c855, c866, c888], current: four)
        XCTAssertEqual(five, four)
        XCTAssertTrue(SlotTable.slots(of: c888, in: five).isEmpty)
    }

    func testIgnoresDuplicatesAndStaleEntries() {
        XCTAssertEqual(assign([c844, c844]), assign([c844]))

        // A table with a shard listed twice and a shard nobody wants any more.
        var messy = assign([c844])
        messy[20] = messy[0]
        messy[21] = c877.shards[3]
        XCTAssertEqual(assign([c844], current: messy), assign([c844]))
    }

    func testHandlesTablesOfAnotherSize() {
        let short = Array(assign([c844]).prefix(4))
        XCTAssertEqual(assign([c844], current: short), assign([c844]))

        let long = assign([c844]) + [c877.shards[0], nil]
        XCTAssertEqual(assign([c844, c877], current: long).count, 32)
        XCTAssertEqual(SlotTable.slots(of: c877, in: assign([c844, c877], current: long)), Array(8..<16))
    }

    func testConfigKeepsSlotsInStepWithPrefixes() {
        var config = SharedConfig()
        XCTAssertEqual(config.slots.count, AppConstants.slotCount)
        config.prefixes = [c844, c877]
        config = config.withSlotsAssigned()
        XCTAssertEqual(config.slots.compactMap { $0 }.count, 16)
        config.prefixes = []
        XCTAssertTrue(config.withSlotsAssigned().slots.allSatisfy { $0 == nil })
    }

    func testReplacingAPrefixKeepsItsSlots() {
        // 877 sits in slots 8–15, with 0–7 free above it.
        let table = assign([c877], current: assign([c844, c877]))
        let replaced = SlotTable.replacing(c877, with: c855, in: table)

        XCTAssertEqual(SlotTable.slots(of: c855, in: replaced), Array(8..<16))
        XCTAssertEqual(Array(replaced[8..<16]), c855.shards.map(Optional.some), "shards stay in order")
        XCTAssertTrue(SlotTable.slots(of: c877, in: replaced).isEmpty)
        XCTAssertTrue(replaced[0..<8].allSatisfy { $0 == nil })
        // A later assignment leaves the replaced prefix where it is.
        XCTAssertEqual(assign([c855], current: replaced), replaced)
        // Other prefixes are untouched.
        let both = assign([c844, c877])
        XCTAssertEqual(SlotTable.slots(of: c844, in: SlotTable.replacing(c877, with: c855, in: both)), Array(0..<8))
    }

    func testPausedPrefixKeepsItsSlotsButProvidesNothing() {
        var config = SharedConfig()
        config.prefixes = [c844, c877]
        config.paused = [c844, c888] // 888 isn't in the list
        config = config.withSlotsAssigned()

        XCTAssertEqual(config.paused, [c844], "a pause can't outlive its prefix")
        XCTAssertEqual(SlotTable.slots(of: c844, in: config.slots), Array(0..<8))
        XCTAssertNil(config.activeRange(slot: 0))
        XCTAssertNil(config.activeRange(slot: 7))
        XCTAssertEqual(config.activeRange(slot: 8), c877.shards[0])
        XCTAssertNil(config.activeRange(slot: 16))
        XCTAssertNil(config.activeRange(slot: 5000))
        XCTAssertEqual(config.activeSlots.compactMap { $0 }, c877.shards)
    }

    func testConfigFromAnEarlierVersionStillLoads() throws {
        // Version 1.0 wrote no "paused" key and had 32 slots.
        let slots = assign([c844]).map { $0.map { #"{"lower":\#($0.lower),"count":\#($0.count)}"# } ?? "null" }
        let json = #"{"prefixes":["844"],"slots":[\#(slots.joined(separator: ","))]}"#
        let config = try JSONDecoder().decode(SharedConfig.self, from: Data(json.utf8))

        XCTAssertEqual(config.prefixes, [c844])
        XCTAssertTrue(config.paused.isEmpty)
        XCTAssertEqual(config.slots.count, 32)

        // And what this version writes reads back the same.
        var current = SharedConfig()
        current.prefixes = [c844, c877]
        current.paused = [c877]
        current = current.withSlotsAssigned()
        let decoded = try JSONDecoder().decode(SharedConfig.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(decoded, current)
    }

    func testSlotFormatter() {
        XCTAssertEqual(SlotFormatter.ranges([]), "")
        XCTAssertEqual(SlotFormatter.ranges([4]), "05")
        XCTAssertEqual(SlotFormatter.ranges(Array(0..<8)), "01–08")
        XCTAssertEqual(SlotFormatter.ranges([8, 0, 2, 1, 31]), "01–03, 09, 32")
        XCTAssertEqual(SlotFormatter.ranges(Array(0..<8) + Array(16..<24)), "01–08, 17–24")
    }
}
