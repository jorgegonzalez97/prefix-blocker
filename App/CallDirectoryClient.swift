import CallKit
import Foundation

/// The real iOS Call Directory, behind the protocol the sync logic uses.
struct LiveCallDirectoryService: CallDirectoryService {
    /// A million numbers load in seconds; past this, iOS is assumed stuck.
    var reloadTimeout: TimeInterval = 180

    func status(slot: Int) async -> ExtensionStatus {
        await withCheckedContinuation { continuation in
            CXCallDirectoryManager.sharedInstance.getEnabledStatusForExtension(
                withIdentifier: AppConstants.extensionIdentifier(slot: slot)
            ) { status, error in
                guard error == nil else {
                    continuation.resume(returning: .unknown)
                    return
                }
                switch status {
                case .enabled: continuation.resume(returning: .enabled)
                case .disabled: continuation.resume(returning: .disabled)
                default: continuation.resume(returning: .unknown)
                }
            }
        }
    }

    func reload(slot: Int) async throws {
        let timeout = reloadTimeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            CXCallDirectoryManager.sharedInstance.reloadExtension(
                withIdentifier: AppConstants.extensionIdentifier(slot: slot)
            ) { error in
                once.resume(error.map(Self.reloadError))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(.timedOut)
            }
        }
    }

    /// Opens Settings. On iOS 26 and later this doesn't always land on the
    /// Call Blocking & Identification screen, so the app also shows the path.
    static func openSettings() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            CXCallDirectoryManager.sharedInstance.openSettings { _ in continuation.resume() }
        }
    }

    private static func reloadError(_ error: Error) -> ReloadError {
        guard let directoryError = error as? CXErrorCodeCallDirectoryManagerError else {
            return .other(error.localizedDescription)
        }
        switch directoryError.code {
        case .extensionDisabled: return .disabled
        case .currentlyLoading: return .busy
        case .loadingInterrupted: return .interrupted
        case .maximumEntriesExceeded: return .tooManyEntries
        case .noExtensionFound: return .other("iOS can't find this extension. Reinstall the app.")
        case .entriesOutOfOrder, .duplicateEntries, .unexpectedIncrementalRemoval:
            return .other("iOS rejected the list (error \(directoryError.code.rawValue)).")
        default:
            #if targetEnvironment(simulator)
            return .other("Call blocking doesn't work in the simulator. Run the app on an iPhone.")
            #else
            return .other("iOS couldn't load the list (error \(directoryError.code.rawValue)). Try again, or restart the iPhone if it keeps failing.")
            #endif
        }
    }
}

/// Resumes a continuation exactly once, whichever of iOS's answer or the timeout comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ error: ReloadError?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()

        if let error {
            pending?.resume(throwing: error)
        } else {
            pending?.resume()
        }
    }
}
