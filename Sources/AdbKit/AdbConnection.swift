import Foundation

/// One connection to the adb server, speaking the "smart socket" host protocol.
///
/// Wire format: every request is `%04x` of the payload length followed by the
/// ASCII payload. Every response starts with `OKAY` or `FAIL`; `FAIL` is
/// followed by a length-prefixed reason.
///
/// A connection is single-use for host services (the server hangs up after
/// answering) but becomes a long-lived device stream once a transport is
/// selected — that is how `sync:` and `shell:` sessions are born.
final class AdbConnection {
    private let socket: AdbSocket

    init(endpoint: AdbEndpoint,
         connectTimeout: TimeInterval = 5,
         ioTimeout: TimeInterval = 60) throws {
        socket = try AdbSocket(endpoint: endpoint,
                               connectTimeout: connectTimeout,
                               ioTimeout: ioTimeout)
    }

    func close() { socket.close() }

    /// A handle that can interrupt this connection from another thread. The
    /// `AdbConnection` itself is thread-confined, but the underlying socket is
    /// safe to shut down concurrently.
    var canceller: @Sendable () -> Void {
        let socket = self.socket
        return { socket.cancel() }
    }

    // MARK: - Framing

    /// Sends a request and consumes the OKAY/FAIL status.
    func send(_ request: String) throws {
        let payload = Array(request.utf8)
        guard payload.count <= 0xFFFF else {
            throw AdbError.protocolViolation("request longer than 65535 bytes")
        }
        var frame = Array(String(format: "%04x", payload.count).utf8)
        frame.append(contentsOf: payload)
        try socket.write(frame)
        try readStatus()
    }

    private func readStatus() throws {
        let status = try String(decoding: socket.readFully(4), as: UTF8.self)
        switch status {
        case "OKAY":
            return
        case "FAIL":
            throw AdbError.requestFailed(try readLengthPrefixedString())
        default:
            throw AdbError.protocolViolation("expected OKAY/FAIL, got \(status.debugDescription)")
        }
    }

    /// Reads a `%04x`-length-prefixed payload (used by host services).
    func readLengthPrefixedString() throws -> String {
        let header = try String(decoding: socket.readFully(4), as: UTF8.self)
        guard let length = Int(header, radix: 16) else {
            throw AdbError.protocolViolation("bad length header \(header.debugDescription)")
        }
        guard length > 0 else { return "" }
        return String(decoding: try socket.readFully(length), as: UTF8.self)
    }

    // MARK: - Raw stream access (post-transport)

    func writeRaw(_ bytes: [UInt8]) throws { try socket.write(bytes) }
    func readRaw(_ count: Int) throws -> [UInt8] { try socket.readFully(count) }
    func readRawSome(max: Int = 64 * 1024) throws -> [UInt8] { try socket.readSome(max: max) }
    func readRawToEnd() throws -> [UInt8] { try socket.readToEnd() }

    // MARK: - Transports

    /// Binds this connection to a device. Afterwards the next `send` must be a
    /// device service such as `sync:` or `shell,v2,raw:...`.
    func selectTransport(_ selector: DeviceSelector) throws {
        try send(selector.transportRequest)
    }
}

/// How to pick a device when more than one is attached.
public enum DeviceSelector: Sendable, Hashable {
    case serial(String)
    case anyUSB
    case anyEmulator
    /// Exactly one device must be attached, otherwise the server errors.
    case only

    var transportRequest: String {
        switch self {
        case .serial(let serial): return "host:transport:\(serial)"
        case .anyUSB: return "host:transport-usb"
        case .anyEmulator: return "host:transport-local"
        case .only: return "host:transport-any"
        }
    }

    /// Prefix for `host-serial:`-style queries that do not open a transport.
    var hostPrefix: String {
        switch self {
        case .serial(let serial): return "host-serial:\(serial):"
        case .anyUSB: return "host-usb:"
        case .anyEmulator: return "host-local:"
        case .only: return "host:"
        }
    }
}
