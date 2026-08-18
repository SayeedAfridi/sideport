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
    private var store: MetadataStore?
    private var deviceRoot: String?

    init(domain: NSFileProviderDomain) {
        serial = domain.identifier.rawValue
        selector = .serial(domain.identifier.rawValue)
        rootFilename = domain.displayName
    }

    // MARK: - Setup

    /// Opens the store, resolving the device's storage root first.
    func preparedStore() async throws -> MetadataStore {
        if let store { return store }
        let root = await resolveRoot()
        let url = try FinderADB.storeURL(forSerial: serial)
        let opened = try MetadataStore(path: url.path, deviceRoot: root)
        store = opened

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
        let store = try await preparedStore()
        let path = try store.path(of: container)
        let listing = try await list(directory: path)
        let result = try store.reconcile(directory: container, listing: listing)
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
        try await client.pull(path, to: destination, on: selector, progress: progress)
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
        try await client.pushAtomically(source, to: path, on: selector, progress: progress)
        return try await record(path: path, name: name, in: parent, store: store)
    }

    /// Replaces an existing file's contents.
    func replaceContents(of id: ItemID, from source: URL,
                         progress: @escaping @Sendable (Int64) throws -> Void) async throws -> (StoredItem, ItemVersion) {
        let store = try await preparedStore()
        let path = try store.path(of: id)
        Log.write.info("write \(path, privacy: .public)")
        try await client.pushAtomically(source, to: path, on: selector, progress: progress)

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
}
