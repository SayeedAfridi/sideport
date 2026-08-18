import Foundation

extension MetadataStore {
    /// The anchor a client should quote back to us. Zero means "seen nothing".
    public func currentAnchor() throws -> Int64 {
        try storeLock.withLock { try currentAnchorLocked() }
    }

    func currentAnchorLocked() throws -> Int64 {
        try db.queryOne("SELECT COALESCE(MAX(anchor), 0) FROM changes") { $0.int64(0) } ?? 0
    }

    /// Replays everything recorded after `anchor`.
    ///
    /// Throws `.anchorExpired` when the caller is asking about changes we have
    /// already pruned. That is not a failure — it tells the system to
    /// re-enumerate from scratch, which is the safety valve that stops a stale
    /// incremental state from persisting forever.
    public func changes(since anchor: Int64) throws -> [ItemChange] {
        try storeLock.withLock {
            guard anchor >= (try prunedThroughLocked()) else { throw CoreError.anchorExpired }
            return try db.query("SELECT anchor, item_id, kind FROM changes WHERE anchor > ?1 ORDER BY anchor",
                                [.integer(anchor)]) { row in
                ItemChange(anchor: row.int64(0),
                           itemID: row.int64(1),
                           kind: ChangeKind(rawValue: row.int(2)) ?? .modified)
            }
        }
    }

    /// Highest anchor we have discarded. A client at or below this must restart.
    public func prunedThrough() throws -> Int64 {
        try storeLock.withLock { try prunedThroughLocked() }
    }

    func prunedThroughLocked() throws -> Int64 {
        let raw = try db.queryOne("SELECT value FROM meta WHERE key = 'pruned_through'") { $0.string(0) }
        return raw.flatMap(Int64.init) ?? 0
    }

    /// Trims the change log. Rows are dropped when they are older than
    /// `olderThan` *or* fall outside the newest `keepingAtMost`.
    ///
    /// Returns the new pruned-through anchor.
    @discardableResult
    public func pruneChangeLog(olderThan age: TimeInterval = 24 * 60 * 60,
                               keepingAtMost limit: Int = 50_000) throws -> Int64 {
        try storeLock.withLock {
            try db.transaction {
                var threshold = try prunedThroughLocked()

                let cutoff = Int64(Date().addingTimeInterval(-age).timeIntervalSince1970)
                if let byAge = try db.queryOne("SELECT MAX(anchor) FROM changes WHERE recorded_at < ?1",
                                               [.integer(cutoff)], row: { $0.isNull(0) ? nil : $0.int64(0) }) ?? nil {
                    threshold = max(threshold, byAge)
                }

                // The row just past the retention window; everything at or below
                // it is excess.
                if let byCount = try db.queryOne("SELECT anchor FROM changes ORDER BY anchor DESC LIMIT 1 OFFSET ?1",
                                                 [.integer(limit)], row: { $0.int64(0) }) {
                    threshold = max(threshold, byCount)
                }

                guard threshold > 0 else { return threshold }
                try db.run("DELETE FROM changes WHERE anchor <= ?1", [.integer(threshold)])
                try db.run("INSERT INTO meta (key, value) VALUES ('pruned_through', ?1) "
                           + "ON CONFLICT(key) DO UPDATE SET value = ?1",
                           [.text(String(threshold))])
                return threshold
            }
        }
    }
}
