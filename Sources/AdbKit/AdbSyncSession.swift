import Foundation

/// The device's `sync:` service — how adb itself implements push and pull.
///
/// A session stays open across many operations, which matters a lot for Finder:
/// enumerating a directory tree over one session avoids a TCP connect and a
/// transport handshake per directory.
///
/// Not thread-safe; confined to the queue that created it.
public final class AdbSyncSession {
    /// adb never puts more than 64 KiB in a single DATA packet.
    static let maxChunk = 64 * 1024
    /// The device-side limit on a sync path argument.
    static let maxPathLength = 1024

    private let connection: AdbConnection
    private let features: AdbFeatures
    private var isValid = true

    init(connection: AdbConnection, features: AdbFeatures) {
        self.connection = connection
        self.features = features
    }

    deinit { try? quit() }

    /// Ends the session politely so the device can release its handles.
    public func quit() throws {
        guard isValid else { return }
        isValid = false
        try? connection.writeRaw(ByteCodec.id("QUIT") + ByteCodec.u32(0))
        connection.close()
    }

    // MARK: - Packet plumbing

    private func send(id: String, payload: [UInt8]) throws {
        try ensureValid()
        try connection.writeRaw(ByteCodec.id(id) + ByteCodec.u32(UInt32(payload.count)) + payload)
    }

    private func send(id: String, path: String) throws {
        let payload = Array(path.utf8)
        guard payload.count <= Self.maxPathLength else {
            throw AdbError.invalidPath("\(path) (exceeds \(Self.maxPathLength) bytes)")
        }
        try send(id: id, payload: payload)
    }

    private func readPacketID() throws -> String {
        String(decoding: try connection.readRaw(4), as: UTF8.self)
    }

    private func readU32() throws -> UInt32 {
        ByteCodec.readU32(try connection.readRaw(4), at: 0)
    }

    /// Consumes a `FAIL` body and throws. Any FAIL poisons the session because
    /// the device may not have drained our pending bytes.
    private func failure() throws -> Never {
        let length = Int(try readU32())
        let message = String(decoding: try connection.readRaw(length), as: UTF8.self)
        isValid = false
        throw AdbError.syncFailed(message)
    }

    private func ensureValid() throws {
        guard isValid else {
            throw AdbError.protocolViolation("sync session is no longer usable")
        }
    }

    // MARK: - Listing

    /// Lists a directory. Entries are `lstat`-shaped: a symlink reports as a
    /// symlink, not as its target.
    public func list(_ path: String) throws -> [AdbFileEntry] {
        features.listV2 ? try listV2(path) : try listV1(path)
    }

    private func listV1(_ path: String) throws -> [AdbFileEntry] {
        try send(id: "LIST", path: path)
        var entries: [AdbFileEntry] = []
        while true {
            switch try readPacketID() {
            case "DENT":
                let header = try connection.readRaw(16)
                let mode = ByteCodec.readU32(header, at: 0)
                let size = ByteCodec.readU32(header, at: 4)
                let mtime = ByteCodec.readU32(header, at: 8)
                let nameLength = Int(ByteCodec.readU32(header, at: 12))
                let name = String(decoding: try connection.readRaw(nameLength), as: UTF8.self)
                if name == "." || name == ".." { continue }
                entries.append(AdbFileEntry(name: name,
                                            mode: mode,
                                            size: Int64(size),
                                            modified: Date(timeIntervalSince1970: TimeInterval(mtime))))
            case "DONE":
                _ = try connection.readRaw(16)
                return entries
            case "FAIL":
                try failure()
            case let other:
                isValid = false
                throw AdbError.protocolViolation("unexpected packet \(other.debugDescription) during LIST")
            }
        }
    }

    /// `LIS2` carries 64-bit sizes and timestamps, so files over 4 GiB and
    /// post-2038 mtimes survive the trip.
    private func listV2(_ path: String) throws -> [AdbFileEntry] {
        try send(id: "LIS2", path: path)
        var entries: [AdbFileEntry] = []
        while true {
            switch try readPacketID() {
            case "DNT2":
                let header = try connection.readRaw(72)
                let error = ByteCodec.readU32(header, at: 0)
                let mode = ByteCodec.readU32(header, at: 20)
                let size = ByteCodec.readU64(header, at: 36)
                let mtime = ByteCodec.readI64(header, at: 52)
                let nameLength = Int(ByteCodec.readU32(header, at: 68))
                let name = String(decoding: try connection.readRaw(nameLength), as: UTF8.self)
                // A per-entry errno (permission denied on a single child, say)
                // must not abort the whole listing.
                if error != 0 || name == "." || name == ".." { continue }
                entries.append(AdbFileEntry(name: name,
                                            mode: mode,
                                            size: Int64(bitPattern: size),
                                            modified: Date(timeIntervalSince1970: TimeInterval(mtime)),
                                            dev: ByteCodec.readU64(header, at: 4),
                                            ino: ByteCodec.readU64(header, at: 12)))
            case "DONE":
                _ = try connection.readRaw(72)
                return entries
            case "FAIL":
                try failure()
            case let other:
                isValid = false
                throw AdbError.protocolViolation("unexpected packet \(other.debugDescription) during LIS2")
            }
        }
    }

