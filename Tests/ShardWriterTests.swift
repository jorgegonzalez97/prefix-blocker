import XCTest

final class ShardWriterTests: XCTestCase {
    private let shardA = AreaCode("844")!.shards[0]
    private let shardB = AreaCode("877")!.shards[5]

    // MARK: What the extension hands to iOS

    func testFullRequestProvidesExactlyTheShard() {
        let directory = FakeDirectory()
        directory.begin(incremental: false)
        ShardWriter.write(shardA, incremental: false, to: directory)

        XCTAssertNil(directory.commit())
        XCTAssertEqual(directory.committed, [shardA])
        XCTAssertEqual(directory.count, 1_000_000)
        XCTAssertTrue(directory.contains(1_844_200_0000))
        XCTAssertTrue(directory.contains(1_844_299_9999))
        XCTAssertFalse(directory.contains(1_844_300_0000))
        XCTAssertFalse(directory.contains(1_844_199_9999))
    }

    func testIncrementalRequestReplacesWhatWasLoaded() {
        let directory = FakeDirectory()
        directory.begin(incremental: false)
        ShardWriter.write(shardA, incremental: false, to: directory)
        XCTAssertNil(directory.commit())

        directory.begin(incremental: true)
        ShardWriter.write(shardB, incremental: true, to: directory)
        XCTAssertNil(directory.commit())
        XCTAssertEqual(directory.committed, [shardB])
    }

    func testReloadingTheSameShardIsHarmless() {
        let directory = FakeDirectory()
        for incremental in [false, true, true] {
            directory.begin(incremental: incremental)
            ShardWriter.write(shardA, incremental: incremental, to: directory)
            XCTAssertNil(directory.commit())
            XCTAssertEqual(directory.committed, [shardA])
        }
    }

    func testEmptySlotClearsTheExtension() {
        let directory = FakeDirectory()
        directory.begin(incremental: false)
        ShardWriter.write(shardA, incremental: false, to: directory)
        XCTAssertNil(directory.commit())

        directory.begin(incremental: true)
        ShardWriter.write(nil, incremental: true, to: directory)
        XCTAssertNil(directory.commit())
        XCTAssertEqual(directory.count, 0)

        directory.begin(incremental: false)
        ShardWriter.write(nil, incremental: false, to: directory)
        XCTAssertNil(directory.commit())
        XCTAssertEqual(directory.count, 0)
    }

    func testBatchBoundariesLoseNothing() {
        // Sizes around the autorelease batch size.
        for count in [1, ShardWriter.batchSize - 1, ShardWriter.batchSize, ShardWriter.batchSize + 1, 3 * ShardWriter.batchSize + 7] {
            let range = NumberRange(lower: 1_844_200_0000, count: count)
            let directory = FakeDirectory()
            directory.begin(incremental: false)
            ShardWriter.write(range, incremental: false, to: directory)
            XCTAssertNil(directory.commit())
            XCTAssertEqual(directory.committed, [range], "count \(count)")
        }
    }

    func testAMillionNumbersAreGeneratedQuickly() {
        final class Counter: BlockingEntrySink {
            var count = 0
            var last: Int64 = 0
            func removeAll() {}
            func add(_ number: Int64) { count += 1; last = number }
        }
        let counter = Counter()
        let started = Date()
        ShardWriter.write(shardA, incremental: false, to: counter)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(counter.count, 1_000_000)
        XCTAssertEqual(counter.last, shardA.upper)
        // Unoptimised test build on a simulator; the release extension is far faster.
        XCTAssertLessThan(elapsed, 5)
    }

    // MARK: The extension's handling of the shared file

