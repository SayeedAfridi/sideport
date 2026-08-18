import Foundation

/// A snapshot of what a device is currently transferring.
///
/// Finder shows per-copy progress already; this exists so the menu bar can
/// answer the different question of "is anything still going on?" without
/// opening a window.
public struct TransferActivity: Codable, Sendable, Equatable {
    public var active: Int
    public var bytes: Int64
    public var updated: Date

    public init(active: Int = 0, bytes: Int64 = 0, updated: Date = Date()) {
        self.active = active
        self.bytes = bytes
        self.updated = updated
    }

    /// Treated as idle once stale: an extension killed mid-transfer would
    /// otherwise leave the menu claiming work forever.
    public var isStale: Bool { Date().timeIntervalSince(updated) > 10 }
    public var isBusy: Bool { active > 0 && !isStale }
}

/// Cross-process transfer reporting through the App Group container.
///
/// The extension writes and the app reads. Writes are throttled and atomic: a
/// progress callback fires per 64 KiB chunk, and touching the disk that often
/// would cost more than the transfer itself.
///
/// Each transfer reports its *own running total* rather than a delta. AdbKit's
/// progress callbacks are cumulative, and treating them as increments makes the
/// reported figure grow quadratically — a 40 MB copy claimed 13.4 GB.
public final class TransferReporter: @unchecked Sendable {
    /// Handle for one in-flight transfer. Summing per-transfer totals is what
    /// keeps concurrent copies accurate.
    public final class Token: @unchecked Sendable {
        fileprivate let id = UUID()
        private let reporter: TransferReporter

        fileprivate init(reporter: TransferReporter) { self.reporter = reporter }

        /// Total bytes moved by *this* transfer so far.
        public func report(_ totalBytes: Int64) { reporter.update(id, to: totalBytes) }
        public func finish() { reporter.finish(id) }
    }

    private let url: URL?
    private let lock = NSLock()
    private var inFlight: [UUID: Int64] = [:]
    private var lastWrite = Date.distantPast

    public init(serial: String) {
        url = try? FinderADB.storeURL(forSerial: serial)
            .deletingLastPathComponent()
            .appendingPathComponent("activity.json")
    }

    public func begin() -> Token {
        let token = Token(reporter: self)
        lock.withLock { inFlight[token.id] = 0 }
        write(force: true)
        return token
    }

    private func update(_ id: UUID, to totalBytes: Int64) {
        lock.withLock { inFlight[id] = totalBytes }
        write(force: false)
    }

    private func finish(_ id: UUID) {
        lock.withLock { inFlight.removeValue(forKey: id) }
        write(force: true)
    }

    private func write(force: Bool) {
        guard let url else { return }
        let snapshot: TransferActivity? = lock.withLock {
            // At most once a second unless a transfer just started or finished.
            guard force || Date().timeIntervalSince(lastWrite) >= 1 else { return nil }
            lastWrite = Date()
            return TransferActivity(active: inFlight.count,
                                    bytes: inFlight.values.reduce(0, +),
                                    updated: Date())
        }
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Reads whatever the extension last reported for a device.
    public static func read(serial: String) -> TransferActivity {
        guard let url = try? FinderADB.storeURL(forSerial: serial)
                .deletingLastPathComponent()
                .appendingPathComponent("activity.json"),
              let data = try? Data(contentsOf: url),
              let activity = try? JSONDecoder().decode(TransferActivity.self, from: data) else {
            return TransferActivity(active: 0, bytes: 0, updated: .distantPast)
        }
        return activity
    }
}
