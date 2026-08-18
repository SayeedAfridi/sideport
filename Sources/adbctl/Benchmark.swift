import AdbKit
import CryptoKit
import Foundation

/// Round-trips a file of a given size and reports throughput and peak memory.
///
/// Peak RSS is the number that matters here. Transfer speed is pinned by the
/// USB link, but memory is entirely ours to get wrong: an early version of the
/// push loop held the whole file resident, so 256 MB cost 269 MB of RSS. This
/// makes that class of regression visible instead of invisible.
struct Benchmark {
    let client: AdbClient
    let selector: DeviceSelector

    /// Peak resident set size in bytes. `ru_maxrss` is bytes on Darwin.
    private var peakMemory: Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int64(usage.ru_maxrss)
    }

    private func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    func run(megabytes: Int, remoteDirectory: String) async throws {
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("adbkit-bench-\(UUID().uuidString).bin")
        let readback = local.appendingPathExtension("out")
        let remote = "\(remoteDirectory)/adbkit-bench.bin"
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: readback)
        }

        print("generating \(megabytes) MB…")
        try generate(megabytes: megabytes, at: local)
        let size = Int64(megabytes) * 1_048_576

        let beforePush = peakMemory
        let pushStart = Date()
        try await client.pushAtomically(local, to: remote, on: selector)
        let pushSeconds = Date().timeIntervalSince(pushStart)

        let pullStart = Date()
        try await client.pull(remote, to: readback, on: selector)
        let pullSeconds = Date().timeIntervalSince(pullStart)
        let afterPull = peakMemory

        try await client.remove(remote, on: selector)

        let sent = try digest(of: local)
        let returned = try digest(of: readback)

        print("")
        print("  push      \(mb(size)) in \(String(format: "%.2fs", pushSeconds)) — \(mb(Int64(Double(size) / max(pushSeconds, 0.001))))/s")
        print("  pull      \(mb(size)) in \(String(format: "%.2fs", pullSeconds)) — \(mb(Int64(Double(size) / max(pullSeconds, 0.001))))/s")
        print("  integrity \(sent == returned ? "identical" : "MISMATCH")")
        print("  peak RSS  \(mb(afterPull)) (was \(mb(beforePush)) before transfer)")
        print("")
        // Memory must not track file size. Anything approaching it means a
        // buffer is being accumulated rather than streamed.
        if afterPull > size / 4 {
            print("  ⚠︎ peak memory is large relative to the payload — check for buffering")
        } else {
            print("  ✓ memory is independent of payload size")
        }
        if sent != returned { exit(1) }
    }

    /// Writes pseudo-random bytes without holding the whole file in memory.
    private func generate(megabytes: Int, at url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var block = Data(count: 1_048_576)
        for index in 0..<megabytes {
            block.withUnsafeMutableBytes { raw in
                let base = raw.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: base.count, by: 997) {
                    base[offset] = UInt8(truncatingIfNeeded: offset &+ index)
                }
            }
            try handle.write(contentsOf: block)
        }
    }

    private func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
