import Foundation

/// The public entry point to AdbKit.
///
/// Speaks the adb protocols directly over TCP to the local adb server rather
/// than shelling out to the `adb` binary. That is not just faster — sandboxed
/// app extensions (which is what the Finder integration is) cannot spawn
/// subprocesses at all, so talking the wire protocol is the only option there.
public final class AdbClient: Sendable {
    public let endpoint: AdbEndpoint

    private let queue: DispatchQueue
    /// Caps how many blocking operations run at once.
    ///
    /// Every operation occupies a thread for the length of its socket I/O, so an
    /// unbounded concurrent queue lets GCD spawn one thread per in-flight
    /// request — and Finder will happily ask for a dozen directories at once.
    /// The adb server gains nothing from more parallelism than this anyway,
    /// since a single USB transport serialises underneath.
    private let gate: OperationQueue
    /// Long-lived streams (device tracking, the filesystem watcher) run here so
    /// they never occupy a slot in the bounded gate.
    let streamingQueue: DispatchQueue
    private let featureCache = FeatureCache()

    public init(endpoint: AdbEndpoint = .default) {
        self.endpoint = endpoint
        self.queue = DispatchQueue(label: "dev.sideport.adbkit.io",
                                   qos: .userInitiated,
                                   attributes: .concurrent)
        self.gate = OperationQueue()
        self.gate.underlyingQueue = queue
        self.gate.maxConcurrentOperationCount = 6
        self.gate.name = "dev.sideport.adbkit.io.gate"
        self.streamingQueue = DispatchQueue(label: "dev.sideport.adbkit.streams",
                                            qos: .utility,
                                            attributes: .concurrent)
    }

    // MARK: - Server

    /// Version of the local adb server, e.g. `41` for "1.0.41".
    public func serverVersion() async throws -> Int {
        try await run {
            let connection = try self.connect()
            defer { connection.close() }
            try connection.send("host:version")
            let hex = try connection.readLengthPrefixedString()
            guard let value = Int(hex, radix: 16) else {
                throw AdbError.protocolViolation("bad version \(hex.debugDescription)")
            }
            return value
        }
    }

    /// True when an adb server is listening. Never throws.
    public func isServerRunning() async -> Bool {
        (try? await serverVersion()) != nil
    }

    // MARK: - Devices

    public func devices() async throws -> [AdbDevice] {
        try await run {
            let connection = try self.connect()
            defer { connection.close() }
            try connection.send("host:devices-l")
            let payload = try connection.readLengthPrefixedString()
            return payload
                .split(separator: "\n")
                .compactMap { AdbDevice.parse(line: String($0)) }
        }
    }

    /// The single connected device, or an error explaining which of the two
    /// failure modes (none / ambiguous) applies.
    public func soleDevice() async throws -> AdbDevice {
        let usable = try await devices().filter { $0.state.isUsable }
        switch usable.count {
        case 1: return usable[0]
        case 0:
            let all = try await devices()
            if let stuck = all.first {
                throw AdbError.deviceUnavailable(serial: stuck.serial, state: stuck.state.rawValue)
            }
            throw AdbError.deviceNotFound("nothing connected")
        default:
            throw AdbError.deviceNotFound("\(usable.count) devices connected; specify a serial")
        }
    }

