import Foundation
import Observation
import os

private let log = Logger(subsystem: "PrefixBlocker", category: "sync")

/// What one extension is doing, for display.
enum SlotState: Equatable, Sendable {
    /// Nothing assigned and nothing loaded.
    case unused
    /// Has work to do (load or clear) at the next sync.
    case waiting
    case loading
    /// iOS is blocking this extension's numbers.
    case loaded
    /// Assigned, but its switch is off in Settings.
    case needsSwitch
    case failed(ReloadError)
}

/// The one thing the user should know right now.
enum OverallStatus: Equatable {
    case empty
    /// Switches (0-based slots) to turn on in Settings.
    case needsSwitches([Int])
    case loading(done: Int, total: Int)
    case protected
    case failed(String)
    /// Work is queued; a sync will pick it up.
    case pending
    /// There are prefixes, but every one of them is paused.
    case paused
}

/// How one prefix is doing, for its row in the list.
enum PrefixStatus: Equatable {
    /// iOS is blocking all of its numbers.
    case active
    case paused
    /// Switches (0-based slots) of this prefix to turn on in Settings.
    case needsSwitches([Int])
    /// Some of its extensions still have to be loaded.
    case loading(done: Int, total: Int)
    case failed(String)
}

/// App state and the logic that keeps iOS in line with it.
///
/// Each extension is stateless: whenever iOS runs it, it provides exactly the
/// range in its slot of the shared configuration. So keeping iOS up to date is
/// simply: for every slot whose range changed since the last successful reload,
/// ask iOS to reload that extension. A reload that returns without error is the
/// only thing treated as proof that iOS has the numbers.
@MainActor
@Observable
final class BlockerModel {
    private(set) var config = SharedConfig()
    private(set) var confirmed: [Confirmation] = Array(repeating: .loaded(nil), count: AppConstants.slotCount)
    private(set) var slotStates: [SlotState] = Array(repeating: .unused, count: AppConstants.slotCount)
    private(set) var isSyncing = false
    /// Set when the shared files can't be used; nothing can be saved or loaded.
    private(set) var storageError: String?
    /// How long the last successful load of each slot took, in seconds.
    private(set) var loadSeconds: [Double?] = Array(repeating: nil, count: AppConstants.slotCount)

    @ObservationIgnored private let store: SharedStore?
    @ObservationIgnored private let service: any CallDirectoryService
    /// Bumped on every configuration change, to notice changes made while iOS is loading.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored var busyRetryDelay: Duration = .seconds(2)

    static let maxBusyRetries = 10
    static let maxInterruptedRetries = 2

    init(store: SharedStore?, service: any CallDirectoryService) {
        self.service = service
        guard let store else {
            self.store = nil
            storageError = "The App Group \(AppConstants.appGroupIdentifier) isn't available. Check the app's signing and entitlements."
            return
        }
        do {
            config = try store.loadConfig().withSlotsAssigned()
            confirmed = try store.loadConfirmed()
            self.store = store
        } catch {
            self.store = nil
            storageError = "Couldn't read the saved prefixes: \(error.localizedDescription)"
        }
        refreshIdleStates()
    }

    // MARK: Editing

    /// Blocks `prefix`. Returns a message if it couldn't be added.
    @discardableResult
    func addPrefix(_ prefix: AreaCode) -> String? {
        guard !config.prefixes.contains(prefix) else { return "\(prefix.digits) is already blocked." }
        guard SlotTable.canAdd(to: config.prefixes) else {
            return "You can block up to \(AppConstants.maxPrefixes) prefixes. Remove one first."
        }
        return update { $0.prefixes.append(prefix) }
    }

    /// Blocks several prefixes at once, skipping the ones already in the list.
    /// Nothing is added if they don't all fit.
    @discardableResult
    func addPrefixes(_ prefixes: [AreaCode]) -> String? {
        var new: [AreaCode] = []
        for prefix in prefixes where !config.prefixes.contains(prefix) && !new.contains(prefix) {
            new.append(prefix)
        }
        guard new.count <= SlotTable.room(after: config.prefixes) else {
            return "You can block up to \(AppConstants.maxPrefixes) prefixes. Remove one first."
        }
        return update { $0.prefixes.append(contentsOf: new) }
    }

    func removePrefix(_ prefix: AreaCode) {
        update { $0.prefixes.removeAll { $0 == prefix } }
    }

