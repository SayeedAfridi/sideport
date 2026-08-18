import AdbKit
import CryptoKit
import Foundation

/// The identity map between Finder's stable item identifiers and device paths.
///
/// **Why identifiers are not paths.** Finder requires an item identifier to
/// survive renames and moves. If a path were the identifier, renaming a folder
/// would change the identifier of everything beneath it and Finder would see the
/// whole subtree vanish and reappear.
///
/// **Why identifiers are not inodes.** `DNT2`/`STA2` do carry `dev` and `ino`,
/// but `/storage/emulated/0` is a FUSE mount and inode stability across remounts
/// is not contractual. Inodes are kept only as a hint for move detection.
///
/// So identifiers are ours: opaque, monotonic, and persisted. A path is
/// reconstructed by walking parent links, which makes a rename a single-row
/// update that the whole subtree inherits for free.
public final class MetadataStore: @unchecked Sendable {
    /// Maps to `NSFileProviderItemIdentifier.rootContainer` one layer up.
    public static let rootID: ItemID = 1

    /// Absolute device path the root identifier corresponds to, resolved once
    /// at domain setup so we never pay `/sdcard`'s two symlink hops per call.
    public let deviceRoot: String

    private let database: SQLiteDatabase
    private let lock = NSRecursiveLock()
    /// Resolved device paths, keyed by identifier.
    ///
    /// Bounded because the extension is long-lived and a device with a deep
    /// tree would otherwise grow this without limit. Eviction is wholesale
    /// rather than LRU: entries are cheap to rebuild (one indexed query) and a
    /// recency list would cost more to maintain than it saves.
    private var pathCache: [ItemID: String] = [:]
    private static let pathCacheLimit = 4096

    public init(path: String, deviceRoot: String) throws {
        self.deviceRoot = deviceRoot.hasSuffix("/") ? String(deviceRoot.dropLast()) : deviceRoot
        self.database = try SQLiteDatabase(path: path)
        try migrate()
    }

    /// For tests and for throwaway enumeration.
    public convenience init(inMemoryDeviceRoot deviceRoot: String) throws {
        try self.init(path: ":memory:", deviceRoot: deviceRoot)
    }

    // MARK: - Schema

    private func migrate() throws {
        let version = try database.queryOne("PRAGMA user_version") { $0.int(0) } ?? 0
        guard version < 1 else { return }

        try database.execute("""
            -- AUTOINCREMENT matters here: without it SQLite reuses the highest
            -- freed rowid, so a purged tombstone could hand its identifier to an
            -- unrelated new file and Finder would think a deleted item returned.
            CREATE TABLE items (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                parent_id    INTEGER NOT NULL REFERENCES items(id),
                name         TEXT    NOT NULL,
                display_name TEXT    NOT NULL,
                is_dir       INTEGER NOT NULL,
                size         INTEGER NOT NULL,
                mtime        INTEGER NOT NULL,
                mode         INTEGER NOT NULL,
                dev          INTEGER,
                ino          INTEGER,
                deleted_at   INTEGER
            );

            -- Partial, so tombstones may share a name with the live entry that
            -- replaced them.
            CREATE UNIQUE INDEX items_live_name ON items(parent_id, name) WHERE deleted_at IS NULL;
            CREATE INDEX items_live_children ON items(parent_id) WHERE deleted_at IS NULL;
            CREATE INDEX items_inode ON items(dev, ino) WHERE deleted_at IS NULL;

            CREATE TABLE changes (
                anchor      INTEGER PRIMARY KEY AUTOINCREMENT,
                item_id     INTEGER NOT NULL,
                kind        INTEGER NOT NULL,
                recorded_at INTEGER NOT NULL
            );
            CREATE INDEX changes_recorded ON changes(recorded_at);

            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

            -- The root is its own parent, which terminates path resolution.
            -- Mode 0o40770 (drwxrwx---), not 0o40755: capabilities are derived
            -- from the group-write bit, so a seed without it makes the root
            -- advertise as read-only and Finder hides "New Folder" until the
            -- real device mode arrives. Emulated storage is drwxrws--- anyway.
            INSERT INTO items (id, parent_id, name, display_name, is_dir, size, mtime, mode)
            VALUES (1, 1, '', '', 1, 0, 0, 16888);

            PRAGMA user_version = 1;
            """)
    }

    // MARK: - Reads

    public func item(_ id: ItemID) throws -> StoredItem? {
        try lock.withLock {
            try database.queryOne(Self.selectColumns + " WHERE id = ?1 AND deleted_at IS NULL",
                                  [.integer(id)], row: Self.decode)
        }
    }

    public func children(of parent: ItemID) throws -> [StoredItem] {
        try lock.withLock {
            try database.query(Self.selectColumns + " WHERE parent_id = ?1 AND deleted_at IS NULL AND id != ?1 ORDER BY name",
                               [.integer(parent)], row: Self.decode)
        }
    }

