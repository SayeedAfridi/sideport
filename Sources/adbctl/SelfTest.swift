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

    struct Verdict {
        let ok: Bool
        let detail: String
    }

    /// Runs `body`, expecting it to fail, and reports which errno the failure
    /// resolves to. Carries the raw device text on mismatch — that text is the
    /// evidence, and a mismatch means our table needs a new entry rather than
    /// that the device is wrong.
    ///
    /// Non-mutating on purpose: recording the result has to be a separate
    /// statement, because a closure that reaches back into `self` cannot run
    /// while `check` is holding it exclusively.
    func classify(_ code: Int32, _ body: () async throws -> Void) async -> Verdict {
        do {
            try await body()
            return Verdict(ok: false, detail: "expected a failure, got success")
        } catch let error as AdbError {
            let resolved = error.posixCode
            return Verdict(ok: resolved == code,
                           detail: "resolved to \(resolved.map(String.init) ?? "nil") from \(error.localizedDescription.debugDescription)")
        } catch {
            return Verdict(ok: false, detail: "threw \(error)")
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

        // Ranged reads go through `dd` over the shell, because the sync
        // protocol has no way to ask for part of a file. That makes binary
        // safety the thing to prove: a byte the framing mangles would show up
        // here and nowhere else.
        print("\nranged reads")

        let wholeAgain = try await client.readRange(remote, offset: 0,
                                                    length: payload.count, on: selector)
        check("a full-length range matches the file", wholeAgain == payload,
              "got \(wholeAgain.count) of \(payload.count) bytes")

        let middle = try await client.readRange(remote, offset: 100_000, length: 4096, on: selector)
        check("an interior range is byte-exact",
              middle == payload.subdata(in: 100_000..<104_096))

        let tail = try await client.readRange(remote, offset: Int64(payload.count - 100),
                                              length: 100, on: selector)
        check("a range at the very end is byte-exact",
              tail == payload.suffix(100))

        // Every byte value appears in the payload, so this covers the ones a
        // line-oriented or text-decoding path would corrupt: 0x00, 0x0A, 0x0D.
        let newlineHeavy = try await client.readRange(remote, offset: 0, length: 1024, on: selector)
        check("bytes a text path would mangle survive", newlineHeavy == payload.prefix(1024),
              "0x0A/0x0D/0x00 round trip")

        let past = try await client.readRange(remote, offset: Int64(payload.count) + 5000,
                                              length: 1024, on: selector)
        check("reading past the end yields nothing rather than failing", past.isEmpty)

        let clipped = try await client.readRange(remote, offset: Int64(payload.count - 50),
                                                 length: 4096, on: selector)
        check("a range overlapping the end is clipped, not padded", clipped.count == 50)

        let zeroLength = try await client.readRange(remote, offset: 0, length: 0, on: selector)
        check("a zero-length range costs no round trip", zeroLength.isEmpty)

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

        // Move detection in AdbFinderCore keys off (dev, ino) staying constant
        // across a rename. If that were false the reconciler would report a
        // delete plus a create and Finder would lose the item's identity.
        print("\ninode stability")
        let beforeMove = try await client.stat(moved, on: selector, followSymlinks: false)
        check("device reports an inode", beforeMove.ino != nil && beforeMove.ino != 0,
              "ino=\(beforeMove.ino.map(String.init) ?? "nil")")
        let renamed = "\(root)/renamed-again.txt"
        try await client.move(from: moved, to: renamed, on: selector)
        let afterMove = try await client.stat(renamed, on: selector, followSymlinks: false)
        check("inode survives a rename",
              beforeMove.ino == afterMove.ino && beforeMove.dev == afterMove.dev,
              "\(beforeMove.dev.map(String.init) ?? "nil"):\(beforeMove.ino.map(String.init) ?? "nil") -> \(afterMove.dev.map(String.init) ?? "nil"):\(afterMove.ino.map(String.init) ?? "nil")")

        let intoSubdir = "\(root)/nested/moved-across.txt"
        try await client.move(from: renamed, to: intoSubdir, on: selector)
        let afterCross = try await client.stat(intoSubdir, on: selector, followSymlinks: false)
        check("inode survives a move between directories", beforeMove.ino == afterCross.ino)

        print("\nmissing paths")
        let ghost = try await client.stat("\(root)/does-not-exist", on: selector)
        check("stat of a missing path reports absence instead of throwing", !ghost.exists)

        print("\nshell")
        let echo = try await client.shell("echo out; echo err 1>&2; exit 7", on: selector)
        check("stdout captured", echo.stdout.contains("out"))
        check("stderr captured separately", echo.stderr.contains("err"), "stderr=\(echo.stderr.debugDescription)")
        check("exit code propagated", echo.exitCode == 7, "got \(echo.exitCode)")

        // The failure-classification table in `DeviceErrno` is only worth
        // anything if it was built against what this device actually says.
        // These provoke real failures and check the recovered errno, so a
        // vendor with different wording fails the selftest instead of silently
        // degrading every error into "cannot synchronize".
        // The sync protocol cannot tell "empty" from "I could not open it":
        // `LIST` answers DONE either way. Reading the second as the first would
        // have the reconciler tombstone every file on the phone.
        print("\nempty versus unreadable")

        let emptyDir = "\(root)/genuinely-empty"
        try await client.makeDirectory(emptyDir, on: selector)
        let empty = try await client.list(emptyDir, on: selector)
        check("a genuinely empty directory lists as empty", empty.isEmpty)

        let unlistable = await classify(EACCES) {
            // /data/data exists and is full of subdirectories, none of which the
            // shell user may see.
            _ = try await client.list("/data/data", on: selector)
        }
        check("an unreadable directory fails instead of reporting empty",
              unlistable.ok, unlistable.detail)

        print("\nerror classification")

        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("adbkit-errno-probe")
        try Data("x".utf8).write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }

        let readOnly = await classify(EROFS) {
            // /system is mounted read-only on any device that is not rooted and
            // remounted, which is the state a user's phone is in.
            try await client.push(probe, to: "/system/adbkit-errno-probe", on: selector)
        }
        check("push to a read-only filesystem reads as EROFS", readOnly.ok, readOnly.detail)

        let denied = await classify(EACCES) {
            try await client.push(probe, to: "/data/data/adbkit-errno-probe", on: selector)
        }
        check("push into a protected directory reads as EACCES", denied.ok, denied.detail)

        let sink = FileManager.default.temporaryDirectory
            .appendingPathComponent("adbkit-errno-sink")
        defer { try? FileManager.default.removeItem(at: sink) }
        let absent = await classify(ENOENT) {
            // Pulled somewhere other than `probe`: a failed pull still
            // truncates its destination, and the pushes above still need it.
            _ = try await client.pull("\(root)/definitely-absent", to: sink, on: selector)
        }
        check("pull of a missing file reads as ENOENT", absent.ok, absent.detail)

        let noParent = await classify(ENOENT) {
            let command = "mkdir \(adbShellQuote("\(root)/absent-parent/child"))"
            try await client.shell(command, on: selector).requireSuccess(command)
        }
        check("mkdir without its parent reads as ENOENT", noParent.ok, noParent.detail)

        let notEmpty = await classify(ENOTEMPTY) {
            let command = "rmdir \(adbShellQuote("\(root)/nested"))"
            try await client.shell(command, on: selector).requireSuccess(command)
        }
        check("rmdir on a populated directory reads as ENOTEMPTY", notEmpty.ok, notEmpty.detail)

        let unreadable = await classify(EACCES) {
            let command = "cat /data/data"
            try await client.shell(command, on: selector).requireSuccess(command)
        }
        check("reading a protected path reads as EACCES", unreadable.ok, unreadable.detail)

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
