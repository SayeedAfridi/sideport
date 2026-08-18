import AdbFinderCore
import AdbKit
import FileProvider
import Foundation

/// Everything one device domain needs: an adb client, its metadata store, and
/// the resolved storage root.
///
/// An actor because Finder calls the extension concurrently from several queues
/// and the store must not be opened twice.
actor DeviceSession {
    nonisolated let serial: String
    nonisolated let selector: DeviceSelector
    nonisolated let rootFilename: String

    private let client = AdbClient()
    /// Lets the menu bar answer "is anything still going on?" without a window.
    /// Finder shows per-copy progress already; this is the different question.
    private let transfers: TransferReporter
    private var store: MetadataStore?
    private var deviceRoot: String?
    private var opening: Task<MetadataStore, Error>?
    private let domain: NSFileProviderDomain
    private var watcher: InotifyWatcher?

    init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.transfers = TransferReporter(serial: domain.identifier.rawValue)
        serial = domain.identifier.rawValue
        selector = .serial(domain.identifier.rawValue)
        rootFilename = domain.displayName
    }

    func shutdown() async {
        await watcher?.stop()
        watcher = nil
    }

    // MARK: - Setup

    /// Opens the store, resolving the device's storage root first.
    ///
    /// Guarded by an in-flight task rather than a plain nil check: actors are
    /// re-entrant, so the `await` below suspends and lets a second caller
    /// through the check, and both would then open the same SQLite file.
    func preparedStore() async throws -> MetadataStore {
        if let store { return store }
        if let opening { return try await opening.value }

        let task = Task { try await openStore() }
        opening = task
        do {
            let opened = try await task.value
            store = opened
            opening = nil
            return opened
        } catch {
            opening = nil
            throw error
        }
    }

    private func openStore() async throws -> MetadataStore {
        let root = await resolveRoot()
        let url = try FinderADB.storeURL(forSerial: serial)
        let opened = try MetadataStore(path: url.path, deviceRoot: root)

        // The root row is seeded with a placeholder mode, so its write
        // capability would otherwise be wrong: /storage/emulated/0 is drwxrws---
        // and the seed says drwxr-xr-x.
        if let rootEntry = try? await client.stat(root, on: selector) , rootEntry.exists {
            try? opened.update(MetadataStore.rootID, from: rootEntry)
        }

        // Collect staging files from transfers that died mid-flight. Only ones
        // older than an hour, so a transfer running right now is never swept
        // out from under itself.
        Task { [client, selector] in
            if let swept = try? await client.sweepStagingFiles(under: root, on: selector), swept > 0 {
                Log.write.info("swept \(swept, privacy: .public) stale staging files")
            }
        }

        Log.domain.info("store ready for \(self.serial, privacy: .public) at root \(root, privacy: .public)")
        return opened
    }

    /// `/sdcard` is a symlink to `/storage/self/primary`, itself a symlink to
    /// `/storage/emulated/0`. Resolved once per session rather than paying two
    /// indirections on every single operation.
    private func resolveRoot() async -> String {
        if let deviceRoot { return deviceRoot }
        let result = try? await client.shell("readlink -f /sdcard", on: selector)
        let candidate = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root = (result?.succeeded == true && candidate.hasPrefix("/"))
            ? candidate
            : FinderADB.defaultDeviceRoot
        deviceRoot = root
        return root
    }

    // MARK: - Enumeration

    /// Lists a directory, folds it into the store, and returns what Finder
    /// should see. Tuples of `Sendable` values cross the actor boundary; the
    /// `NSFileProviderItem` objects are built by the caller.
    func enumerate(_ container: ItemID) async throws -> [(StoredItem, ItemVersion)] {
        let began = DispatchTime.now()
        let store = try await preparedStore()
        let opened = DispatchTime.now()
        let path = try store.path(of: container)
        let listing = try await list(directory: path)
        let listed = DispatchTime.now()
        let result = try store.reconcile(directory: container, listing: listing)
        let reconciled = DispatchTime.now()
        // Watch what the user is actually looking at, rather than the whole
        // tree: inotify is not recursive and its watch budget is finite.
        await startWatcherIfNeeded().watch(path)
        let armed = DispatchTime.now()
        func ms(_ a: DispatchTime, _ b: DispatchTime) -> Double {
            Double(b.uptimeNanoseconds - a.uptimeNanoseconds) / 1_000_000
        }
        Log.enumeration.debug("""
            timing \(path, privacy: .public): store=\(ms(began, opened), privacy: .public) \
            list=\(ms(opened, listed), privacy: .public) \
            reconcile=\(ms(listed, reconciled), privacy: .public) \
            watch=\(ms(reconciled, armed), privacy: .public)
            """)
        if !result.isEmpty {
            Log.enumeration.debug("""
                \(path, privacy: .public): +\(result.created.count) ~\(result.modified.count) \
                →\(result.moved.count) -\(result.deleted.count)
                """)
        }
        return try store.children(of: container).map { ($0, store.version(of: $0)) }
    }

    func itemAndVersion(_ id: ItemID) async throws -> (StoredItem, ItemVersion) {
        let store = try await preparedStore()
        guard let item = try store.item(id) else { throw CoreError.itemNotFound(id) }
        return (item, store.version(of: item))
    }

    /// One sync session serves the listing *and* every symlink resolution in it,
    /// rather than paying a TCP connect and transport handshake per entry.
    private func list(directory path: String) async throws -> [AdbFileEntry] {
        let entries = try await listOnOneSession(path)
        // `LIST` answers DONE with no entries when its opendir fails, so an
        // unreadable directory and an empty one are identical on the wire. This
        // is the path enumeration and reconciliation both take, and reading the
        // first as the second would tombstone every file under it.
        if entries.isEmpty { try await client.confirmListable(path, on: selector) }
        return entries
    }

    /// Kept on a single sync session so a symlink's target can be stat'd without
    /// paying for a second connection.
    private func listOnOneSession(_ path: String) async throws -> [AdbFileEntry] {
        try await client.withSyncSession(selector) { session in
            try session.list(path).map { entry in
                // Listings are lstat-shaped, so a symlink to a folder would
                // otherwise reach Finder as an unopenable file. The link's own
                // dev/ino are kept: the link is the thing living in this
                // directory, and identity must track it, not its target.
                guard entry.isSymlink,
                      let target = try? session.stat(path + "/" + entry.name, followSymlinks: true),
                      target.exists else { return entry }
                return AdbFileEntry(name: entry.name, mode: target.mode, size: target.size,
                                    modified: target.modified, dev: entry.dev, ino: entry.ino)
            }
        }
    }

    // MARK: - Contents

    func pull(_ id: ItemID, to destination: URL,
              progress: @escaping @Sendable (Int64) throws -> Void) async throws {
        let store = try await preparedStore()
        let path = try store.path(of: id)
        Log.fetch.info("pulling \(path, privacy: .public)")
        let token = transfers.begin()
        defer { token.finish() }
        try await client.pull(path, to: destination, on: selector) { sent in
            token.report(sent)
            try progress(sent)
        }
    }

    // MARK: - Writes

    /// Creates a directory and records it.
    func createDirectory(named name: String, in parent: ItemID) async throws -> (StoredItem, ItemVersion) {
        let store = try await preparedStore()
        let path = try store.path(of: parent) + "/" + name
        Log.write.info("mkdir \(path, privacy: .public)")
        try await client.makeDirectory(path, on: selector)
        return try await record(path: path, name: name, in: parent, store: store)
    }

    /// Uploads a new file and records it.
    func createFile(named name: String, in parent: ItemID, from source: URL,
                    progress: @escaping @Sendable (Int64) throws -> Void) async throws -> (StoredItem, ItemVersion) {
        let store = try await preparedStore()
        let path = try store.path(of: parent) + "/" + name
        Log.write.info("create \(path, privacy: .public)")
        let token = transfers.begin()
        defer { token.finish() }
        try await client.pushAtomically(source, to: path, on: selector) { sent in
            token.report(sent)
            try progress(sent)
        }
        return try await record(path: path, name: name, in: parent, store: store)
    }

    /// Replaces an existing file's contents.
    func replaceContents(of id: ItemID, from source: URL,
                         progress: @escaping @Sendable (Int64) throws -> Void) async throws -> (StoredItem, ItemVersion) {
        let store = try await preparedStore()
        let path = try store.path(of: id)
        Log.write.info("write \(path, privacy: .public)")
        let token = transfers.begin()
        defer { token.finish() }
        try await client.pushAtomically(source, to: path, on: selector) { sent in
            token.report(sent)
            try progress(sent)
        }

        let entry = try await client.stat(path, on: selector)
        try store.update(id, from: entry)
        return try await itemAndVersion(id)
    }

    /// Renames and/or moves, preserving the identifier so the subtree keeps its
    /// identity in Finder.
    func relocate(_ id: ItemID, to name: String, parent: ItemID) async throws -> (StoredItem, ItemVersion) {
        let store = try await preparedStore()
        let source = try store.path(of: id)
        let destination = try store.path(of: parent) + "/" + name
        guard source != destination else { return try await itemAndVersion(id) }

        Log.write.info("mv \(source, privacy: .public) -> \(destination, privacy: .public)")
        try await client.move(from: source, to: destination, on: selector)
        try store.move(id, toParent: parent, name: name)
        return try await itemAndVersion(id)
    }

    func delete(_ id: ItemID) async throws {
        let store = try await preparedStore()
        let path = try store.path(of: id)
        Log.write.info("rm \(path, privacy: .public)")
        try await client.remove(path, on: selector)
        try store.markDeleted(id)
    }

    /// Stats what we just wrote and folds it into the store, so the row carries
    /// the device's own size, mtime, and inode rather than our guess at them.
    private func record(path: String, name: String, in parent: ItemID,
                        store: MetadataStore) async throws -> (StoredItem, ItemVersion) {
        let entry = try await client.stat(path, on: selector, followSymlinks: false)
        guard entry.exists else { throw CoreError.itemNotFound(parent) }

        let named = AdbFileEntry(name: name, mode: entry.mode, size: entry.size,
                                 modified: entry.modified, dev: entry.dev, ino: entry.ino)
        // A name reused after a delete must not inherit the old identity, so an
        // existing row is refreshed rather than a duplicate inserted.
        if let existing = try store.child(of: parent, named: name) {
            try store.update(existing.id, from: named)
            return try await itemAndVersion(existing.id)
        }
        let inserted = try store.insert(childOf: parent, entry: named)
        return (inserted, store.version(of: inserted))
    }

    // MARK: - Change tracking

    /// Begins watching as soon as the extension exists.
    ///
    /// Arming only on enumeration is not enough: the system serves an already
    /// materialised directory straight from its replica, so it may never ask us
    /// anything — and a watcher that waits to be asked never starts. The root is
    /// armed unconditionally; deeper directories are added as they are visited.
    func beginWatching() async {
        guard let store = try? await preparedStore() else {
            Log.watch.error("cannot start watcher: store unavailable")
            return
        }
        let root = (try? store.path(of: MetadataStore.rootID)) ?? FinderADB.defaultDeviceRoot
        await startWatcherIfNeeded().watch(root)
    }

    private func startWatcherIfNeeded() -> InotifyWatcher {
        if let watcher { return watcher }
        let created = InotifyWatcher(client: client, selector: selector) { [weak self] paths in
            await self?.deviceChanged(paths)
        }
        watcher = created
        return created
    }

    /// A directory changed on the device: re-list it, fold the result into the
    /// store, and tell the system to pick up the delta.
    private func deviceChanged(_ paths: [String]) async {
        guard let store else { return }
        var touched: [ItemID] = []

        var vanished: [String] = []
        for path in paths {
            // A path we have never enumerated is nothing to update — the user
            // has not looked there, and the next enumeration will be correct.
            guard let item = try? store.item(atDevicePath: path), item.isDirectory else {
                vanished.append(path)
                continue
            }
            do {
                let listing = try await list(directory: path)
                let result = try store.reconcile(directory: item.id, listing: listing)
                if !result.isEmpty { touched.append(item.id) }
            } catch {
                Log.watch.error("rescan of \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // A watched directory that no longer resolves has been deleted; leaving
        // it armed would stop inotifyd starting at all.
        if !vanished.isEmpty { await watcher?.unwatch(vanished) }

        guard !touched.isEmpty else { return }
        let manager = NSFileProviderManager(for: domain)

        // The working set first: it is the only channel the system consults
        // when no window is open on the changed folder.
        manager?.signalEnumerator(for: .workingSet) { error in
            if let error {
                Log.watch.error("working set signal failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        for id in touched {
            Log.watch.info("signalling container \(id, privacy: .public)")
            manager?.signalEnumerator(for: .init(itemID: id)) { error in
                if let error {
                    Log.watch.error("signal failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Domain-wide change replay for the working set: same as `changes(since:in:)`
    /// but without filtering to one container.
    func allChanges(since anchor: Int64) async throws -> (updated: [(StoredItem, ItemVersion)],
                                                          deleted: [ItemID],
                                                          anchor: Int64) {
        let store = try await preparedStore()
        let entries = try store.changes(since: anchor)

        var updated: [(StoredItem, ItemVersion)] = []
        var deleted: [ItemID] = []
        var seen = Set<ItemID>()

        for change in entries.reversed() where seen.insert(change.itemID).inserted {
            if change.kind == .deleted {
                deleted.append(change.itemID)
                continue
            }
            guard let item = try store.item(change.itemID) else {
                deleted.append(change.itemID)
                continue
            }
            updated.append((item, store.version(of: item)))
        }
        return (updated, deleted, try store.currentAnchor())
    }

    /// Replays the change log for one container.
    ///
    /// Deletions are looked up including tombstones, because a deletion still
    /// has to be attributed to the container that lost the item.
    func changes(since anchor: Int64,
                 in container: ItemID) async throws -> (updated: [(StoredItem, ItemVersion)],
                                                        deleted: [ItemID],
                                                        anchor: Int64) {
        let store = try await preparedStore()
        let entries = try store.changes(since: anchor)

        var updated: [(StoredItem, ItemVersion)] = []
        var deleted: [ItemID] = []
        var seen = Set<ItemID>()

        // Newest wins: an item created and then modified within one batch should
        // be reported once.
        for change in entries.reversed() where seen.insert(change.itemID).inserted {
            if change.kind == .deleted {
                if let tombstone = try store.itemIncludingDeleted(change.itemID),
                   tombstone.parentID == container {
                    deleted.append(change.itemID)
                }
                continue
            }
            guard let item = try store.item(change.itemID) else {
                deleted.append(change.itemID)
                continue
            }
            guard item.parentID == container else { continue }
            updated.append((item, store.version(of: item)))
        }

        return (updated, deleted, try store.currentAnchor())
    }

    func currentAnchor() async throws -> Int64 {
        try await preparedStore().currentAnchor()
    }
}
