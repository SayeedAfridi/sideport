import AdbKit
import CryptoKit
import Foundation

/// End-to-end exercise of every protocol path, run against a real device.
///
/// Two things here are load-bearing beyond "does it work": the multi-operation
/// session test proves packet framing is exact (a wrong header size desyncs the
/// stream and the *second* call is what fails), and the awkward-filename test
/// proves shell quoting holds.
struct SelfTest {
    let client: AdbClient
    let selector: DeviceSelector

    private var passed = 0
    private var failed = 0

    init(client: AdbClient, selector: DeviceSelector) {
        self.client = client
        self.selector = selector
    }

    mutating func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            print("  ✓ \(label)")
        } else {
            failed += 1
            let extra = detail()
            print("  ✗ \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    mutating func run(in parent: String) async throws {
        let root = "\(parent)/adbkit-selftest"
        print("device:  \(selector)")
        print("scratch: \(root)\n")

        let features = try await client.features(for: selector)
        print("features: ls_v2=\(features.listV2) stat_v2=\(features.statV2) shell_v2=\(features.shellV2)\n")

        try? await client.remove(root, on: selector)

        print("directories")
        try await client.makeDirectory("\(root)/nested/deep", on: selector)
        let dirStat = try await client.stat("\(root)/nested/deep", on: selector)
        check("mkdir -p creates the full chain", dirStat.exists && dirStat.isDirectory)

        print("\npush / pull round trip")
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("adbkit-\(UUID().uuidString).bin")
        // Larger than one 64 KiB DATA packet so chunking is actually exercised.
        let payload = Data((0..<(700 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try payload.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let remote = "\(root)/payload.bin"
        try await client.push(local, to: remote, on: selector)
        let pushed = try await client.stat(remote, on: selector)
        check("pushed file has the right size", pushed.size == Int64(payload.count),
              "expected \(payload.count), got \(pushed.size)")

        let readback = local.appendingPathExtension("out")
        defer { try? FileManager.default.removeItem(at: readback) }
        try await client.pull(remote, to: readback, on: selector)
        let returned = try Data(contentsOf: readback)
        check("pulled bytes are identical",
              SHA256.hash(data: returned) == SHA256.hash(data: payload),
              "\(returned.count) bytes back vs \(payload.count) sent")

        print("\nlisting")
        let entries = try await client.list(root, on: selector)
        check("listing sees both children", entries.count == 2,
              "got \(entries.map(\.name).sorted())")
        check("directory flag is right", entries.first { $0.name == "nested" }?.isDirectory == true)
        check("file size is right", entries.first { $0.name == "payload.bin" }?.size == Int64(payload.count))
        check("`.` and `..` are filtered out", !entries.contains { $0.name == "." || $0.name == ".." })

        // If any packet header size is wrong the stream desyncs and the second
        // operation on the same session is where it shows up.
        print("\nsession reuse (framing check)")
        let reuse: [Int] = try await client.withSyncSession(selector) { session in
            let first = try session.list(root).count
            let second = try session.list(root).count
            let third = try session.stat(remote).exists ? 1 : 0
            let fourth = try session.list("\(root)/nested").count
            return [first, second, third, fourth]
        }
        check("four operations on one session stay in sync",
              reuse == [2, 2, 1, 1], "got \(reuse)")

        print("\nawkward names")
        let tricky = "\(root)/a file 'with' quotes & $pace.txt"
        try await client.withSyncSession(selector) { session in
            try session.push(data: Data("hello".utf8), to: tricky)
        }
        let trickyStat = try await client.stat(tricky, on: selector)
        check("quoting survives push", trickyStat.exists && trickyStat.size == 5)

        let moved = "\(root)/renamed ünïcode 名前.txt"
        try await client.move(from: tricky, to: moved, on: selector)
        check("move handles quotes and unicode", try await client.stat(moved, on: selector).exists)
        check("source is gone after move", try await !client.stat(tricky, on: selector).exists)

        print("\nmissing paths")
        let ghost = try await client.stat("\(root)/does-not-exist", on: selector)
        check("stat of a missing path reports absence instead of throwing", !ghost.exists)

        print("\nshell")
        let echo = try await client.shell("echo out; echo err 1>&2; exit 7", on: selector)
        check("stdout captured", echo.stdout.contains("out"))
        check("stderr captured separately", echo.stderr.contains("err"), "stderr=\(echo.stderr.debugDescription)")
        check("exit code propagated", echo.exitCode == 7, "got \(echo.exitCode)")

        print("\ncapacity")
        let free = try await client.availableCapacity(at: parent, on: selector)
        check("df reports free space", (free ?? 0) > 0, "got \(free.map(String.init) ?? "nil")")

        print("\ncleanup")
        try await client.remove(root, on: selector)
        check("scratch directory removed", try await !client.stat(root, on: selector).exists)

        print("\n\(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