    // MARK: - Stat

    /// Stats a single path. A non-existent path comes back with `exists == false`
    /// rather than throwing, matching adb's own behaviour.
    public func stat(_ path: String, followSymlinks: Bool = true) throws -> AdbFileEntry {
        let name = (path as NSString).lastPathComponent
        guard features.statV2 else {
            try send(id: "STAT", path: path)
            guard try readPacketID() == "STAT" else {
                isValid = false
                throw AdbError.protocolViolation("expected STAT reply")
            }
            let body = try connection.readRaw(12)
            return AdbFileEntry(name: name,
                                mode: ByteCodec.readU32(body, at: 0),
                                size: Int64(ByteCodec.readU32(body, at: 4)),
                                modified: Date(timeIntervalSince1970: TimeInterval(ByteCodec.readU32(body, at: 8))))
        }

        let requestID = followSymlinks ? "STA2" : "LST2"
        try send(id: requestID, path: path)
        guard try readPacketID() == requestID else {
            isValid = false
            throw AdbError.protocolViolation("expected \(requestID) reply")
        }
        // 68 bytes, not 72: `sync_stat_v2` is `sync_dent_v2` minus the
        // trailing `namelen`. Reading one word short here desyncs the stream
        // and the *next* operation on the session is what fails.
        let body = try connection.readRaw(68)
        let error = ByteCodec.readU32(body, at: 0)
        guard error == 0 else {
            // errno from the device: report as "does not exist" shaped entry.
            return AdbFileEntry(name: name, mode: 0, size: 0, modified: .distantPast)
        }
        return AdbFileEntry(name: name,
                            mode: ByteCodec.readU32(body, at: 20),
                            size: Int64(bitPattern: ByteCodec.readU64(body, at: 36)),
                            modified: Date(timeIntervalSince1970: TimeInterval(ByteCodec.readI64(body, at: 52))),
                            dev: ByteCodec.readU64(body, at: 4),
                            ino: ByteCodec.readU64(body, at: 12))
    }

    // MARK: - Pull

    /// Streams a device file, handing each chunk to `consume` as it arrives.
    /// Returns the total number of bytes received.
    @discardableResult
    public func receive(_ path: String, consume: (Data) throws -> Void) throws -> Int64 {
        try send(id: "RECV", path: path)
        var total: Int64 = 0
        while true {
            switch try readPacketID() {
            case "DATA":
                let length = Int(try readU32())
                guard length <= Self.maxChunk else {
                    isValid = false
                    throw AdbError.protocolViolation("DATA chunk of \(length) bytes exceeds protocol maximum")
                }
                let chunk = try connection.readRaw(length)
                total += Int64(length)
                try consume(Data(chunk))
            case "DONE":
                _ = try connection.readRaw(4)
                return total
            case "FAIL":
                try failure()
            case let other:
                isValid = false
                throw AdbError.protocolViolation("unexpected packet \(other.debugDescription) during RECV")
            }
        }
    }

    /// Pulls a device file to a local URL, replacing anything already there.
    ///
    /// Socket to file descriptor through a single reusable buffer: no `Data` is
    /// allocated per chunk, so a multi-gigabyte pull costs the same memory as a
    /// small one.
    @discardableResult
    public func pull(_ remotePath: String,
                     to localURL: URL,
                     progress: ((Int64) throws -> Void)? = nil) throws -> Int64 {
        let manager = FileManager.default
        try? manager.removeItem(at: localURL)

        let descriptor = open(localURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else {
            throw AdbError.localIOFailure(errno, "cannot create \(localURL.path)")
        }
        var closed = false
        defer { if !closed { close(descriptor) } }

        do {
            try send(id: "RECV", path: remotePath)
            var buffer = [UInt8](repeating: 0, count: Self.maxChunk)
            var total: Int64 = 0

            try buffer.withUnsafeMutableBytes { raw in
                while true {
                    switch try readPacketID() {
                    case "DATA":
                        let length = Int(try readU32())
                        guard length <= Self.maxChunk else {
                            isValid = false
                            throw AdbError.protocolViolation(
                                "DATA chunk of \(length) bytes exceeds protocol maximum")
                        }
                        try connection.readRaw(into: raw, count: length)
                        try Self.writeFully(descriptor, raw.baseAddress!, length)
                        total += Int64(length)
                        try progress?(Int64(length))
                    case "DONE":
                        _ = try connection.readRaw(4)
                        return
                    case "FAIL":
                        try failure()
                    case let other:
                        isValid = false
                        throw AdbError.protocolViolation(
                            "unexpected packet \(other.debugDescription) during RECV")
                    }
                }
            }

            close(descriptor)
            closed = true
            return total
        } catch {
            close(descriptor)
            closed = true
            try? manager.removeItem(at: localURL)
            throw error
        }
    }

    private static func writeFully(_ descriptor: Int32,
                                   _ base: UnsafeRawPointer,
                                   _ count: Int) throws {
        var offset = 0
        while offset < count {
            let written = write(descriptor, base.advanced(by: offset), count - offset)
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                throw AdbError.localIOFailure(errno, "write")
            }
        }
    }