    func testProviderReadsItsOwnSlot() throws {
        let store = makeTemporaryStore()
        var config = SharedConfig()
        config.prefixes = [AreaCode("844")!]
        config = config.withSlotsAssigned()
        try store.save(config)

        let directory = FakeDirectory()
        directory.begin(incremental: false)
        XCTAssertEqual(try ShardProvider.provide(slot: 3, from: store, incremental: false, to: directory), 1_000_000)
        XCTAssertNil(directory.commit())
        XCTAssertEqual(directory.committed, [AreaCode("844")!.shards[3]])

        // Slots without a shard, or beyond the table, provide nothing.
        for slot in [8, 31, 32, 63, 64, 500] {
            let empty = FakeDirectory()
            empty.begin(incremental: false)
            XCTAssertEqual(try ShardProvider.provide(slot: slot, from: store, incremental: false, to: empty), 0)
            XCTAssertNil(empty.commit())
            XCTAssertEqual(empty.count, 0)
        }
    }

    func testProviderProvidesNothingForAPausedPrefix() throws {
        let store = makeTemporaryStore()
        var config = SharedConfig()
        config.prefixes = [AreaCode("844")!, AreaCode("877")!]
        config.paused = [AreaCode("844")!]
        config = config.withSlotsAssigned()
        try store.save(config)

        let paused = FakeDirectory()
        paused.begin(incremental: false)
        XCTAssertEqual(try ShardProvider.provide(slot: 3, from: store, incremental: false, to: paused), 0)
        XCTAssertNil(paused.commit())
        XCTAssertEqual(paused.count, 0)

        let active = FakeDirectory()
        active.begin(incremental: false)
        XCTAssertEqual(try ShardProvider.provide(slot: 11, from: store, incremental: false, to: active), 1_000_000)
        XCTAssertNil(active.commit())
        XCTAssertEqual(active.committed, [AreaCode("877")!.shards[3]])
    }

    func testProviderWithNoFileProvidesNothing() throws {
        let directory = FakeDirectory()
        directory.begin(incremental: false)
        XCTAssertEqual(try ShardProvider.provide(slot: 0, from: makeTemporaryStore(), incremental: false, to: directory), 0)
        XCTAssertNil(directory.commit())
        XCTAssertEqual(directory.count, 0)
    }

    func testProviderLeavesIOSUntouchedWhenTheFileIsUnreadable() throws {
        let store = makeTemporaryStore()
        try Data("not json".utf8).write(to: store.directory.appendingPathComponent("config.json"))

        let directory = FakeDirectory()
        directory.begin(incremental: false)
        ShardWriter.write(shardA, incremental: false, to: directory)
        XCTAssertNil(directory.commit())

        // The read fails before anything is removed, so the old list survives.
        directory.begin(incremental: true)
        XCTAssertThrowsError(try ShardProvider.provide(slot: 0, from: store, incremental: true, to: directory))
        XCTAssertEqual(directory.committed, [shardA])
    }

    // MARK: The simulated iOS really is strict

    func testFakeDirectoryRejectsWhatIOSRejects() {
        let outOfOrder = FakeDirectory()
        outOfOrder.begin(incremental: false)
        outOfOrder.add(5); outOfOrder.add(4)
        XCTAssertEqual(outOfOrder.commit(), "entriesOutOfOrder")

        let repeated = FakeDirectory()
        repeated.begin(incremental: false)
        repeated.add(5); repeated.add(5)
        XCTAssertEqual(repeated.commit(), "entriesOutOfOrder")

        let duplicate = FakeDirectory()
        duplicate.begin(incremental: false)
        duplicate.add(5)
        XCTAssertNil(duplicate.commit())
        duplicate.begin(incremental: true)
        duplicate.add(5) // already stored, and not removed first
        XCTAssertEqual(duplicate.commit(), "duplicateEntries")
        XCTAssertEqual(duplicate.count, 1, "a rejected request changes nothing")

        let removal = FakeDirectory()
        removal.begin(incremental: false)
        removal.removeAll()
        XCTAssertEqual(removal.commit(), "removal in a full request")

        let tooMany = FakeDirectory()
        tooMany.entryLimit = 10
        tooMany.begin(incremental: false)
        ShardWriter.write(NumberRange(lower: 100, count: 11), incremental: false, to: tooMany)
        XCTAssertEqual(tooMany.commit(), "maximumEntriesExceeded")
        XCTAssertEqual(tooMany.count, 0)
    }
}
