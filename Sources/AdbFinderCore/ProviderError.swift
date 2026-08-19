import AdbKit
import FileProvider
import Foundation

/// Translates our errors into ones Finder understands.
///
/// This lives in the core rather than in the extension so it can be tested: the
/// consequence of a wrong code here is a lost file, and "we compiled it" is not
/// evidence that `.noSuchItem` went to the right place.
///
/// This matters more than it looks. The File Provider API treats the error code
/// as an *instruction*, not a description: `.noSuchItem` means "this is gone,
/// drop it from the replica", `.serverUnreachable` means "hold the change and
/// retry", `.insufficientQuota` means "tell the user the destination is full".
/// Answering "no such item" to a failed upload therefore does not merely
/// mislabel the failure — it discards the file the user was copying.
///
/// So the rule here is: never widen a transient failure into a permanent one,
/// and never claim an item is missing unless the device said exactly that.
public enum ProviderError {
    public static func map(_ error: Error) -> Error {
        if error is CancellationError { return cancelled }
        if let core = error as? CoreError { return map(core) }
        if let adb = error as? AdbError { return map(adb) }

        let ns = error as NSError
        // A cancellation that has already been through a completion handler
        // comes back as an NSError; re-wrapping it as a sync failure would show
        // the user an error for something they asked to stop.
        if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return ns }
        if ns.domain == NSFileProviderErrorDomain { return ns }
        if ns.domain == NSPOSIXErrorDomain { return fromPosix(Int32(ns.code), underlying: error) }
        return provider(.cannotSynchronize, underlying: error)
    }

    /// True when the caller should treat the failure as "already done".
    ///
    /// Deleting something the device has already lost is a success: the user
    /// asked for it to be gone and it is gone. Reporting an error would put a
    /// failure badge on a folder that is in exactly the requested state.
    public static func isAlreadyGone(_ error: Error) -> Bool {
        if let core = error as? CoreError, case .itemNotFound = core { return true }
        if let adb = error as? AdbError { return adb.posixCode == ENOENT }
        let ns = error as NSError
        if ns.domain == NSFileProviderErrorDomain,
           ns.code == NSFileProviderError.noSuchItem.rawValue { return true }
        return false
    }

    // MARK: - Our own errors

    private static func map(_ error: CoreError) -> Error {
        switch error {
        case .itemNotFound, .notADirectory:
            return provider(.noSuchItem, underlying: error)
        case .anchorExpired:
            // Tells the system to re-enumerate from scratch rather than trust a
            // delta we can no longer produce.
            return provider(.syncAnchorExpired, underlying: error)
        case .appGroupUnavailable:
            // A missing entitlement. Nothing will work until it is fixed and no
            // amount of retrying changes that — but it is not an *authentication*
            // problem either, and saying so would send the user looking for a
            // sign-in that does not exist.
            return provider(.cannotSynchronize, underlying: error)
        case .storageUnavailable:
            // The volume, not the file. This one is worth being careful about:
            // the failing path is the *root*, and `.noSuchItem` there would tell
            // the system every file on the phone had ceased to exist. It clears
            // on its own once the device finishes mounting, so hold and retry.
            return provider(.serverUnreachable, underlying: error)
        case .database:
            // Our own store is broken. Retrying the same item will not help, but
            // the domain is not dead either — the next request may touch rows
            // that are fine.
            return provider(.cannotSynchronize, underlying: error)
        }
    }

    private static func map(_ error: AdbError) -> Error {
        switch error {
        case .serverUnreachable, .socket, .unexpectedEOF, .protocolViolation, .deviceNotFound:
            // All of these mean the cable, the server, or the stream — never the
            // file. The item is still on the phone; we just cannot see it now.
            return provider(.serverUnreachable, underlying: error)

        case .deviceUnavailable(_, let state):
            // "unauthorized" is the one device state a retry will never fix: the
            // user has to accept the USB-debugging prompt on the phone. Saying
            // "unreachable" would leave Finder retrying a dialog it cannot press.
            return state == AdbDevice.State.unauthorized.rawValue
                ? provider(.notAuthenticated, underlying: error)
                : provider(.serverUnreachable, underlying: error)

        case .invalidPath:
            return provider(.noSuchItem, underlying: error)

        case .syncFailed, .requestFailed, .commandFailed, .localIO:
            guard let code = error.posixCode else {
                // adb told us something we do not recognise. Refusing to guess:
                // `.cannotSynchronize` surfaces it without either dropping the
                // item or retrying forever.
                Log.write.error("unmapped adb failure: \(error.localizedDescription, privacy: .public)")
                return provider(.cannotSynchronize, underlying: error)
            }
            return fromPosix(code, underlying: error)
        }
    }

    // MARK: - errno

    /// Maps a POSIX code onto the File Provider vocabulary, falling back to the
    /// code itself.
    ///
    /// Returning the raw errno is not a failure of mapping — `NSPOSIXErrorDomain`
    /// is what the API asks for when the failure genuinely is a filesystem one,
    /// and Finder already knows how to phrase "Permission denied".
    private static func fromPosix(_ code: Int32, underlying: Error) -> Error {
        switch code {
        case ENOENT:
            return provider(.noSuchItem, underlying: underlying)

        case ENOSPC, EDQUOT, EFBIG:
            // The one case where the right answer is a specific dialog rather
            // than a retry: the phone is full and will stay full.
            return provider(.insufficientQuota, underlying: underlying)

        case let code where DeviceErrno.isTransient(code):
            // A reset connection or a busy volume is worth another go; saying
            // otherwise would surface a transient hiccup as a hard failure.
            return provider(.serverUnreachable, underlying: underlying)

        default:
            return posix(code, underlying: underlying)
        }
    }

    // MARK: - Construction

    private static var cancelled: Error {
        NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
    }

    /// Builds the error with the original attached.
    ///
    /// `NSFileProviderError(_:)` gives no way to pass `userInfo`, and the code
    /// alone is unreadable in a log a week later — the underlying error is what
    /// says *which* of the six things that produce `.serverUnreachable` happened.
    private static func provider(_ code: NSFileProviderError.Code, underlying: Error) -> NSError {
        NSError(domain: NSFileProviderErrorDomain, code: code.rawValue, userInfo: [
            NSUnderlyingErrorKey: underlying as NSError,
            NSLocalizedDescriptionKey: underlying.localizedDescription
        ])
    }

    private static func posix(_ code: Int32, underlying: Error) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSUnderlyingErrorKey: underlying as NSError,
            NSLocalizedDescriptionKey: underlying.localizedDescription
        ])
    }
}
