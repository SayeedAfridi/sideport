import Foundation

extension AdbClient {
    /// Reads `length` bytes of a device file starting at `offset`.
    ///
    /// The sync protocol has no notion of a range: `RECV` sends a whole file and
    /// nothing else. So this goes through the shell instead, where `dd` can seek
    /// — and `shell,v2` frames stdout separately from stderr, which is what
    /// makes carrying binary over it safe.
    ///
    /// Measured on a POCO F7: a fixed ~75 ms per call, then about 15 MB/s. That
    /// is half of `RECV`'s throughput, so this is not the way to move a whole
    /// file. It is the way to answer "what is in the last 64 KB of this 7 GB
    /// archive", which costs 76 ms here and 218 seconds the other way. The
    /// offset itself is free: 64 KiB at 500 MB in measures the same as 64 KiB
    /// at zero, because `iflag=skip_bytes` makes `dd` seek rather than read
    /// through.
    public func readRange(_ remotePath: String,
                          offset: Int64,
                          length: Int,
                          on selector: DeviceSelector) async throws -> Data {
        guard length > 0 else { return Data() }
        guard offset >= 0 else {
            throw AdbError.invalidPath("negative offset \(offset) for \(remotePath)")
        }

        // `bs` is only the buffer size; `skip_bytes`/`count_bytes` reinterpret
        // skip and count as byte counts, which is the whole trick — without them
        // both are in blocks and no useful block size divides an arbitrary range.
        let command = """
            dd if=\(adbShellQuote(remotePath)) bs=262144 skip=\(offset) count=\(length) \
            iflag=skip_bytes,count_bytes 2>/dev/null
            """

        return try await run {
            let connection = try self.connect()
            defer { connection.close() }
            try connection.selectTransport(selector)
            try connection.send("shell,v2,raw:\(command)")

            var data = Data()
            data.reserveCapacity(length)
            var exitCode: Int32 = 0

            loop: while true {
                let header: [UInt8]
                do {
                    header = try connection.readRaw(5)
                } catch AdbError.unexpectedEOF {
                    break loop
                }
                let packetID = header[0]
                let size = Int(ByteCodec.readU32(header, at: 1))
                let payload = size > 0 ? try connection.readRaw(size) : []

                switch packetID {
                case 1: data.append(contentsOf: payload)
                case 3:
                    exitCode = payload.first.map(Int32.init) ?? 0
                    break loop
                default: continue
                }
            }

            guard exitCode == 0 else {
                throw AdbError.commandFailed(command: "dd", exitCode: exitCode, stderr: "")
            }
            // Short reads are normal at end of file; over-long ones are not, and
            // would mean the framing is wrong rather than the file is short.
            guard data.count <= length else {
                throw AdbError.protocolViolation(
                    "ranged read returned \(data.count) bytes for a \(length)-byte request")
            }
            return data
        }
    }
}
