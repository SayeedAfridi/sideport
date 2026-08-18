import AdbFinderCore
import FileProvider

/// Enumerates one directory.
///
/// No paging: the adb sync protocol returns whole directories in a single
/// exchange, so there is nothing to page through. If a pathological directory
/// ever shows up, chunk the *emission*, not the fetch.
final class DirectoryEnumerator: NSObject, NSFileProviderEnumerator {
    private let session: DeviceSession
    private let container: ItemID
    private var work: Task<Void, Never>?

    init(session: DeviceSession, container: ItemID) {
        self.session = session
        self.container = container
    }

    func invalidate() {
        work?.cancel()
        work = nil
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        work = Task { [session, container] in
            do {
                let rows = try await session.enumerate(container)
                let rootFilename = session.rootFilename
                observer.didEnumerate(rows.map {
                    ProviderItem($0.0, version: $0.1, rootFilename: rootFilename)
                })
                observer.finishEnumerating(upTo: nil)
            } catch {
                Log.enumeration.error("enumeration failed: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(ProviderError.map(error))
            }
        }
    }
}

/// Serves containers we do not model, such as the working set, without erroring.
///
/// Throwing for the working set instead would make the system retry in a loop;
/// enumerating nothing is the quiet, correct answer until M4 gives us real
/// change tracking.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }
}
