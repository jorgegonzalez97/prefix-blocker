import Foundation
import XCTest

/// What iOS stores for one Call Directory extension, with the rules iOS applies
/// to a request: numbers arrive in strictly ascending order, a number can't be
/// added twice, entries can only be removed in an incremental request, and one
/// extension can't hold more than `entryLimit` numbers. A request that breaks a
/// rule changes nothing.
///
/// Numbers are kept as runs of consecutive values, so millions of them cost
/// almost no memory.
final class FakeDirectory: BlockingEntrySink {
    /// The lowest per-extension limit developers have reported hitting on real devices.
    var entryLimit: Int64 = 1_800_000

    private(set) var committed: [NumberRange] = []
    private var kept: [NumberRange] = []
    private var added: [NumberRange] = []
    private var incremental = false
    private(set) var failure: String?

    var count: Int64 { committed.reduce(0) { $0 + $1.count } }

    func contains(_ number: Int64) -> Bool {
        committed.contains { $0.contains(number) }
    }

    func begin(incremental: Bool) {
        self.incremental = incremental
        kept = incremental ? committed : []
        added = []
        failure = nil
    }

    func removeAll() {
        guard incremental else { return fail("removal in a full request") }
        guard added.isEmpty else { return fail("removal after an addition") }
        kept = []
    }

    func add(_ number: Int64) {
        if let last = added.last {
            guard number > last.upper else { return fail("entriesOutOfOrder") }
            if number == last.upper + 1, !kept.contains(where: { $0.contains(number) }) {
                added[added.count - 1].count += 1
                return
            }
        }
        guard !kept.contains(where: { $0.contains(number) }) else { return fail("duplicateEntries") }
        added.append(NumberRange(lower: number, count: 1))
    }

    /// Ends the request. Returns the reason it was rejected, or `nil` if it was stored.
    func commit() -> String? {
        if failure == nil {
            var merged: [NumberRange] = []
            for run in (kept + added).sorted(by: { $0.lower < $1.lower }) {
                if let last = merged.last, run.lower == last.upper + 1 {
                    merged[merged.count - 1].count += run.count
                } else {
                    merged.append(run)
                }
            }
            if merged.reduce(0, { $0 + $1.count }) > entryLimit {
                fail("maximumEntriesExceeded")
            } else {
                committed = merged
            }
        }
        return failure
    }

    /// iOS discards the entries of an extension that is switched off.
    func wipe() { committed = [] }

    private func fail(_ reason: String) {
        failure = failure ?? reason
    }
}

/// A simulated iPhone: one directory per extension, the switches in Settings,
/// and extensions that run the app's real `ShardProvider` code against the real
/// files on disk.
final class FakeIOS: CallDirectoryService, @unchecked Sendable {
    let store: SharedStore
    let directories: [FakeDirectory]
    private(set) var enabled = Set<Int>()
    /// Successful app-initiated reloads per slot.
    private(set) var reloadCounts: [Int]
    /// Errors to throw from the next reloads of a slot, in order, before reloads work again.
    var scriptedErrors: [Int: [ReloadError]] = [:]
    /// Answer `unknown` to every status query, as the simulator does.
    var statusUnavailable = false
    /// Whether turning a switch on makes iOS load that extension right away.
    /// `false` is the pessimistic case: nothing is blocked until the app reloads.
    var loadsWhenSwitchedOn = true
    /// Run on the main actor around the extension's work, to simulate the user editing while iOS loads.
    var beforeExtensionRuns: (@MainActor (Int) -> Void)?
    var afterExtensionRan: (@MainActor (Int) -> Void)?

    init(store: SharedStore, slotCount: Int = AppConstants.slotCount) {
        self.store = store
        directories = (0..<slotCount).map { _ in FakeDirectory() }
        reloadCounts = Array(repeating: 0, count: slotCount)
    }

    // MARK: CallDirectoryService

    func status(slot: Int) async -> ExtensionStatus {
        if statusUnavailable { return .unknown }
        return enabled.contains(slot) ? .enabled : .disabled
    }

    func reload(slot: Int) async throws {
        guard enabled.contains(slot) else { throw ReloadError.disabled }
        if var queue = scriptedErrors[slot], !queue.isEmpty {
            let error = queue.removeFirst()
            scriptedErrors[slot] = queue
            throw error
        }
        await beforeExtensionRuns?(slot)
        // After its first load, iOS offers an extension incremental requests.
        try runExtension(slot: slot, incremental: true)
        await afterExtensionRan?(slot)
        reloadCounts[slot] += 1
    }

    // MARK: Things iOS and the user do on their own

    /// The user flips a switch on: iOS immediately asks that extension for its complete list.
    func turnOn(_ slots: some Sequence<Int>) {
        for slot in slots where enabled.insert(slot).inserted && loadsWhenSwitchedOn {
            try? runExtension(slot: slot, incremental: false)
        }
    }

    func turnOff(_ slots: some Sequence<Int>) {
        for slot in slots where enabled.remove(slot) != nil {
            directories[slot].wipe()
        }
    }

    /// iOS reloads every enabled extension from scratch (iOS update, restore from backup).
    func systemReloadsEverything() {
        for slot in enabled.sorted() {
            try? runExtension(slot: slot, incremental: false)
        }
    }

    private func runExtension(slot: Int, incremental: Bool) throws {
        let directory = directories[slot]
        directory.begin(incremental: incremental)
        // A throw here is the extension cancelling its request: nothing changes.
        try ShardProvider.provide(slot: slot, from: store, incremental: incremental, to: directory)
        if let failure = directory.commit() {
            throw failure == "maximumEntriesExceeded" ? ReloadError.tooManyEntries : ReloadError.other(failure)
        }
    }

    // MARK: What the phone would do with a call

    func isBlocked(_ number: Int64) -> Bool {
        enabled.contains { directories[$0].contains(number) }
    }

    var blockedCount: Int64 {
        enabled.reduce(0) { $0 + directories[$1].count }
    }
}

/// Deterministic random numbers, so a failing sample can be reproduced.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

extension XCTestCase {
    /// A store in a fresh temporary directory, removed when the test ends.
    func makeTemporaryStore() -> SharedStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrefixBlockerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SharedStore(directory: directory)
    }
}
