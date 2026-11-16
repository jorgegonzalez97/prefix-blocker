import CallKit
import Foundation
import os

private let log = Logger(subsystem: "PrefixBlocker", category: "extension")

/// Call Directory extension. The app embeds 64 copies of it; each one serves
/// one slot of the shared configuration (`ShardSlotIndex` in its Info.plist).
///
/// iOS can't block by pattern: it only takes a list of complete numbers in
/// ascending order. Every time iOS runs this extension it provides the whole
/// list for its slot, so it keeps no state and an iOS-initiated reload (switch
/// turned on, iOS update, restore from backup) is always complete.
final class CallDirectoryHandler: CXCallDirectoryProvider {

    override func beginRequest(with context: CXCallDirectoryExtensionContext) {
        context.delegate = self

        guard let slot = AppConstants.extensionSlotIndex, let store = SharedStore.appGroup() else {
            log.error("Missing slot index or App Group: check the extension's Info.plist and entitlements.")
            context.cancelRequest(withError: HandlerError.misconfigured)
            return
        }

        // `isIncremental` has to be read before any entry is added or removed.
        let incremental = context.isIncremental
        do {
            let count = try ShardProvider.provide(slot: slot,
                                                  from: store,
                                                  incremental: incremental,
                                                  to: ContextSink(context: context))
            log.info("Slot \(slot): provided \(count) numbers (\(incremental ? "incremental" : "full", privacy: .public) request)")
        } catch {
            // Cancelling keeps what iOS already has, which beats emptying the
            // list because the file was unreadable (e.g. before first unlock).
            log.error("Slot \(slot): can't read the configuration: \(error.localizedDescription, privacy: .public)")
            context.cancelRequest(withError: error)
            return
        }
        context.completeRequest()
    }
}

extension CallDirectoryHandler: CXCallDirectoryExtensionContextDelegate {
    func requestFailed(for extensionContext: CXCallDirectoryExtensionContext, withError error: Error) {
        // The app gets the same error from reloadExtension and reacts to it there.
        log.error("Request failed: \(error.localizedDescription, privacy: .public)")
    }
}

private enum HandlerError: Error {
    case misconfigured
}

private struct ContextSink: BlockingEntrySink {
    let context: CXCallDirectoryExtensionContext

    func removeAll() { context.removeAllBlockingEntries() }
    func add(_ number: Int64) { context.addBlockingEntry(withNextSequentialPhoneNumber: number) }
}
