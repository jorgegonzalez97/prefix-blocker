import XCTest

/// End-to-end: the app's model on one side, a simulated iPhone on the other,
/// the real files in between. "Blocked" always means what the simulated phone
/// would do with an incoming call, not what the app believes.
@MainActor
final class BlockerModelTests: XCTestCase {
    private let c844 = AreaCode("844")!
    private let c877 = AreaCode("877")!

    private func makeWorld(switchesOn: Range<Int> = 0..<AppConstants.slotCount) -> (BlockerModel, FakeIOS) {
        let store = makeTemporaryStore()
        let ios = FakeIOS(store: store)
        ios.turnOn(switchesOn)
        let model = BlockerModel(store: store, service: ios)
        model.busyRetryDelay = .milliseconds(1)
        return (model, ios)
    }

    // MARK: Blocking

    func testBlocksExactlyTheChosenPrefixes() async {
        let (model, ios) = makeWorld()
        XCTAssertEqual(model.overallStatus, .empty)

        XCTAssertNil(model.addPrefix(c844))
        XCTAssertNil(model.addPrefix(c877))
        await model.sync()

        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 16_000_000)
        XCTAssertEqual(model.loadedNumberCount, 16_000_000)
        XCTAssertEqual(model.totalNumberCount, 16_000_000)

        // Edges of each prefix.
        for npa: Int64 in [844, 877] {
            let base = 1_000_000_0000 + npa * 1_000_0000
            XCTAssertTrue(ios.isBlocked(base + 200_0000), "\(npa) first number")
            XCTAssertTrue(ios.isBlocked(base + 555_0123))
            XCTAssertTrue(ios.isBlocked(base + 999_9999), "\(npa) last number")
            XCTAssertFalse(ios.isBlocked(base + 199_9999), "nonexistent exchange")
            XCTAssertFalse(ios.isBlocked(base + 1000_0000), "next prefix")
            XCTAssertFalse(ios.isBlocked(base - 1), "previous prefix")
        }
        XCTAssertFalse(ios.isBlocked(1_212_555_0123))
        XCTAssertFalse(ios.isBlocked(1_800_555_0123))
        XCTAssertFalse(ios.isBlocked(44_844_555_0123), "same digits, another country")

        // A large random sample across all of +1 agrees with the definition of the prefixes.
        var generator = SeededGenerator(seed: 844_877)
        for _ in 0..<200_000 {
            let number = Int64.random(in: 1_200_000_0000...1_999_999_9999, using: &generator)
            let expected = c844.contains(number) || c877.contains(number)
            XCTAssertEqual(ios.isBlocked(number), expected, "\(number)")
        }