    // MARK: - Push

    /// Pushes a local file to the device, preserving its mtime.
    /// `progress` may throw to abort the transfer, which is how a cancelled
    /// Finder upload stops without waiting for gigabytes to finish.
    ///
    /// Streams through one reusable frame buffer — an 8-byte `DATA` header
    /// followed by the payload, filled in place by `read(2)` and written with a
    /// single `send`. The obvious `FileHandle.read(upToCount:)` loop instead
    /// held the whole file resident: 256 MB pushed peaked at 269 MB RSS.
    public func push(_ localURL: URL,
                     to remotePath: String,
                     mode: UInt16 = 0o644,
                     progress: ((Int64) throws -> Void)? = nil) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let modified = (attributes[.modificationDate] as? Date) ?? Date()

        let descriptor = open(localURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw AdbError.localIOFailure(errno, "cannot read \(localURL.path)")
        }
        defer { close(descriptor) }
        // Read once, sequentially, and do not pollute the page cache with a file
        // we will never look at again.
        _ = fcntl(descriptor, F_RDAHEAD, 1)
        _ = fcntl(descriptor, F_NOCACHE, 1)

        // The device parses "path,mode" — the comma is the separator, so a
        // literal comma in the filename would be misread. `pushAtomically`
        // stages through a UUID name, which never contains one.
        try send(id: "SEND", path: "\(remotePath),\(mode)")

        var frame = [UInt8](repeating: 0, count: 8 + Self.maxChunk)
        try frame.withUnsafeMutableBytes { raw in
            // The packet id never changes; write it once.
            raw[0] = UInt8(ascii: "D")
            raw[1] = UInt8(ascii: "A")
            raw[2] = UInt8(ascii: "T")
            raw[3] = UInt8(ascii: "A")
            let payload = raw.baseAddress!.advanced(by: 8)

            while true {
                var count = 0
                while true {
                    count = read(descriptor, payload, Self.maxChunk)
                    if count >= 0 || errno != EINTR { break }
                }
                guard count >= 0 else {
                    throw AdbError.localIOFailure(errno, "read")
                }
                if count == 0 { break }

                let length = UInt32(count)
                raw[4] = UInt8(length & 0xFF)
                raw[5] = UInt8((length >> 8) & 0xFF)
                raw[6] = UInt8((length >> 16) & 0xFF)
                raw[7] = UInt8((length >> 24) & 0xFF)

                try connection.writeRaw(UnsafeRawBufferPointer(
                    UnsafeMutableRawBufferPointer(rebasing: raw[0..<(8 + count)])))
                try progress?(Int64(count))
            }
        }

        try connection.writeRaw(ByteCodec.id("DONE")
                                + ByteCodec.u32(UInt32(max(0, modified.timeIntervalSince1970))))
        try finishSend()
    }

    /// Consumes the `OKAY`/`FAIL` that closes a `SEND`.
    private func finishSend() throws {
        switch try readPacketID() {
        case "OKAY":
            _ = try connection.readRaw(4)
        case "FAIL":
            try failure()
        case let other:
            isValid = false
            throw AdbError.protocolViolation("unexpected packet \(other.debugDescription) after SEND")
        }
    }

    /// Pushes in-memory data (used for small writes from Finder).
    public func push(data: Data,
                     to remotePath: String,
                     mode: UInt16 = 0o644,
                     modified: Date = Date()) throws {
        try send(id: "SEND", path: "\(remotePath),\(mode)")
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.maxChunk, data.count)
            try send(id: "DATA", payload: [UInt8](data[offset..<end]))
            offset = end
        }
        try connection.writeRaw(ByteCodec.id("DONE") + ByteCodec.u32(UInt32(max(0, modified.timeIntervalSince1970))))
        try finishSend()
    }
}
