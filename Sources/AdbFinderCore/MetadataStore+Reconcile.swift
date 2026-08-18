import AdbKit
import Foundation

extension MetadataStore {
    /// Folds a fresh directory listing into the store and reports what changed.
    ///
    /// The order of the passes is the whole algorithm. Matching names first, then
    /// inode-based move detection, and only then treating leftovers as
    /// created/deleted is what makes a rename come out as one `moved` rather than
    /// a `deleted` plus a `created` — which would destroy the item's identity in
    /// Finder and collapse any open document.
    @discardableResult
    public func reconcile(directory id: ItemID, listing: [AdbFileEntry]) throws -> ReconcileResult {
        try storeLock.withLock {
            let result = try db.transaction { try reconcileLocked(directory: id, listing: listing) }
            if !result.moved.isEmpty || !result.deleted.isEmpty { invalidatePathCache() }
            return result
        }
    }

    private func reconcileLocked(directory id: ItemID, listing: [AdbFileEntry]) throws -> ReconcileResult {
        guard let directory = try db.queryOne(Self.selectColumns + " WHERE id = ?1 AND deleted_at IS NULL",
                                              [.integer(id)], row: Self.decode) else {
            throw CoreError.itemNotFound(id)
        }
        guard directory.isDirectory else { throw CoreError.notADirectory(id) }

        let existing = try db.query(Self.selectColumns + " WHERE parent_id = ?1 AND deleted_at IS NULL AND id != ?1",
                                    [.integer(id)], row: Self.decode)
        var byName = [String: StoredItem](uniqueKeysWithValues: existing.map { ($0.name, $0) })

        // Display names depend on the whole directory, so they are resolved once
        // over the incoming listing rather than per entry.
        let displayNames = DisplayName.resolve(listing.map(\.name))

        var result = ReconcileResult()
        var claimed = Set<ItemID>()

        for entry in listing {
            let display = displayNames[entry.name] ?? entry.name

            // Pass 1 — same name in the same directory.
            if let current = byName[entry.name] {
                claimed.insert(current.id)
                if let updated = try applyIfChanged(current, entry: entry, display: display, parent: id) {
                    result.modified.append(updated)
                }
                continue
            }

            // Pass 2 — a name we have not seen here, but an inode we have seen
            // elsewhere: the file moved rather than being recreated.
            if let source = try moveSource(for: entry, excluding: claimed, directory: id) {
                claimed.insert(source.id)
                try db.run("""
                    UPDATE items SET parent_id = ?2, name = ?3, display_name = ?4,
                                     size = ?5, mtime = ?6, mode = ?7 WHERE id = ?1
                    """, [.integer(source.id), .integer(id), .text(entry.name), .text(display),
                          .integer(entry.size), .integer(Int64(entry.modified.timeIntervalSince1970)),
                          .integer(Int64(entry.mode))])
                try appendChangeLocked(source.id, .moved)
                result.moved.append(rebuild(source, entry: entry, display: display, parent: id))
                continue
            }

            // Pass 3 — genuinely new.
            result.created.append(try insertLockedForReconcile(childOf: id, entry: entry, display: display))
        }

        // Pass 4 — anything left unclaimed is gone.
        for (_, orphan) in byName where !claimed.contains(orphan.id) {
            try db.run("UPDATE items SET deleted_at = ?2 WHERE id = ?1",
                       [.integer(orphan.id), .integer(Int64(Date().timeIntervalSince1970))])
            try appendChangeLocked(orphan.id, .deleted)
            result.deleted.append(orphan.id)
        }
        byName.removeAll()

        result.anchor = try currentAnchorLocked()
        return result
    }

    /// Updates a row only when something Finder would notice actually differs,
    /// so an unchanged directory produces no change-log churn at all.
    private func applyIfChanged(_ current: StoredItem, entry: AdbFileEntry,
                                display: String, parent: ItemID) throws -> StoredItem? {
        let sameContent = current.size == entry.size
            && Int64(current.modified.timeIntervalSince1970) == Int64(entry.modified.timeIntervalSince1970)
        let sameMetadata = current.mode == entry.mode && current.displayName == display
        guard !(sameContent && sameMetadata) else { return nil }

        try db.run("""
            UPDATE items SET display_name = ?2, size = ?3, mtime = ?4, mode = ?5, dev = ?6, ino = ?7
            WHERE id = ?1
            """, [.integer(current.id), .text(display), .integer(entry.size),
                  .integer(Int64(entry.modified.timeIntervalSince1970)), .integer(Int64(entry.mode)),
                  .optionalInteger(entry.dev), .optionalInteger(entry.ino)])
        try appendChangeLocked(current.id, .modified)
        return rebuild(current, entry: entry, display: display, parent: parent)
    }

    /// Finds a live row elsewhere carrying this entry's `(dev, ino)`.
    ///
    /// Returns nil when the device gave us no inode — legacy `ls_v2`-less
    /// devices — in which case a move degrades to delete-plus-create. That is
    /// noisier for Finder but never incorrect.
    ///
    /// Assumes emulated storage does not expose hard links, which holds for
    /// `/storage/emulated/0`. Two hard links to one file would share an inode
    /// and could be misread as a move.
    private func moveSource(for entry: AdbFileEntry, excluding claimed: Set<ItemID>,
                            directory: ItemID) throws -> StoredItem? {
        guard let dev = entry.dev, let ino = entry.ino, ino != 0 else { return nil }
        let candidates = try db.query(Self.selectColumns + " WHERE dev = ?1 AND ino = ?2 AND deleted_at IS NULL",
                                      [.integer(Int64(bitPattern: dev)), .integer(Int64(bitPattern: ino))],
                                      row: Self.decode)
        return candidates.first { $0.id != directory && $0.id != MetadataStore.rootID && !claimed.contains($0.id) }
    }

    private func insertLockedForReconcile(childOf parent: ItemID, entry: AdbFileEntry,
                                          display: String) throws -> StoredItem {
        try db.run("""
            INSERT INTO items (parent_id, name, display_name, is_dir, size, mtime, mode, dev, ino)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            """, [.integer(parent), .text(entry.name), .text(display),
                  .boolean(entry.isDirectory), .integer(entry.size),
                  .integer(Int64(entry.modified.timeIntervalSince1970)), .integer(Int64(entry.mode)),
                  .optionalInteger(entry.dev), .optionalInteger(entry.ino)])
        let id = db.lastInsertedID
        try appendChangeLocked(id, .created)
        return StoredItem(id: id, parentID: parent, name: entry.name, displayName: display,
                          isDirectory: entry.isDirectory, size: entry.size, modified: entry.modified,
                          mode: entry.mode, dev: entry.dev, ino: entry.ino)
    }

    private func rebuild(_ current: StoredItem, entry: AdbFileEntry,
                         display: String, parent: ItemID) -> StoredItem {
        StoredItem(id: current.id, parentID: parent, name: entry.name, displayName: display,
                   isDirectory: entry.isDirectory, size: entry.size, modified: entry.modified,
                   mode: entry.mode, dev: entry.dev ?? current.dev, ino: entry.ino ?? current.ino)
    }
}
