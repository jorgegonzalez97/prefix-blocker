import Foundation

/// Values shared by the app, every Call Directory extension and the tests.
///
/// Identifiers come from each target's Info.plist, which takes them from the
/// `BASE_BUNDLE_ID` and `APP_GROUP_ID` build settings in `Config/Signing.xcconfig`,
/// so they only have to be changed in one place.
enum AppConstants {
    /// Number of Call Directory extensions embedded in the app. Must match the
    /// number of `ShardNN` targets in `project.yml`.
    static let slotCount = 64

    /// Numbers handed to iOS by one extension.
    ///
    /// iOS has no published limit, but developers consistently report that a
    /// single extension stops accepting entries somewhere around 1.8–2 million.
    /// One million stays well below that and loads in a single request, so an
    /// extension never needs more than one reload to be complete.
    static let shardSize: Int64 = 1_000_000

    /// Extensions a single 3-digit prefix occupies (8,000,000 numbers).
    static var shardsPerPrefix: Int { Int(AreaCode.numbersPerAreaCode / shardSize) }

    /// Prefixes that can be blocked at the same time.
    static var maxPrefixes: Int { slotCount / shardsPerPrefix }

    static let appGroupIdentifier: String =
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
        ?? "group.com.example.prefixblocker"

    private static let extensionIdentifierPrefix: String =
        Bundle.main.object(forInfoDictionaryKey: "ShardExtensionIdentifierPrefix") as? String
        ?? "com.example.prefixblocker.shard"

    /// Slot this extension serves (0-based). `nil` in the app and in tests.
    static let extensionSlotIndex: Int? = {
        switch Bundle.main.object(forInfoDictionaryKey: "ShardSlotIndex") {
        case let text as String: return Int(text)
        case let number as NSNumber: return number.intValue
        default: return nil
        }
    }()

    /// Bundle identifier of the extension that serves `slot`.
    static func extensionIdentifier(slot: Int) -> String {
        extensionIdentifierPrefix + slotLabel(slot)
    }

    /// Two-digit name shown in Settings ("Prefix Blocker 07") and in the app.
    static func slotLabel(_ slot: Int) -> String {
        slot + 1 < 10 ? "0\(slot + 1)" : "\(slot + 1)"
    }
}
