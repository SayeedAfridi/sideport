import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Where the adb server lives. Almost always loopback:5037.
public struct AdbEndpoint: Sendable, Hashable {
    public var host: String
    public var port: UInt16

    public init(host: String = "127.0.0.1", port: UInt16 = 5037) {
        self.host = host
        self.port = port
    }

    /// Honours `ANDROID_ADB_SERVER_PORT` the same way the adb client does.
    public static var `default`: AdbEndpoint {
        var endpoint = AdbEndpoint()
        if let raw = ProcessInfo.processInfo.environment["ANDROID_ADB_SERVER_PORT"],
           let port = UInt16(raw) {
            endpoint.port = port
        }
        return endpoint
    }
}

/// Blocking POSIX TCP client.
///
/// Deliberately blocking: the adb protocols are strictly request/response and
/// far easier to get right synchronously. Every instance is confined to the
/// dispatch queue that created it, which is what makes the `@unchecked` safe.
final class AdbSocket: @unchecked Sendable {
    private var fd: Int32 = -1

    init(endpoint: AdbEndpoint, connectTimeout: TimeInterval, ioTimeout: TimeInterval) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(endpoint.host, String(endpoint.port), &hints, &list)
        guard rc == 0, let head = list else {
            throw AdbError.serverUnreachable("getaddrinfo: \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(list) }

        var lastError = "no usable address"
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let candidate = cursor {
            let s = socket(candidate.pointee.ai_family,
                           candidate.pointee.ai_socktype,
                           candidate.pointee.ai_protocol)
            if s >= 0 {
                do {
                    try AdbSocket.connect(s,
                                          address: candidate.pointee.ai_addr,
                                          length: candidate.pointee.ai_addrlen,
                                          timeout: connectTimeout)
                    AdbSocket.configure(s, ioTimeout: ioTimeout)
                    fd = s
                    return
                } catch {
                    lastError = (error as? AdbError).flatMap(\.errorDescription) ?? "\(error)"
                    Darwin.close(s)
                }
            } else {
                lastError = String(cString: strerror(errno))
            }
            cursor = candidate.pointee.ai_next
        }
        throw AdbError.serverUnreachable("\(endpoint.host):\(endpoint.port) — \(lastError)")
    }

    deinit { close() }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Wakes a read that is blocked on another thread, without closing the
    /// descriptor. Closing it here instead would risk the blocked reader
    /// touching a recycled fd; `shutdown` makes that read return clean EOF and
    /// lets the owning thread do the actual close.
    func cancel() {
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    // MARK: - I/O

    func write(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        var offset = 0
        try bytes.withUnsafeBytes { buffer in
            let base = buffer.baseAddress!
            while offset < bytes.count {
                let n = send(fd, base.advanced(by: offset), bytes.count - offset, 0)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 {
                    throw AdbError.socket("send: \(String(cString: strerror(errno)))")
                } else {
                    throw AdbError.unexpectedEOF
                }
            }
        }
    }

    func write(_ data: Data) throws { try write([UInt8](data)) }

    /// Reads exactly `count` bytes or throws.
    func readFully(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        try buffer.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            while offset < count {
                let n = recv(fd, base.advanced(by: offset), count - offset, 0)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 {
                    throw AdbError.socket("recv: \(String(cString: strerror(errno)))")
                } else {
                    throw AdbError.unexpectedEOF
                }
            }
        }
        return buffer
    }

    /// Reads whatever is available, up to `max`. Empty result means clean EOF.
    func readSome(max: Int = 64 * 1024) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: max)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress!, max, 0) }
            if n > 0 { return Array(buffer[0..<n]) }
            if n == 0 { return [] }
            if errno == EINTR { continue }
            throw AdbError.socket("recv: \(String(cString: strerror(errno)))")
        }
    }

    /// Drains the stream until the peer closes it.
    func readToEnd() throws -> [UInt8] {
        var out: [UInt8] = []
        while true {
            let chunk = try readSome()
            if chunk.isEmpty { return out }
            out.append(contentsOf: chunk)
        }
    }

    // MARK: - Setup helpers

    private static func configure(_ fd: Int32, ioTimeout: TimeInterval) {
        var on: Int32 = 1
        // Never let a dead peer raise SIGPIPE and kill the host process.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: Int(ioTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Non-blocking connect with an explicit timeout, then back to blocking.
    private static func connect(_ fd: Int32,
                                address: UnsafeMutablePointer<sockaddr>?,
                                length: socklen_t,
                                timeout: TimeInterval) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }

        if Darwin.connect(fd, address, length) == 0 { return }
        guard errno == EINPROGRESS else {
            throw AdbError.serverUnreachable(String(cString: strerror(errno)))
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(timeout * 1000))
        if ready == 0 { throw AdbError.serverUnreachable("connect timed out") }
        if ready < 0 { throw AdbError.serverUnreachable(String(cString: strerror(errno))) }

        var soError: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &size)
        if soError != 0 {
            throw AdbError.serverUnreachable(String(cString: strerror(soError)))
        }
    }
}
