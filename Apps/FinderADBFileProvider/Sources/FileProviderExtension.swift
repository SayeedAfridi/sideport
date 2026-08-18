import AdbFinderCore
import AdbKit
import FileProvider

/// The Finder-facing surface. Deliberately thin: it translates File Provider
/// calls into `DeviceSession` work and maps errors back. Anything resembling
/// logic belongs in `AdbFinderCore`, where it can be tested without a domain
/// registered and without Finder in the loop.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let session: DeviceSession

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.session = DeviceSession(domain: domain)
        super.init()
        Log.domain.info("extension started for \(domain.identifier.rawValue, privacy: .public)")

        let session = self.session
        Task { await session.beginWatching() }
    }

    func invalidate() {
        // The watcher holds a long-lived adb transport; leaving it running past
        // invalidation would leak a connection per extension lifetime.
        let session = self.session
        Task { await session.shutdown() }
        Log.domain.info("extension invalidated for \(self.domain.identifier.rawValue, privacy: .public)")
    }

    // MARK: - Reads

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task { [session] in
            do {
                guard let id = identifier.itemID else { throw CoreError.itemNotFound(0) }
                let (stored, version) = try await session.itemAndVersion(id)
                completionHandler(ProviderItem(stored, version: version, rootFilename: session.rootFilename), nil)
            } catch {
                completionHandler(nil, ProviderError.map(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        // The working set is the domain-wide delta channel: without it, changes
        // made on the phone stay invisible until someone re-opens the folder.
        if containerItemIdentifier == .workingSet {
            return WorkingSetEnumerator(session: session)
        }
        guard containerItemIdentifier != .trashContainer else { return EmptyEnumerator() }
        guard let id = containerItemIdentifier.itemID else {
            throw NSFileProviderError(.noSuchItem)
        }
        return DirectoryEnumerator(session: session, container: id)
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task { [session, domain] in
            do {
                guard let id = itemIdentifier.itemID else { throw CoreError.itemNotFound(0) }
                let (stored, version) = try await session.itemAndVersion(id)

                // A replicated provider materialises whole files — opening a
                // 6 GB archive downloads 6 GB. Honest progress and a working
                // cancel are the only mitigations this API allows.
                progress.totalUnitCount = max(stored.size, 1)
                let destination = Self.temporaryURL(for: domain, name: stored.name)

                try await session.pull(id, to: destination) { transferred in
                    guard !progress.isCancelled else { throw CancellationError() }
                    progress.completedUnitCount = min(transferred, progress.totalUnitCount)
                }

                completionHandler(destination,
                                  ProviderItem(stored, version: version, rootFilename: session.rootFilename),
                                  nil)
            } catch is CancellationError {
                completionHandler(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                Log.fetch.error("fetch failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, nil, ProviderError.map(error))
            }
        }
        return progress
    }

    // MARK: - Writes

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let filename = itemTemplate.filename

        // Finder writes .DS_Store into every directory it opens. Refusing here
        // keeps the file in the Mac's local replica — Finder stays happy — while
        // the phone never sees it.
        guard !SyncExclusions.excludes(filename) else {
            Log.write.debug("excluded \(filename, privacy: .public) from sync")
            completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
            return progress
        }

        let isDirectory = itemTemplate.contentType == .folder
        let expected = (itemTemplate.documentSize ?? nil)?.int64Value ?? 1

        Task { [session] in
            do {
                guard let parent = itemTemplate.parentItemIdentifier.itemID else {
                    throw CoreError.itemNotFound(0)
                }

                let result: (StoredItem, ItemVersion)
                if isDirectory {
                    result = try await session.createDirectory(named: filename, in: parent)
                } else {
                    guard let url else { throw CoreError.itemNotFound(parent) }
                    progress.totalUnitCount = max(expected, 1)
                    result = try await session.createFile(named: filename, in: parent, from: url) { sent in
                        guard !progress.isCancelled else { throw CancellationError() }
                        progress.completedUnitCount = min(sent, progress.totalUnitCount)
                    }
                }

                completionHandler(ProviderItem(result.0, version: result.1,
                                               rootFilename: session.rootFilename), [], false, nil)
            } catch is CancellationError {
                completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                Log.write.error("create failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, ProviderError.map(error))
            }
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        guard !SyncExclusions.excludes(item.filename) else {
            completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
            return progress
        }

        let filename = item.filename
        let newParent = item.parentItemIdentifier.itemID
        let wantsRelocate = changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier)
        let wantsContents = changedFields.contains(.contents)
        let expected = (item.documentSize ?? nil)?.int64Value ?? 1

        Task { [session] in
            do {
                guard let id = item.itemIdentifier.itemID else { throw CoreError.itemNotFound(0) }
                var current = try await session.itemAndVersion(id)

                // Rename before content: doing it the other way round would
                // upload into the old path and then move the fresh bytes.
                if wantsRelocate, let newParent {
                    current = try await session.relocate(id, to: filename, parent: newParent)
                }

                if wantsContents, let newContents {
                    progress.totalUnitCount = max(expected, 1)
                    current = try await session.replaceContents(of: id, from: newContents) { sent in
                        guard !progress.isCancelled else { throw CancellationError() }
                        progress.completedUnitCount = min(sent, progress.totalUnitCount)
                    }
                }

                completionHandler(ProviderItem(current.0, version: current.1,
                                               rootFilename: session.rootFilename), [], false, nil)
            } catch is CancellationError {
                completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                Log.write.error("modify failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, ProviderError.map(error))
            }
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task { [session] in
            do {
                guard let id = identifier.itemID else { throw CoreError.itemNotFound(0) }
                try await session.delete(id)
                completionHandler(nil)
            } catch where ProviderError.isAlreadyGone(error) {
                // The device has already lost it, so the user's request is
                // satisfied. Reporting an error here badges a folder that is in
                // exactly the state that was asked for.
                Log.write.debug("delete: already gone")
                completionHandler(nil)
            } catch {
                Log.write.error("delete failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(ProviderError.map(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    // MARK: - Helpers

    /// Where a materialised file is written before the system takes it.
    ///
    /// The manager's own temporary directory is guaranteed to be on the same
    /// volume as the replica, which lets the system claim the file by renaming
    /// it. The container's `tmp` is only *probably* on that volume, and if it
    /// ever is not, every materialisation silently pays a second full copy —
    /// on a 7 GB download that is 7 GB of avoidable I/O and transient disk.
    ///
    /// So the fallback is kept, because failing a download over a temporary
    /// directory would be worse, but it is no longer silent.
    static func temporaryURL(for domain: NSFileProviderDomain, name: String) -> URL {
        let directory: URL
        do {
            guard let manager = NSFileProviderManager(for: domain) else {
                throw CoreError.itemNotFound(0)
            }
            directory = try manager.temporaryDirectoryURL()
        } catch {
            Log.fetch.error("""
                falling back to the container tmp: \(error.localizedDescription, privacy: .public)
                """)
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(name)")
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}