        // No extension holds more than iOS accepts, and none is used needlessly.
        for (slot, directory) in ios.directories.enumerated() {
            XCTAssertEqual(directory.count, slot < 16 ? 1_000_000 : 0, "slot \(slot)")
            XCTAssertEqual(ios.reloadCounts[slot], slot < 16 ? 1 : 0, "slot \(slot)")
        }
    }

    func testEightPrefixesUseAllSwitchesAndANinthIsRefused() async {
        let (model, ios) = makeWorld()
        for digits in ["844", "877", "855", "866", "800", "833", "888", "900"] {
            XCTAssertNil(model.addPrefix(AreaCode(digits)!))
        }
        XCTAssertNotNil(model.addPrefix(AreaCode("212")!))
        XCTAssertNotNil(model.addPrefix(c844), "already blocked")
        XCTAssertEqual(model.config.prefixes.count, 8)

        await model.sync()
        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 64_000_000)
        XCTAssertTrue(ios.isBlocked(1_900_555_0123))
        XCTAssertFalse(ios.isBlocked(1_212_555_0123))
        XCTAssertTrue(ios.directories.allSatisfy { $0.count == 1_000_000 })
    }

    func testAllTollFreePrefixesInOneGo() async {
        let (model, ios) = makeWorld()
        model.addPrefix(c844)
        XCTAssertNil(model.addPrefixes(AreaCode.tollFree))
        XCTAssertEqual(model.config.prefixes.count, 7, "844 isn't added twice")
        XCTAssertEqual(model.config.prefixes.first, c844)

        // Two more don't fit next to seven, and then nothing is added at all.
        XCTAssertNotNil(model.addPrefixes([AreaCode("900")!, AreaCode("212")!]))
        XCTAssertEqual(model.config.prefixes.count, 7)

        await model.sync()
        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 56_000_000)
        for prefix in AreaCode.tollFree {
            XCTAssertTrue(ios.isBlocked(prefix.range.lower), prefix.digits)
            XCTAssertEqual(model.status(of: prefix), .active)
        }
    }

    // MARK: Switches in Settings

    func testAsksForSwitchesThenLoadsOnceTheyAreOn() async {
        let (model, ios) = makeWorld(switchesOn: 0..<0)
        model.addPrefix(c844)
        await model.sync()

        XCTAssertEqual(model.overallStatus, .needsSwitches(Array(0..<8)))
        XCTAssertEqual(ios.blockedCount, 0)
        XCTAssertEqual(model.loadedNumberCount, 0)
        let progress = model.progress(of: c844)
        XCTAssertEqual(progress.loaded, 0)
        XCTAssertEqual(progress.total, 8)

        // Turning a switch on makes iOS load that extension by itself, at once and completely.
        ios.turnOn(0..<8)
        XCTAssertEqual(ios.blockedCount, 8_000_000)

        // Back in the app, a sync confirms it.
        await model.sync()
        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 8_000_000)
        XCTAssertEqual(model.loadedNumberCount, 8_000_000)
    }

    func testSomeSwitchesOn() async {
        let (model, ios) = makeWorld(switchesOn: 0..<3)
        model.addPrefix(c844)
        await model.sync()

        XCTAssertEqual(model.overallStatus, .needsSwitches([3, 4, 5, 6, 7]))
        XCTAssertEqual(ios.blockedCount, 3_000_000)
        XCTAssertEqual(model.loadedNumberCount, 3_000_000)
        XCTAssertEqual(model.progress(of: c844).loaded, 3)
        XCTAssertTrue(ios.isBlocked(1_844_200_0000))
        XCTAssertFalse(ios.isBlocked(1_844_999_9999))
    }

    func testSwitchTurnedOffLaterIsNoticedAndRecovered() async {
        let (model, ios) = makeWorld()
        model.addPrefix(c844)
        await model.sync()
        XCTAssertEqual(model.overallStatus, .protected)

        ios.turnOff([2])
        XCTAssertEqual(ios.blockedCount, 7_000_000)
        await model.sync()
        XCTAssertEqual(model.overallStatus, .needsSwitches([2]))
        XCTAssertEqual(model.loadedNumberCount, 7_000_000)

        ios.turnOn([2])
        await model.sync()
        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 8_000_000)
    }

    func testSwitchTurnedBackOnIsReloadedEvenIfIOSDoesNotDoIt() async {
        let (model, ios) = makeWorld()
        model.addPrefix(c844)
        await model.sync()

        // The app sees the switch off, then on again, and iOS loaded nothing by itself.
        ios.loadsWhenSwitchedOn = false
        ios.turnOff([5])
        await model.sync()
        ios.turnOn([5])
        XCTAssertEqual(ios.blockedCount, 7_000_000)

        await model.sync()
        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 8_000_000, "an earlier load must not count once the switch was off")
    }

    func testSwitchesTurnedOnWithoutIOSLoadingAnything() async {
        let (model, ios) = makeWorld(switchesOn: 0..<0)
        ios.loadsWhenSwitchedOn = false
        model.addPrefix(c844)
        await model.sync()
        ios.turnOn(0..<8)
        XCTAssertEqual(ios.blockedCount, 0)

        await model.sync()
        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 8_000_000)
    }

    // MARK: Editing

    func testRemovingAPrefixUnblocksItAndLeavesTheOtherAlone() async {
        let (model, ios) = makeWorld()
        model.addPrefix(c844)
        model.addPrefix(c877)
        await model.sync()

        model.removePrefix(c844)
        await model.sync()

        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 8_000_000)
        XCTAssertFalse(ios.isBlocked(1_844_555_0123))
        XCTAssertTrue(ios.isBlocked(1_877_555_0123))
        // 844's extensions were reloaded (to empty); 877's were not touched again.
        XCTAssertEqual(Array(ios.reloadCounts[0..<8]), Array(repeating: 2, count: 8))
        XCTAssertEqual(Array(ios.reloadCounts[8..<16]), Array(repeating: 1, count: 8))

        model.removePrefix(c877)
        await model.sync()
        XCTAssertEqual(model.overallStatus, .empty)
        XCTAssertEqual(ios.blockedCount, 0)
    }

    func testChangingAPrefixReusesItsSwitches() async {
        // Only the first 16 switches are on: a changed prefix must not need any others.
        let (model, ios) = makeWorld(switchesOn: 0..<16)
        let c855 = AreaCode("855")!
        model.addPrefix(c844)
        model.addPrefix(c877)
        await model.sync()

        XCTAssertNil(model.replacePrefix(c877, with: c855))
        XCTAssertEqual(model.config.prefixes, [c844, c855], "keeps its place in the list")
        XCTAssertEqual(model.slots(of: c855), Array(8..<16))
        await model.sync()

        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 16_000_000)
        XCTAssertFalse(ios.isBlocked(1_877_555_0123))
        XCTAssertTrue(ios.isBlocked(1_855_200_0000))
        XCTAssertTrue(ios.isBlocked(1_855_999_9999))
        XCTAssertTrue(ios.isBlocked(1_844_555_0123))
        XCTAssertEqual(Array(ios.reloadCounts[0..<8]), Array(repeating: 1, count: 8), "844 is left alone")
        XCTAssertEqual(Array(ios.reloadCounts[8..<16]), Array(repeating: 2, count: 8))

        // Changes that make no sense are refused and change nothing.
        XCTAssertNotNil(model.replacePrefix(c855, with: c844), "already in the list")
        XCTAssertNotNil(model.replacePrefix(c877, with: AreaCode("888")!), "877 is gone")
        XCTAssertNil(model.replacePrefix(c855, with: c855))
        XCTAssertEqual(model.config.prefixes, [c844, c855])
    }

    func testPausingUnblocksAndResumingBlocksAgainInTheSameSwitches() async {
        let (model, ios) = makeWorld(switchesOn: 0..<16)
        model.addPrefix(c844)
        model.addPrefix(c877)
        await model.sync()

        model.setPaused(c844, true)
        XCTAssertEqual(model.status(of: c844), .paused)
        await model.sync()

        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 8_000_000)
        XCTAssertFalse(ios.isBlocked(1_844_555_0123))
        XCTAssertTrue(ios.isBlocked(1_877_555_0123))
        XCTAssertEqual(model.totalNumberCount, 8_000_000)
        XCTAssertEqual(model.activePrefixes, [c877])
        XCTAssertEqual(model.verdict(for: 1_844_555_0123), .paused(c844))
        XCTAssertEqual(model.verdict(for: 1_877_555_0123), .blocked(c877))
        XCTAssertEqual(model.verdict(for: 1_212_555_0123), .allowed)

        // A prefix added meanwhile doesn't take the paused one's switches.
        XCTAssertEqual(model.slots(of: c844), Array(0..<8))

        model.setPaused(c844, false)
        await model.sync()
        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(model.status(of: c844), .active)
        XCTAssertEqual(ios.blockedCount, 16_000_000)
        XCTAssertTrue(ios.isBlocked(1_844_555_0123))
        XCTAssertEqual(Array(ios.reloadCounts[8..<16]), Array(repeating: 1, count: 8), "877 is left alone")
    }

    func testPausedPrefixDoesNotAskForItsSwitches() async {
        let (model, ios) = makeWorld(switchesOn: 0..<0)
        model.addPrefix(c844)
        await model.sync()
        XCTAssertEqual(model.status(of: c844), .needsSwitches(Array(0..<8)))

        model.setPaused(c844, true)
        await model.sync()
        XCTAssertEqual(model.overallStatus, .paused)
        XCTAssertEqual(model.status(of: c844), .paused)
        XCTAssertTrue(model.slotsNeedingSwitch.isEmpty)

        // Switched on while paused: iOS runs the extensions, which provide nothing.
        ios.turnOn(0..<8)
        XCTAssertEqual(ios.blockedCount, 0)

        model.setPaused(c844, false)
        await model.sync()
        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 8_000_000)
    }

    func testPauseStateSurvivesRelaunchAndChangingThePrefix() async {
        let (model, ios) = makeWorld()
        let c855 = AreaCode("855")!
        model.addPrefix(c844)
        model.setPaused(c844, true)
        XCTAssertNil(model.replacePrefix(c844, with: c855))
        XCTAssertTrue(model.isPaused(c855))
        await model.sync()
        XCTAssertEqual(ios.blockedCount, 0)

        let relaunched = BlockerModel(store: ios.store, service: ios)
        XCTAssertEqual(relaunched.status(of: c855), .paused)
        XCTAssertEqual(relaunched.overallStatus, .paused)

        relaunched.removePrefix(c855)
        XCTAssertTrue(relaunched.config.paused.isEmpty)
        XCTAssertEqual(relaunched.overallStatus, .empty)
    }

    func testVerdictOnlySaysBlockedOnceIOSHasTheNumber() async {
        let (model, ios) = makeWorld(switchesOn: 0..<3)
        model.addPrefix(c844)
        XCTAssertEqual(model.verdict(for: 1_844_200_0000), .notLoadedYet(c844))
        await model.sync()

        XCTAssertEqual(model.verdict(for: 1_844_200_0000), .blocked(c844))
        XCTAssertEqual(model.verdict(for: 1_844_999_9999), .notLoadedYet(c844), "its switch is still off")
        XCTAssertFalse(ios.isBlocked(1_844_999_9999))
    }

    func testAddingAPrefixDoesNotReloadTheExistingOne() async {
        let (model, ios) = makeWorld()
        model.addPrefix(c844)
        await model.sync()
        model.addPrefix(c877)
        await model.sync()

        XCTAssertEqual(ios.blockedCount, 16_000_000)
        XCTAssertEqual(ios.reloadCounts.reduce(0, +), 16)
    }

    func testEditWhileIOSIsLoadingIsNeverMistakenForLoaded() async {
        let (model, ios) = makeWorld()
        model.addPrefix(c844)

        // While iOS runs the first extension, the user removes the prefix (so the
        // extension reads an empty slot) and adds it back before iOS answers.
        let c844 = c844
        var edits = 0
        ios.beforeExtensionRuns = { slot in
            if slot == 0, edits == 0 { model.removePrefix(c844) }
        }
        ios.afterExtensionRan = { slot in
            if slot == 0, edits == 0 {
                edits += 1
                model.addPrefix(c844)
            }
        }
        await model.sync()

        XCTAssertEqual(edits, 1)
        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 8_000_000, "slot 0 must have been loaded again after the edit")
        XCTAssertTrue(ios.isBlocked(1_844_200_0000))
    }

    func testSyncRequestedDuringASyncStillAppliesTheChange() async {
        let (model, ios) = makeWorld()
        model.addPrefix(c844)

        let c877 = c877
        var requested = false
        ios.afterExtensionRan = { slot in
            guard slot == 7, !requested else { return }
            requested = true
            model.addPrefix(c877)
            Task { await model.sync() } // what the UI does after an edit
        }
        await model.sync()

        XCTAssertTrue(requested)
        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 16_000_000)
    }

    // MARK: Errors

    func testBusyAndInterruptedReloadsAreRetried() async {
        let (model, ios) = makeWorld()
        ios.scriptedErrors = [0: [.busy, .busy, .busy], 1: [.interrupted, .interrupted]]
        model.addPrefix(c844)
        await model.sync()

        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 8_000_000)
    }

    func testPersistentFailureIsReportedThenRecovers() async {
        let (model, ios) = makeWorld()
        ios.scriptedErrors = [4: [.interrupted, .interrupted, .interrupted]]
        model.addPrefix(c844)
        await model.sync()

        XCTAssertEqual(model.slotStates[4], .failed(.interrupted))
        XCTAssertEqual(model.overallStatus, .failed(ReloadError.interrupted.message))
        XCTAssertEqual(ios.blockedCount, 7_000_000)
        XCTAssertEqual(model.loadedNumberCount, 7_000_000, "the app must not claim the failed million")

        await model.sync() // "Try Again"
        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 8_000_000)
    }

    func testOtherErrorsAreReportedWithoutRetryingForever() async {
        let (model, ios) = makeWorld()
        ios.scriptedErrors = [0: [.tooManyEntries], 1: [.timedOut], 2: [.other("boom")]]
        model.addPrefix(c844)
        await model.sync()

        XCTAssertEqual(model.slotStates[0], .failed(.tooManyEntries))
        XCTAssertEqual(model.slotStates[1], .failed(.timedOut))
        XCTAssertEqual(model.slotStates[2], .failed(.other("boom")))
        XCTAssertEqual(model.loadedNumberCount, 5_000_000)
        XCTAssertEqual(ios.blockedCount, 5_000_000)
    }

    func testIOSRefusingAnOversizedListIsReported() async {
        let (model, ios) = makeWorld()
        ios.directories[0].entryLimit = 999_999
        model.addPrefix(c844)
        await model.sync()

        XCTAssertEqual(model.slotStates[0], .failed(.tooManyEntries))
        XCTAssertEqual(ios.blockedCount, 7_000_000)
    }

    func testStatusUnavailableStillLoads() async {
        let (model, ios) = makeWorld()
        ios.statusUnavailable = true
        model.addPrefix(c844)
        await model.sync()

        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 8_000_000)
    }

    func testDisabledReportedByReloadAsksForTheSwitch() async {
        let (model, ios) = makeWorld(switchesOn: 0..<0)
        ios.statusUnavailable = true
        model.addPrefix(c844)
        await model.sync()

        XCTAssertEqual(model.overallStatus, .needsSwitches(Array(0..<8)))
    }

    // MARK: Things that happen without the app

    func testIOSReloadingOnItsOwnKeepsFullProtection() async {
        let (model, ios) = makeWorld()
        model.addPrefix(c844)
        model.addPrefix(c877)
        await model.sync()

        ios.systemReloadsEverything() // iOS update or restore, app not running
        XCTAssertEqual(ios.blockedCount, 16_000_000)
        XCTAssertTrue(ios.isBlocked(1_877_999_9999))
    }

    func testSwitchesTurnedOnBeforeTheAppEverSyncs() async {
        // The user adds a prefix, goes straight to Settings and never returns to the app.
        let (model, ios) = makeWorld(switchesOn: 0..<0)
        model.addPrefix(c844)
        ios.turnOn(0..<8)
        XCTAssertEqual(ios.blockedCount, 8_000_000)
    }

    func testStateSurvivesRelaunchWithoutReloading() async {
        let (model, ios) = makeWorld()
        model.addPrefix(c844)
        model.addPrefix(c877)
        await model.sync()
        let reloads = ios.reloadCounts

        let relaunched = BlockerModel(store: ios.store, service: ios)
        XCTAssertEqual(relaunched.config.prefixes, [c844, c877])
        XCTAssertEqual(relaunched.overallStatus, .protected, "known before any sync")
        await relaunched.sync()
        XCTAssertEqual(relaunched.overallStatus, .protected)
        XCTAssertEqual(ios.reloadCounts, reloads, "nothing changed, so nothing is reloaded")
    }

    func testUpgradeFrom32ExtensionsKeepsEverythingWithoutReloading() async throws {
        // What version 1.0 left behind: three prefixes in 32 slots, all confirmed.
        let store = makeTemporaryStore()
        let ios = FakeIOS(store: store)
        ios.turnOn(0..<24)
        let prefixes = ["844", "877", "855"].map { AreaCode($0)! }
        let slots = SlotTable.assign(prefixes: prefixes, current: [], slotCount: 32)
        let slotJSON = slots.map { $0.map { #"{"lower":\#($0.lower),"count":\#($0.count)}"# } ?? "null" }.joined(separator: ",")
        try Data(#"{"prefixes":["844","877","855"],"slots":[\#(slotJSON)]}"#.utf8)
            .write(to: store.directory.appendingPathComponent("config.json"))
        try JSONEncoder().encode(slots.map(Confirmation.loaded))
            .write(to: store.directory.appendingPathComponent("confirmed.json"))
        ios.systemReloadsEverything()
        XCTAssertEqual(ios.blockedCount, 24_000_000)

        let model = BlockerModel(store: store, service: ios)
        XCTAssertNil(model.storageError)
        XCTAssertEqual(model.config.prefixes, prefixes)
        XCTAssertEqual(model.config.slots.count, 64)
        XCTAssertEqual(Array(model.config.slots[0..<32]), slots, "nothing moved")
        XCTAssertEqual(model.overallStatus, .protected, "known before any sync")

        await model.sync()
        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.reloadCounts.reduce(0, +), 0, "nothing changed, so nothing is reloaded")
        XCTAssertEqual(ios.blockedCount, 24_000_000)

        // A fourth and fifth prefix go to the next switches, including the new ones.
        model.addPrefix(AreaCode("866")!)
        model.addPrefix(AreaCode("888")!)
        XCTAssertEqual(model.slots(of: AreaCode("866")!), Array(24..<32))
        XCTAssertEqual(model.slots(of: AreaCode("888")!), Array(32..<40))
    }

    func testReloadEverythingRebuildsTheSameList() async {
        let (model, ios) = makeWorld()
        model.addPrefix(c844)
        await model.sync()

        model.forgetConfirmations()
        XCTAssertEqual(model.loadedNumberCount, 0)
        await model.sync()

        XCTAssertEqual(model.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 8_000_000)
        XCTAssertEqual(Array(ios.reloadCounts[0..<8]), Array(repeating: 2, count: 8))
    }

    func testLostConfirmationFileOnlyCostsAReload() async throws {
        let (model, ios) = makeWorld()
        model.addPrefix(c844)
        await model.sync()

        try FileManager.default.removeItem(at: ios.store.directory.appendingPathComponent("confirmed.json"))
        let relaunched = BlockerModel(store: ios.store, service: ios)
        await relaunched.sync()

        XCTAssertEqual(relaunched.overallStatus, .protected)
        XCTAssertEqual(ios.blockedCount, 8_000_000)
    }

    // MARK: Storage problems

    func testMissingAppGroupIsReportedAndNothingIsAttempted() async {
        let ios = FakeIOS(store: makeTemporaryStore())
        let model = BlockerModel(store: nil, service: ios)

        XCTAssertNotNil(model.storageError)
        XCTAssertNotNil(model.addPrefix(c844))
        XCTAssertTrue(model.config.prefixes.isEmpty)
        await model.sync()
        XCTAssertEqual(ios.reloadCounts.reduce(0, +), 0)
    }

    func testUnreadableConfigNeverWipesWhatIOSHas() async throws {
        let (model, ios) = makeWorld()
        model.addPrefix(c844)
        await model.sync()

        try Data("garbage".utf8).write(to: ios.store.directory.appendingPathComponent("config.json"))
        ios.systemReloadsEverything() // every extension cancels its request
        XCTAssertEqual(ios.blockedCount, 8_000_000)

        // The app says so instead of showing an empty list and syncing it.
        let relaunched = BlockerModel(store: ios.store, service: ios)
        XCTAssertNotNil(relaunched.storageError)
        await relaunched.sync()
        XCTAssertEqual(ios.blockedCount, 8_000_000)
    }
}
