import AdbFinderCore
import AdbKit
import FileProvider

/// Translates our errors into ones Finder understands.
///
/// This matters more than it looks: an unmapped error makes Finder show a
/// generic failure and, worse, sometimes retry forever. `NSFileProviderError`
/// codes tell the system what to actually do — re-enumerate, show unreachable,
/// or give up on this item.
enum ProviderError {
    static func map(_ error: Error) -> Error {
        if let core = error as? CoreError { return map(core) }
        if let adb = error as? AdbError { return map(adb) }
        return error
    }

    private static func map(_ error: CoreError) -> Error {
        switch error {
        case .itemNotFound, .notADirectory:
            return NSFileProviderError(.noSuchItem)
        case .anchorExpired:
            // Tells the system to re-enumerate from scratch rather than trust a
            // delta we can no longer produce.
            return NSFileProviderError(.syncAnchorExpired)
        case .appGroupUnavailable, .database:
            return error
        }
    }

    private static func map(_ error: AdbError) -> Error {
        switch error {
        case .serverUnreachable, .socket, .unexpectedEOF:
            return NSFileProviderError(.serverUnreachable)
        case .deviceNotFound, .deviceUnavailable:
            return NSFileProviderError(.serverUnreachable)
        case .syncFailed, .invalidPath:
            return NSFileProviderError(.noSuchItem)
        case .requestFailed, .protocolViolation, .commandFailed, .localIO:
            return error
        }
    }
}