    /// Emits the full device list every time the adb server sees a change.
    /// This is the hot-plug signal the Finder integration needs.
    public func deviceChanges() -> AsyncThrowingStream<[AdbDevice], Error> {
        AsyncThrowingStream { continuation in
            streamingQueue.async {
                do {
                    // Long-lived: no read timeout, changes may be hours apart.
                    let connection = try AdbConnection(endpoint: self.endpoint, ioTimeout: 0)
                    defer { connection.close() }
                    // Cancelling only shuts the socket down; the read below
                    // then returns EOF and this thread performs the close.
                    let cancel = connection.canceller
                    continuation.onTermination = { _ in cancel() }

                    do {
                        try connection.send("host:track-devices-l")
                    } catch {
                        try connection.send("host:track-devices")
                    }
                    while true {
                        let payload = try connection.readLengthPrefixedString()
                        continuation.yield(payload
                            .split(separator: "\n")
                            .compactMap { AdbDevice.parse(line: String($0)) })
                    }
                } catch AdbError.unexpectedEOF {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Features

    public func features(for selector: DeviceSelector) async throws -> AdbFeatures {
        if let cached = featureCache.value(for: selector) { return cached }
        let features: AdbFeatures = try await run {
            let connection = try self.connect()
            defer { connection.close() }
            try connection.send("\(selector.hostPrefix)features")
            let payload = try connection.readLengthPrefixedString()
            return AdbFeatures(raw: Set(payload.split(separator: ",").map(String.init)))
        }
        featureCache.store(features, for: selector)
        return features
    }

    // MARK: - Sync sessions

    /// Runs `body` against an open sync session, then tears it down.
    ///
    /// Batch related work inside one call: opening a session costs a TCP
    /// connect plus a transport handshake, and Finder enumerations touch many
    /// paths at once.
    public func withSyncSession<T: Sendable>(
        _ selector: DeviceSelector,
        _ body: @escaping @Sendable (AdbSyncSession) throws -> T
    ) async throws -> T {
        let features = try await features(for: selector)
        return try await run {
            let connection = try self.connect()
            try connection.selectTransport(selector)
            try connection.send("sync:")
            let session = AdbSyncSession(connection: connection, features: features)
            defer { try? session.quit() }
            return try body(session)
        }
    }

    /// Lists a directory, refusing to report "empty" when it means "unreadable".
    ///
    /// `adbd`'s sync `LIST` answers `DONE` with no entries when its `opendir`
    /// fails, so on the wire an unreadable directory is byte-for-byte identical
    /// to an empty one. Taking that at face value is not a cosmetic problem: the
    /// reconciler would read zero entries as "everything here was deleted" and
    /// tombstone the lot. A phone that is locked before its first unlock, or
    /// mid-remount, or simply holding a directory that is not ours to read,
    /// would present as a phone whose storage had been wiped.
    ///
    /// So an empty result gets a second look, and only an empty result — the
    /// probe costs a shell round-trip and never runs on a directory that
    /// returned anything.
    public func list(_ path: String, on selector: DeviceSelector) async throws -> [AdbFileEntry] {
        let entries = try await withSyncSession(selector) { try $0.list(path) }
        if entries.isEmpty { try await confirmListable(path, on: selector) }
        return entries
    }

    /// Throws unless `path` is a directory we can actually enumerate.
    ///
    /// `ls -A` performs the same `opendir` the sync service does but reports the
    /// errno instead of swallowing it, which is the whole point.
    ///
    /// Public because callers that drive `AdbSyncSession.list` directly — to
    /// keep several operations on one session — bypass `list(_:on:)` and would
    /// otherwise inherit the very ambiguity this exists to remove.
    public func confirmListable(_ path: String, on selector: DeviceSelector) async throws {
        let command = "ls -A \(adbShellQuote(path)) >/dev/null"
        try await shell(command, on: selector).requireSuccess(command)
    }

    public func stat(_ path: String,
                     on selector: DeviceSelector,
                     followSymlinks: Bool = true) async throws -> AdbFileEntry {
        try await withSyncSession(selector) { try $0.stat(path, followSymlinks: followSymlinks) }
    }

    /// Pulls a file to a local URL. `progress` reports bytes-so-far and is
    /// called on a background queue.
    @discardableResult
    public func pull(_ remotePath: String,
                     to localURL: URL,
                     on selector: DeviceSelector,
                     progress: (@Sendable (Int64) throws -> Void)? = nil) async throws -> Int64 {
        try await withSyncSession(selector) { session in
            var transferred: Int64 = 0
            return try session.pull(remotePath, to: localURL) { delta in
                transferred += delta
                try progress?(transferred)
            }
        }
    }

    public func push(_ localURL: URL,
                     to remotePath: String,
                     on selector: DeviceSelector,
                     mode: UInt16 = 0o644,
                     progress: (@Sendable (Int64) throws -> Void)? = nil) async throws {
        try await withSyncSession(selector) { session in
            var transferred: Int64 = 0
            try session.push(localURL, to: remotePath, mode: mode) { delta in
                transferred += delta
                try progress?(transferred)
            }
        }
    }

    /// Uploads to a temporary name in the destination directory, then renames
    /// into place.
    ///
    /// Two problems solved by one mechanism. An interrupted direct `SEND` would
    /// leave the user's existing file truncated — `mv` within a directory is
    /// atomic, so the visible file either is the old one or the complete new
    /// one. And the sync protocol's `SEND` takes `"path,mode"`, splitting on the
    /// last comma, so a filename containing a comma is ambiguous; the UUID
    /// temporary name never contains one.
    public func pushAtomically(_ localURL: URL,
                               to remotePath: String,
                               on selector: DeviceSelector,
                               mode: UInt16 = 0o644,
                               progress: (@Sendable (Int64) throws -> Void)? = nil) async throws {
        let staging = Self.stagingPath(for: remotePath)
        do {
            try await push(localURL, to: staging, on: selector, mode: mode, progress: progress)
            try await move(from: staging, to: remotePath, on: selector)
        } catch {
            // Best effort: if the device is gone this fails too, and the sweep
            // on next connect will collect the leftover.
            try? await remove(staging, on: selector, recursive: false)
            throw error
        }
    }

    /// Prefix for in-flight uploads. Public so the orphan sweep and the
    /// enumerator can both recognise them.
    public static let stagingPrefix = ".sideport-tmp-"

    static func stagingPath(for remotePath: String) -> String {
        let directory = (remotePath as NSString).deletingLastPathComponent
        return "\(directory)/\(stagingPrefix)\(UUID().uuidString)"
    }

    /// Removes staging files left behind by transfers that died mid-flight.
    ///
    /// Only files older than `olderThanMinutes` are touched, so a transfer
    /// running right now in another process is never swept out from under it.
    @discardableResult
    public func sweepStagingFiles(under root: String,
                                  on selector: DeviceSelector,
                                  olderThanMinutes: Int = 60) async throws -> Int {
        let command = "find \(adbShellQuote(root)) -type f -name \(adbShellQuote(Self.stagingPrefix + "*")) "
            + "-mmin +\(olderThanMinutes) -print -delete 2>/dev/null | wc -l"
        let result = try await shell(command, on: selector)
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: - Shell

    public func shell(_ command: String, on selector: DeviceSelector) async throws -> ShellResult {
        let features = try await features(for: selector)
        return try await run {
            let connection = try self.connect()
            defer { connection.close() }
            try connection.selectTransport(selector)
            return features.shellV2
                ? try AdbShellRunner.runV2(connection: connection, command: command)
                : try AdbShellRunner.runLegacy(connection: connection, command: command)
        }
    }

    /// A name a person would actually recognise.
    ///
    /// `host:devices-l` only reports `ro.product.model`, which on many phones is
    /// a bare part number — this device calls itself `25053PC47I` there, while
    /// its owner and its Bluetooth name both say "POCO F7". Preference order is
    /// the name the owner chose, then the marketing name, then the model.
    ///
    /// One shell round trip, not five: the candidates run in sequence and the
    /// first usable line wins.
    public func deviceName(for selector: DeviceSelector) async throws -> String? {
        let probe = [
            "settings get global device_name 2>/dev/null",
            "getprop ro.product.marketname",
            "getprop ro.product.vendor.marketname",
            "getprop ro.product.odm.marketname",
            "getprop ro.product.model",
        ].joined(separator: "; ")

        let result = try await shell(probe, on: selector)
        for line in result.stdout.split(separator: "\n") {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // `settings get` prints the literal string "null" when unset.
            guard !candidate.isEmpty, candidate != "null" else { continue }
            return candidate
        }
        return nil
    }

    // MARK: - Namespace mutation
    //
    // The sync protocol can create and overwrite files but cannot make
    // directories, rename, or delete. Those go through the shell.

    public func makeDirectory(_ path: String, on selector: DeviceSelector) async throws {
        let command = "mkdir -p \(adbShellQuote(path))"
        try await shell(command, on: selector).requireSuccess(command)
    }

    public func remove(_ path: String, on selector: DeviceSelector, recursive: Bool = true) async throws {
        let command = "rm \(recursive ? "-rf" : "-f") \(adbShellQuote(path))"
        try await shell(command, on: selector).requireSuccess(command)
    }

    public func move(from source: String, to destination: String, on selector: DeviceSelector) async throws {
        let command = "mv -f \(adbShellQuote(source)) \(adbShellQuote(destination))"
        try await shell(command, on: selector).requireSuccess(command)
    }

    public func copy(from source: String, to destination: String, on selector: DeviceSelector) async throws {
        let command = "cp -a \(adbShellQuote(source)) \(adbShellQuote(destination))"
        try await shell(command, on: selector).requireSuccess(command)
    }

    /// Total and free bytes on the volume containing `path`.
    ///
    /// `-P` forces the POSIX single-line format; without it a long device name
    /// wraps onto its own line and the columns no longer line up.
    public func capacity(at path: String,
                         on selector: DeviceSelector) async throws -> (total: Int64, free: Int64)? {
        let result = try await shell("df -kP \(adbShellQuote(path)) | tail -1", on: selector)
        let fields = result.stdout.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4,
              let totalKB = Int64(fields[1]),
              let freeKB = Int64(fields[3]) else { return nil }
        return (totalKB * 1024, freeKB * 1024)
    }

    /// Free bytes on the volume containing `path`, for Finder's capacity display.
    public func availableCapacity(at path: String, on selector: DeviceSelector) async throws -> Int64? {
        try await capacity(at: path, on: selector)?.free
    }

    // MARK: - Plumbing

    internal func connect() throws -> AdbConnection {
        try AdbConnection(endpoint: endpoint)
    }

    /// Hops blocking socket work off the Swift cooperative pool, which must
    /// never be blocked or the whole concurrency runtime can stall.
    internal func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            gate.addOperation {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

/// Feature sets change only when a device is replaced, so caching them removes
/// a round trip from every single file operation.
private final class FeatureCache: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var storage: [DeviceSelector: AdbFeatures] = [:]

    func value(for selector: DeviceSelector) -> AdbFeatures? {
        lock.withLock { storage[selector] }
    }

    func store(_ features: AdbFeatures, for selector: DeviceSelector) {
        lock.withLock { storage[selector] = features }
    }
}
