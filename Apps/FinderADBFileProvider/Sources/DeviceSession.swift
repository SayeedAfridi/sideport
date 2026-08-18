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
}
