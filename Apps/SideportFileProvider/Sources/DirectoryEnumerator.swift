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
            completionHandler(SyncAnchorCoding.encode(anchor))
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from syncAnchor: NSFileProviderSyncAnchor) {
        work = Task { [session, container] in
            do {
                let from = SyncAnchorCoding.decode(syncAnchor)
                let result = try await session.changes(since: from, in: container)
                Log.enumeration.info("changes for container \(container, privacy: .public) from anchor \(from, privacy: .public): \(result.updated.count, privacy: .public) updated, \(result.deleted.count, privacy: .public) deleted")
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
                observer.finishEnumeratingChanges(upTo: SyncAnchorCoding.encode(result.anchor), moreComing: false)
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

}

/// The domain-wide change feed.
///
/// Signalling a specific container only reaches a *live* enumerator — one Finder
/// actually has open. The working set is how the system learns about changes
/// when nothing is being looked at, so without it a photo taken on the phone
/// stays invisible until someone happens to re-open the folder.
///
/// Its initial contents are deliberately empty: the working set is meant to hold
/// recently-used items, and we have no reason to pin any. It exists here purely
/// as the delta channel.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let session: DeviceSession
    private var work: Task<Void, Never>?

    init(session: DeviceSession) {
        self.session = session
    }

    func invalidate() {
        work?.cancel()
        work = nil
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task { [session] in
            let anchor = (try? await session.currentAnchor()) ?? 0
            completionHandler(SyncAnchorCoding.encode(anchor))
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from syncAnchor: NSFileProviderSyncAnchor) {
        work = Task { [session] in
            do {
                let from = SyncAnchorCoding.decode(syncAnchor)
                let result = try await session.allChanges(since: from)
                Log.enumeration.info("working-set changes from anchor \(from, privacy: .public): \(result.updated.count, privacy: .public) updated, \(result.deleted.count, privacy: .public) deleted")
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
                observer.finishEnumeratingChanges(upTo: SyncAnchorCoding.encode(result.anchor),
                                                  moreComing: false)
            } catch CoreError.anchorExpired {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            } catch {
                observer.finishEnumeratingWithError(ProviderError.map(error))
            }
        }
    }
}

/// Serves containers we genuinely do not model, such as the trash.
///
/// Throwing instead would make the system retry in a loop; enumerating nothing
/// is the quiet, correct answer.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }
}

/// Anchors travel as opaque `Data`; ours is just the change-log row id.
enum SyncAnchorCoding {
    static func encode(_ anchor: Int64) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(withUnsafeBytes(of: anchor.littleEndian) { Data($0) })
    }

    static func decode(_ anchor: NSFileProviderSyncAnchor) -> Int64 {
        let data = anchor.rawValue
        guard data.count == MemoryLayout<Int64>.size else { return 0 }
        return data.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
    }
}
