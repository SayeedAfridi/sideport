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

    // MARK: - Change tracking

    /// Implementing this pair is what turns a signal from the watcher into an
    /// incremental refresh. Without it the system can only re-enumerate the
    /// whole directory, which is both slower and visibly flickery.
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task { [session] in
            let anchor = (try? await session.currentAnchor()) ?? 0
            completionHandler(Self.encode(anchor))
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from syncAnchor: NSFileProviderSyncAnchor) {
        work = Task { [session, container] in
            do {
                let result = try await session.changes(since: Self.decode(syncAnchor), in: container)
                let rootFilename = session.rootFilename

                if !result.updated.isEmpty {
                    observer.didUpdate(result.updated.map {
                        ProviderItem($0.0, version: $0.1, rootFilename: rootFilename)
                    })
                }
                if !result.deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: result.deleted.map {
                        NSFileProviderItemIdentifier(itemID: $0)
                    })
                }
                observer.finishEnumeratingChanges(upTo: Self.encode(result.anchor), moreComing: false)
            } catch CoreError.anchorExpired {
                // Correct, just slower: the system re-enumerates from scratch
                // rather than trusting a delta we can no longer produce.
                Log.enumeration.info("sync anchor expired; full re-enumeration")
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            } catch {
                observer.finishEnumeratingWithError(ProviderError.map(error))
            }
        }
    }

    /// Anchors travel as opaque `Data`; ours is just the change-log row id.
    private static func encode(_ anchor: Int64) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(withUnsafeBytes(of: anchor.littleEndian) { Data($0) })
    }

    private static func decode(_ anchor: NSFileProviderSyncAnchor) -> Int64 {
        let data = anchor.rawValue
        guard data.count == MemoryLayout<Int64>.size else { return 0 }
        return data.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
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
