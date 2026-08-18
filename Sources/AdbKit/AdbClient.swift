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
    private let featureCache = FeatureCache()

    public init(endpoint: AdbEndpoint = .default) {
        self.endpoint = endpoint
        self.queue = DispatchQueue(label: "dev.finderadb.adbkit.io",
                                   qos: .userInitiated,
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
            queue.async {
                do {
                    // Long-lived: no read timeout, changes may be hours apart.
                    let connection = try AdbConnection(endpoint: self.endpoint, ioTimeout: 0)
                    defer { connection.close() }
                    // Cancelling only shuts the socket down; the read below
                    // then returns EOF and this thread performs the close.
                    continuation.onTermination = { _ in connection.canceller() }

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

    public func list(_ path: String, on selector: DeviceSelector) async throws -> [AdbFileEntry] {
        try await withSyncSession(selector) { try $0.list(path) }
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
                     progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Int64 {
        try await withSyncSession(selector) { session in
            var transferred: Int64 = 0
            return try session.pull(remotePath, to: localURL) { delta in
                transferred += delta
                progress?(transferred)
            }
        }
    }

    public func push(_ localURL: URL,
                     to remotePath: String,
                     on selector: DeviceSelector,
                     mode: UInt16 = 0o644,
                     progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        try await withSyncSession(selector) { session in
            var transferred: Int64 = 0
            try session.push(localURL, to: remotePath, mode: mode) { delta in
                transferred += delta
                progress?(transferred)
            }
        }
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

    /// Free bytes on the volume containing `path`, for Finder's capacity display.
    public func availableCapacity(at path: String, on selector: DeviceSelector) async throws -> Int64? {
        let result = try await shell("df -kP \(adbShellQuote(path)) | tail -1", on: selector)
        let fields = result.stdout.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4, let kilobytes = Int64(fields[3]) else { return nil }
        return kilobytes * 1024
    }

    // MARK: - Plumbing

    private func connect() throws -> AdbConnection {
        try AdbConnection(endpoint: endpoint)
    }

    /// Hops blocking socket work off the Swift cooperative pool, which must
    /// never be blocked or the whole concurrency runtime can stall.
    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
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