    public func child(of parent: ItemID, named name: String) throws -> StoredItem? {
        try lock.withLock {
            try database.queryOne(Self.selectColumns + " WHERE parent_id = ?1 AND name = ?2 AND deleted_at IS NULL AND id != ?1",
                                  [.integer(parent), .text(name)], row: Self.decode)
        }
    }

    /// Absolute device path, resolved by walking parent links.
    public func path(of id: ItemID) throws -> String {
        try lock.withLock {
            if let cached = pathCache[id] { return cached }
            guard id != Self.rootID else { return deviceRoot }

            // One recursive query beats N round trips for a deep tree. The
            // `chain.id <> 1` guard stops the root's self-reference looping.
            let components = try database.query("""
                WITH RECURSIVE chain(id, parent_id, name, depth) AS (
                    SELECT id, parent_id, name, 0 FROM items WHERE id = ?1 AND deleted_at IS NULL
                    UNION ALL
                    SELECT i.id, i.parent_id, i.name, chain.depth + 1
                      FROM items i JOIN chain ON i.id = chain.parent_id
                     WHERE chain.id <> 1
                )
                SELECT name FROM chain WHERE id <> 1 ORDER BY depth DESC
                """, [.integer(id)]) { $0.string(0) }

            guard !components.isEmpty else { throw CoreError.itemNotFound(id) }
            let resolved = deviceRoot + "/" + components.joined(separator: "/")
            if pathCache.count >= Self.pathCacheLimit { pathCache.removeAll(keepingCapacity: true) }
            pathCache[id] = resolved
            return resolved
        }
    }

    /// Resolves an absolute device path back to its item, if we know it.
    ///
    /// The watcher reports paths, not identifiers, so this is how a filesystem
    /// event is matched to the tree we already track. Returns nil for anything
    /// outside the domain root or not yet enumerated — both mean "nothing to
    /// update", not an error.
    public func item(atDevicePath path: String) throws -> StoredItem? {
        guard path == deviceRoot || path.hasPrefix(deviceRoot + "/") else { return nil }
        let relative = String(path.dropFirst(deviceRoot.count))
        let components = relative.split(separator: "/").map(String.init)

        return try lock.withLock {
            var current = try database.queryOne(
                Self.selectColumns + " WHERE id = ?1 AND deleted_at IS NULL",
                [.integer(Self.rootID)], row: Self.decode)
            for component in components {
                guard let parent = current else { return nil }
                current = try database.queryOne(
                    Self.selectColumns + " WHERE parent_id = ?1 AND name = ?2 AND deleted_at IS NULL AND id != ?1",
                    [.integer(parent.id), .text(component)], row: Self.decode)
            }
            return current
        }
    }

    /// Looks up an item even after it has been tombstoned.
    ///
    /// Change replay needs this: a deletion must still be attributable to a
    /// parent container, and by then the live row is gone.
    public func itemIncludingDeleted(_ id: ItemID) throws -> StoredItem? {
        try lock.withLock {
            try database.queryOne(Self.selectColumns + " WHERE id = ?1", [.integer(id)], row: Self.decode)
        }
    }

    /// Content and metadata versions for `NSFileProviderItemVersion`.
    ///
    /// Known weakness: the sync protocol carries mtime in whole seconds, so two
    /// writes within one second that leave the size unchanged are
    /// indistinguishable here. The `inotifyd` watcher (M4) covers device-side
    /// writes, and for our own writes we know the version directly.
    public func version(of item: StoredItem) -> ItemVersion {
        var content = Data()
        content.append(contentsOf: withUnsafeBytes(of: item.size.littleEndian, Array.init))
        content.append(contentsOf: withUnsafeBytes(of: Int64(item.modified.timeIntervalSince1970).littleEndian, Array.init))

        var metadata = Data(item.name.utf8)
        metadata.append(contentsOf: withUnsafeBytes(of: item.parentID.littleEndian, Array.init))
        metadata.append(contentsOf: withUnsafeBytes(of: item.mode.littleEndian, Array.init))

        return ItemVersion(content: Data(SHA256.hash(data: content)),
                           metadata: Data(SHA256.hash(data: metadata)))
    }

    // MARK: - Writes

    /// Inserts a child and records a `created` change.
    @discardableResult
    public func insert(childOf parent: ItemID, entry: AdbFileEntry, displayName: String? = nil) throws -> StoredItem {
        try lock.withLock {
            try database.transaction { try insertLocked(childOf: parent, entry: entry, displayName: displayName) }
        }
    }

