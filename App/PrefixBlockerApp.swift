import SwiftUI
import UIKit

@main
struct PrefixBlockerApp: App {
    @State private var model = AppEnvironment.makeModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}

@MainActor
enum AppEnvironment {
    static func makeModel() -> BlockerModel {
        #if DEBUG
        if let demo = DemoCallDirectoryService.fromLaunchArguments() {
            return demo.makeModel()
        }
        #endif
        return BlockerModel(store: SharedStore.appGroup(), service: LiveCallDirectoryService())
    }

    #if DEBUG
    /// Screen to open at launch, for screenshots: `-demoScreen add|edit|detail|check|switches`.
    static var demoScreen: String? { UserDefaults.standard.string(forKey: "demoScreen") }
    #endif

    /// Syncs with the screen kept awake and, if the user leaves the app, a few
    /// extra seconds from iOS to finish the extension being loaded.
    static func sync(_ model: BlockerModel) async {
        guard !model.isSyncing else {
            await model.sync() // only queues another pass
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        let background = BackgroundActivity()
        background.begin()
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            background.end()
        }
        await model.sync()
    }
}

@MainActor
private final class BackgroundActivity {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "CallDirectorySync") { [weak self] in
            // iOS calls the expiration handler on the main thread.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

#if DEBUG
/// A pretend iOS for the simulator, where there is no phone to block calls on.
/// Launch with `-demo on`, `-demo off`, `-demo half` or `-demo fail`, optionally
/// with `-demoPrefixes 844,877`, `-demoPaused 877` and `-demoDelay 2000` (ms per
/// switch), to see the app in each state.
struct DemoCallDirectoryService: CallDirectoryService {
    var enabledSlots: Set<Int>
    var prefixes: [AreaCode]
    var paused: [AreaCode] = []
    /// Slots whose reload always fails.
    var failingSlots: Set<Int> = []
    var reloadDelay: Duration = .milliseconds(350)

    static func fromLaunchArguments() -> DemoCallDirectoryService? {
        let defaults = UserDefaults.standard
        guard let mode = defaults.string(forKey: "demo") else { return nil }
        let all = Set(0..<AppConstants.slotCount)
        let enabled: Set<Int>
        switch mode {
        case "on", "fail": enabled = all
        case "half": enabled = all.filter { $0 < 12 }
        default: enabled = []
        }
        func codes(_ key: String) -> [AreaCode] {
            (defaults.string(forKey: key) ?? "").split(separator: ",").compactMap { AreaCode(String($0)) }
        }
        var service = DemoCallDirectoryService(enabledSlots: enabled, prefixes: codes("demoPrefixes"), paused: codes("demoPaused"))
        if mode == "fail" { service.failingSlots = [4, 5, 13] }
        if defaults.object(forKey: "demoDelay") != nil {
            service.reloadDelay = .milliseconds(defaults.integer(forKey: "demoDelay"))
        }
        return service
    }

    @MainActor
    func makeModel() -> BlockerModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-\(UUID().uuidString)", isDirectory: true)
        let model = BlockerModel(store: SharedStore(directory: directory), service: self)
        for prefix in prefixes { model.addPrefix(prefix) }
        for prefix in paused { model.setPaused(prefix, true) }
        return model
    }

    func status(slot: Int) async -> ExtensionStatus {
        enabledSlots.contains(slot) ? .enabled : .disabled
    }

    func reload(slot: Int) async throws {
        guard enabledSlots.contains(slot) else { throw ReloadError.disabled }
        try? await Task.sleep(for: reloadDelay)
        if failingSlots.contains(slot) { throw ReloadError.timedOut }
    }
}
#endif