    /// Blocks `new` instead of `old`, in the same extensions, so the switches
    /// that are already on keep working. Returns a message if it couldn't be changed.
    @discardableResult
    func replacePrefix(_ old: AreaCode, with new: AreaCode) -> String? {
        guard old != new else { return nil }
        guard let index = config.prefixes.firstIndex(of: old) else { return "\(old.digits) isn't in the list any more." }
        guard !config.prefixes.contains(new) else { return "\(new.digits) is already blocked." }
        return update { config in
            config.prefixes[index] = new
            config.slots = SlotTable.replacing(old, with: new, in: config.slots)
            if config.paused.remove(old) != nil { config.paused.insert(new) }
        }
    }

    /// Stops blocking `prefix` without removing it, or starts again. A paused
    /// prefix keeps its extensions, so resuming needs no new switches.
    func setPaused(_ prefix: AreaCode, _ paused: Bool) {
        guard config.prefixes.contains(prefix) else { return }
        update { config in
            if paused { config.paused.insert(prefix) } else { config.paused.remove(prefix) }
        }
    }

    func isPaused(_ prefix: AreaCode) -> Bool { config.paused.contains(prefix) }

    /// Makes the next sync reload every extension, whatever the app believes is loaded.
    func forgetConfirmations() {
        confirmed = Array(repeating: .unknown, count: AppConstants.slotCount)
        saveConfirmed()
        refreshIdleStates()
        if isSyncing { needsAnotherPass = true }
    }

    @discardableResult
    private func update(_ change: (inout SharedConfig) -> Void) -> String? {
        guard let store else { return storageError }
        var next = config
        change(&next)
        next = next.withSlotsAssigned()
        guard next != config else { return nil }
        do {
            // Saved before anything else: extensions read this file whenever iOS runs them.
            try store.save(next)
        } catch {
            return "Couldn't save: \(error.localizedDescription)"
        }
        config = next
        revision += 1
        refreshIdleStates()
        if isSyncing { needsAnotherPass = true }
        return nil
    }

    // MARK: Derived

    /// Numbers iOS is confirmed to be blocking.
    var loadedNumberCount: Int64 {
        zip(config.activeSlots, slotStates).reduce(0) { total, pair in
            pair.1 == .loaded ? total + (pair.0?.count ?? 0) : total
        }
    }

    /// Numbers that will be blocked once everything is loaded.
    var totalNumberCount: Int64 {
        config.activeSlots.reduce(0) { $0 + ($1?.count ?? 0) }
    }

    /// Prefixes that aren't paused.
    var activePrefixes: [AreaCode] {
        config.prefixes.filter { !config.paused.contains($0) }
    }

    var slotsNeedingSwitch: [Int] {
        slotStates.indices.filter { slotStates[$0] == .needsSwitch }
    }

    /// Slots (extensions) reserved for `prefix`, in ascending order.
    func slots(of prefix: AreaCode) -> [Int] {
        SlotTable.slots(of: prefix, in: config.slots)
    }

    /// Slots assigned to `prefix` and how many of them iOS has loaded.
    func progress(of prefix: AreaCode) -> (loaded: Int, total: Int) {
        let slots = slots(of: prefix)
        return (slots.filter { slotStates[$0] == .loaded }.count, slots.count)
    }

    func status(of prefix: AreaCode) -> PrefixStatus {
        if config.paused.contains(prefix) { return .paused }
        let slots = slots(of: prefix)
        for slot in slots {
            if case .failed(let error) = slotStates[slot] { return .failed(error.message) }
        }
        let off = slots.filter { slotStates[$0] == .needsSwitch }
        if !off.isEmpty { return .needsSwitches(off) }
        let done = slots.filter { slotStates[$0] == .loaded }.count
        if !slots.isEmpty, done == slots.count { return .active }
        return .loading(done: done, total: slots.count)
    }

    /// Every extension that failed to load, with the reason.
    var failures: [(slot: Int, message: String)] {
        slotStates.indices.compactMap { slot in
            if case .failed(let error) = slotStates[slot] { return (slot, error.message) }
            return nil
        }
    }

    /// What iOS does with a call from `number` (CallKit format), as far as the app knows.
    func verdict(for number: Int64) -> NumberVerdict {
        guard let prefix = config.prefixes.first(where: { $0.contains(number) }) else { return .allowed }
        if config.paused.contains(prefix) { return .paused(prefix) }
        let loaded = config.slots.indices.contains { slot in
            slotStates[slot] == .loaded && (config.slots[slot]?.contains(number) ?? false)
        }
        return loaded ? .blocked(prefix) : .notLoadedYet(prefix)
    }