    /// Renames and/or reparents, preserving the identifier so the whole subtree
    /// keeps its identity.
    public func move(_ id: ItemID, toParent parent: ItemID, name: String, displayName: String? = nil) throws {
        try lock.withLock {
            try database.transaction {
                try database.run("UPDATE items SET parent_id = ?2, name = ?3, display_name = ?4 WHERE id = ?1",
                                 [.integer(id), .integer(parent), .text(name), .text(displayName ?? name)])
                try appendChangeLocked(id, .moved)
            }
            pathCache.removeAll()
        }
    }

    /// Refreshes a row from a fresh device stat, after we changed the file
    /// ourselves. Returns nil when nothing Finder would notice differs, so a
    /// no-op write does not churn the change log.
    @discardableResult
    public func update(_ id: ItemID, from entry: AdbFileEntry) throws -> StoredItem? {
        try lock.withLock {
            guard let current = try database.queryOne(
                Self.selectColumns + " WHERE id = ?1 AND deleted_at IS NULL",
                [.integer(id)], row: Self.decode) else { throw CoreError.itemNotFound(id) }

            let sameContent = current.size == entry.size
                && Int64(current.modified.timeIntervalSince1970) == Int64(entry.modified.timeIntervalSince1970)
            guard !(sameContent && current.mode == entry.mode) else { return nil }

            try database.transaction {
                try database.run("""
                    UPDATE items SET size = ?2, mtime = ?3, mode = ?4, dev = ?5, ino = ?6 WHERE id = ?1
                    """, [.integer(id), .integer(entry.size),
                          .integer(Int64(entry.modified.timeIntervalSince1970)),
                          .integer(Int64(entry.mode)),
                          .optionalInteger(entry.dev), .optionalInteger(entry.ino)])
                try appendChangeLocked(id, .modified)
            }
            return StoredItem(id: current.id, parentID: current.parentID, name: current.name,
                              displayName: current.displayName, isDirectory: entry.isDirectory,
                              size: entry.size, modified: entry.modified, mode: entry.mode,
                              dev: entry.dev ?? current.dev, ino: entry.ino ?? current.ino)
        }
    }

    /// Tombstones rather than deleting: `enumerateChanges` must still be able to
    /// report the deletion to a client whose anchor predates it.
    public func markDeleted(_ id: ItemID) throws {
        try lock.withLock {
            try database.transaction { try markDeletedLocked(id) }
            pathCache.removeAll()
        }
    }

    // MARK: - Locked internals

    private func insertLocked(childOf parent: ItemID, entry: AdbFileEntry, displayName: String?) throws -> StoredItem {
        try database.run("""
            INSERT INTO items (parent_id, name, display_name, is_dir, size, mtime, mode, dev, ino)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            """, [.integer(parent), .text(entry.name), .text(displayName ?? entry.name),
                  .boolean(entry.isDirectory), .integer(entry.size),
                  .integer(Int64(entry.modified.timeIntervalSince1970)), .integer(Int64(entry.mode)),
                  .optionalInteger(entry.dev), .optionalInteger(entry.ino)])

        let id = database.lastInsertedID
        try appendChangeLocked(id, .created)
        return StoredItem(id: id, parentID: parent, name: entry.name, displayName: displayName ?? entry.name,
                          isDirectory: entry.isDirectory, size: entry.size, modified: entry.modified,
                          mode: entry.mode, dev: entry.dev, ino: entry.ino)
    }

    private func markDeletedLocked(_ id: ItemID) throws {
        try database.run("UPDATE items SET deleted_at = ?2 WHERE id = ?1",
                         [.integer(id), .integer(Int64(Date().timeIntervalSince1970))])
        try appendChangeLocked(id, .deleted)
    }

    func appendChangeLocked(_ id: ItemID, _ kind: ChangeKind) throws {
        try database.run("INSERT INTO changes (item_id, kind, recorded_at) VALUES (?1, ?2, ?3)",
                         [.integer(id), .integer(kind.rawValue), .integer(Int64(Date().timeIntervalSince1970))])
    }

    func withLockAndTransaction<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock { try database.transaction(body) }
    }

    func invalidatePathCache() { pathCache.removeAll() }

    var db: SQLiteDatabase { database }
    var storeLock: NSRecursiveLock { lock }

    // MARK: - Row mapping

    static let selectColumns = """
        SELECT id, parent_id, name, display_name, is_dir, size, mtime, mode, dev, ino FROM items
        """

    static func decode(_ row: SQLiteRow) -> StoredItem {
        StoredItem(id: row.int64(0),
                   parentID: row.int64(1),
                   name: row.string(2),
                   displayName: row.string(3),
                   isDirectory: row.bool(4),
                   size: row.int64(5),
                   modified: Date(timeIntervalSince1970: TimeInterval(row.int64(6))),
                   mode: UInt32(truncatingIfNeeded: row.int64(7)),
                   dev: row.optionalUInt64(8),
                   ino: row.optionalUInt64(9))
    }
}
