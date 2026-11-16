import Foundation

/// Whether the user has turned an extension on in Settings.
enum ExtensionStatus: Sendable {
    case unknown, enabled, disabled
}

/// Why iOS refused or failed to reload an extension.
enum ReloadError: Error, Equatable, Sendable {
    /// The extension is switched off in Settings.
    case disabled
    /// iOS is already loading this extension; try again shortly.
    case busy
    /// iOS stopped the extension before it finished (time or memory).
    case interrupted
    /// iOS won't store this many numbers for one extension.
    case tooManyEntries
    /// iOS never answered.
    case timedOut
    case other(String)

    var message: String {
        switch self {
        case .disabled: return "The switch is off in Settings."
        case .busy: return "iOS is still busy loading. Try again in a moment."
        case .interrupted: return "iOS interrupted the loading."
        case .tooManyEntries: return "iOS refused the list as too large."
        case .timedOut: return "iOS didn't respond."
        case .other(let text): return text
        }
    }
}

/// The part of CallKit the app depends on, so the sync logic can be tested
/// against a simulated iOS.
protocol CallDirectoryService: Sendable {
    func status(slot: Int) async -> ExtensionStatus
    /// Asks iOS to run the extension for `slot`. Returning without throwing
    /// means iOS stored what the extension provided.
    func reload(slot: Int) async throws
}
