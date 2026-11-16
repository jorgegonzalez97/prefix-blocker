import Foundation

/// Where blocking entries go. In an extension this is the CallKit request
/// context; in tests, a fake directory that enforces the same rules as iOS.
protocol BlockingEntrySink {
    /// Drops everything this extension loaded before. Only valid in an incremental request.
    func removeAll()
    /// Adds one number. Numbers must arrive in ascending order.
    func add(_ number: Int64)
}

enum ShardWriter {
    /// Numbers added per autorelease pool, so the extension's memory stays flat
    /// (iOS kills Call Directory extensions that go over about 12 MB).
    static let batchSize: Int64 = 50_000

    /// Hands iOS the complete list for one extension.
    ///
    /// The result is always "exactly `range` is blocked", whatever was loaded
    /// before, so the same code serves every kind of request:
    /// - a full request (first activation, iOS update, restore): iOS has already
    ///   discarded the old entries, so only additions are allowed;
    /// - an incremental request: old entries are still there and are removed first.
    static func write<Sink: BlockingEntrySink>(_ range: NumberRange?, incremental: Bool, to sink: Sink) {
        if incremental { sink.removeAll() }
        guard let range, range.count > 0 else { return }

        let end = range.lower + range.count
        var next = range.lower
        while next < end {
            let batchEnd = min(end, next + batchSize)
            autoreleasepool {
                var number = next
                while number < batchEnd {
                    sink.add(number)
                    number += 1
                }
            }
            next = batchEnd
        }
    }
}

/// What an extension does when iOS runs it. Lives here, away from CallKit, so
/// the tests run the very same code against a simulated iOS.
enum ShardProvider {
    /// Provides the list for `slot` and returns how many numbers it contains.
    ///
    /// Throws before touching `sink` if the configuration can't be read; the
    /// caller then cancels the request and iOS keeps what it already has.
    @discardableResult
    static func provide<Sink: BlockingEntrySink>(slot: Int,
                                                 from store: SharedStore,
                                                 incremental: Bool,
                                                 to sink: Sink) throws -> Int64 {
        let config = try store.loadConfig()
        let range = config.activeRange(slot: slot)
        ShardWriter.write(range, incremental: incremental, to: sink)
        return range?.count ?? 0
    }
}