    var overallStatus: OverallStatus {
        let wanted = config.activeSlots
        let assigned = wanted.indices.filter { wanted[$0] != nil }
        let working = slotStates.contains { $0 == .loading || $0 == .waiting }

        if isSyncing && working {
            let done = assigned.filter { slotStates[$0] == .loaded }.count
            return .loading(done: done, total: assigned.count)
        }
        if assigned.isEmpty && !working {
            let failed = slotStates.contains { if case .failed = $0 { true } else { false } }
            if !failed { return config.prefixes.isEmpty ? .empty : .paused }
        }
        let switches = slotsNeedingSwitch
        if !switches.isEmpty { return .needsSwitches(switches) }
        for state in slotStates {
            if case .failed(let error) = state { return .failed(error.message) }
        }
        if working { return .pending }
        return .protected
    }

    // MARK: Sync

    /// Brings iOS in line with the configuration. Safe to call at any time; a
    /// call made while a sync is running makes that sync take one more pass.
    func sync() async {
        guard store != nil else { return }
        if isSyncing {
            needsAnotherPass = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        repeat {
            needsAnotherPass = false
            for slot in 0..<AppConstants.slotCount {
                await syncSlot(slot)
            }
        } while needsAnotherPass
    }

    private func syncSlot(_ slot: Int) async {
        let status = await service.status(slot: slot)

        if status == .disabled {
            // iOS ignores a switched-off extension and asks it for its complete
            // list when it is switched back on, so earlier loads don't count.
            setConfirmed(slot, .loaded(nil))
            slotStates[slot] = config.activeRange(slot: slot) == nil ? .unused : .needsSwitch
            return
        }

        var busyRetries = 0
        var interruptedRetries = 0

        while true {
            // Read again on every attempt: the user may have edited the list meanwhile.
            let want = config.activeRange(slot: slot)
            if confirmed[slot] == .loaded(want) {
                slotStates[slot] = want == nil ? .unused : .loaded
                return
            }

            slotStates[slot] = .loading
            let startRevision = revision
            let started = ContinuousClock.now

            do {
                try await service.reload(slot: slot)

                guard revision == startRevision else {
                    // The list changed while iOS was loading, so it's unclear which
                    // version the extension read. Load again.
                    setConfirmed(slot, .unknown)
                    continue
                }
                let elapsed = ContinuousClock.now - started
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                loadSeconds[slot] = seconds
                setConfirmed(slot, .loaded(want))
                slotStates[slot] = want == nil ? .unused : .loaded
                log.info("Slot \(AppConstants.slotLabel(slot), privacy: .public): \(want?.count ?? 0) numbers in \(seconds, format: .fixed(precision: 2)) s")
                return
            } catch {
                let failure = (error as? ReloadError) ?? .other(error.localizedDescription)
                log.error("Slot \(AppConstants.slotLabel(slot), privacy: .public) failed: \(failure.message, privacy: .public)")

                switch failure {
                case .disabled:
                    setConfirmed(slot, .loaded(nil))
                    slotStates[slot] = want == nil ? .unused : .needsSwitch
                    return
                case .busy where busyRetries < Self.maxBusyRetries:
                    busyRetries += 1
                    try? await Task.sleep(for: busyRetryDelay)
                case .interrupted where interruptedRetries < Self.maxInterruptedRetries:
                    interruptedRetries += 1
                default:
                    // What iOS holds for this extension is no longer certain.
                    setConfirmed(slot, .unknown)
                    slotStates[slot] = .failed(failure)
                    return
                }
            }
        }
    }

    private func setConfirmed(_ slot: Int, _ value: Confirmation) {
        guard confirmed[slot] != value else { return }
        confirmed[slot] = value
        saveConfirmed()
    }

    private func saveConfirmed() {
        do {
            try store?.save(confirmed: confirmed)
        } catch {
            // Not fatal: at worst the next launch reloads an extension it didn't need to.
            log.error("Couldn't save confirmations: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Recomputes the state of every slot that isn't being loaded right now.
    private func refreshIdleStates() {
        let wanted = config.activeSlots
        for slot in slotStates.indices where slotStates[slot] != .loading {
            let want = wanted[slot]
            if confirmed[slot] == .loaded(want) {
                slotStates[slot] = want == nil ? .unused : .loaded
            } else if want != nil, slotStates[slot] == .needsSwitch {
                continue
            } else {
                slotStates[slot] = .waiting
            }
        }
    }
}
