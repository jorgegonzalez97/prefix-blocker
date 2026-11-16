import Foundation

/// What the app knows an extension has loaded into iOS.
enum Confirmation: Codable, Equatable, Sendable {
    /// A reload of this extension succeeded while it was configured with this range (`nil` = empty).
    case loaded(NumberRange?)
    /// Not known; the next sync reloads the extension.
    case unknown
}

/// JSON files in the App Group container shared by the app and its extensions.
///
/// Reads tell "the file doesn't exist" (use the default) apart from "the file
/// can't be read" (an error). An extension must never empty its list because of
/// a read failure, e.g. before the first unlock after a restart.
struct SharedStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The store in the App Group container, or `nil` if the App Group entitlement is missing.
    static func appGroup() -> SharedStore? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier
        ) else { return nil }
        return SharedStore(directory: container.appendingPathComponent("PrefixBlocker", isDirectory: true))
    }

    // MARK: Configuration (written by the app, read by extensions)

    func loadConfig() throws -> SharedConfig {
        var config = try read(SharedConfig.self, from: "config") ?? SharedConfig()
        // A file written by a build with a different number of extensions.
        if config.slots.count != AppConstants.slotCount {
            config = config.withSlotsAssigned()
        }
        return config
    }

    func save(_ config: SharedConfig) throws { try write(config, to: "config") }

    // MARK: Confirmed state (app only)

    /// What each extension is known to have loaded. A fresh install has loaded nothing.
    func loadConfirmed() throws -> [Confirmation] {
        var confirmed = try read([Confirmation].self, from: "confirmed") ?? []
        if confirmed.count < AppConstants.slotCount {
            confirmed += Array(repeating: .loaded(nil), count: AppConstants.slotCount - confirmed.count)
        }
        return Array(confirmed.prefix(AppConstants.slotCount))
    }

    func save(confirmed: [Confirmation]) throws { try write(confirmed, to: "confirmed") }

    // MARK: Private

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    private func read<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
        let fileURL = url(name)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: fileURL))
    }

    private func write<T: Encodable>(_ value: T, to name: String) throws {
        let data = try JSONEncoder().encode(value)
        // Readable after the first unlock, so iOS can reload an extension while the phone is locked.
        try data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
