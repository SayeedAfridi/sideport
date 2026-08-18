import AdbKit
import Foundation

// A thin harness over AdbKit so every protocol operation can be exercised
// against a real device before any Finder plumbing depends on it.

let usage = """
adbctl — AdbKit protocol harness

Usage:
  adbctl [-s SERIAL] <command> [args]

Commands:
  devices                       List attached devices
  features                      Show negotiated protocol features
  ls <remote>                   List a device directory
  stat <remote>                 Stat a device path
  pull <remote> <local>         Copy a file off the device
  push <local> <remote>         Copy a file onto the device
  mkdir <remote>                Create a directory (with parents)
  rm <remote>                   Delete recursively
  mv <src> <dst>                Rename or move
  df <remote>                   Free space on the containing volume
  shell <command...>            Run a shell command
  watch                         Stream device hot-plug events
  selftest <remote-dir>         Round-trip every operation in a scratch dir
  bench [MB] [remote-dir]       Measure throughput and peak memory (default 256 MB)
"""

var arguments = Array(CommandLine.arguments.dropFirst())
var explicitSerial: String?

if let flagIndex = arguments.firstIndex(of: "-s"), flagIndex + 1 < arguments.count {
    explicitSerial = arguments[flagIndex + 1]
    arguments.removeSubrange(flagIndex...(flagIndex + 1))
}

guard let command = arguments.first else {
    print(usage)
    exit(2)
}
let operands = Array(arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func require(_ count: Int, _ hint: String) -> [String] {
    guard operands.count >= count else { fail("expected \(hint)") }
    return operands
}

func humanSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

let client = AdbClient()

@MainActor
func resolveSelector() async throws -> DeviceSelector {
    if let explicitSerial { return .serial(explicitSerial) }
    return .serial(try await client.soleDevice().serial)
}

do {
    switch command {
    case "devices":
        let devices = try await client.devices()
        if devices.isEmpty {
            print("No devices attached.")
        }
        for device in devices {
            print("\(device.serial)\t\(device.state.rawValue)\t\(device.displayName)")
        }

    case "features":
        let features = try await client.features(for: try await resolveSelector())
        print("ls_v2:    \(features.listV2)")
        print("stat_v2:  \(features.statV2)")
        print("shell_v2: \(features.shellV2)")
        print("all:      \(features.raw.sorted().joined(separator: ", "))")

    case "ls":
        let args = require(1, "ls <remote>")
        let entries = try await client.list(args[0], on: try await resolveSelector())
        for entry in entries.sorted(by: { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }) {
            let kind = entry.isDirectory ? "d" : (entry.isSymlink ? "l" : "-")
            let size = entry.isDirectory ? "" : humanSize(entry.size)
            print(String(format: "%@%04o  %10@  %@", kind, Int(entry.posixPermissions), size as NSString, entry.name))
        }

    case "stat":
        let args = require(1, "stat <remote>")
        let entry = try await client.stat(args[0], on: try await resolveSelector())
        guard entry.exists else { fail("no such path: \(args[0])") }
        print("mode:     \(String(format: "0%o", entry.mode))")
        print("size:     \(entry.size) (\(humanSize(entry.size)))")
        print("modified: \(entry.modified)")
        print("kind:     \(entry.isDirectory ? "directory" : entry.isSymlink ? "symlink" : "file")")

    case "pull":
        let args = require(2, "pull <remote> <local>")
        let start = Date()
        let bytes = try await client.pull(args[0], to: URL(fileURLWithPath: args[1]), on: try await resolveSelector())
        let elapsed = Date().timeIntervalSince(start)
        print("pulled \(humanSize(bytes)) in \(String(format: "%.2fs", elapsed)) (\(humanSize(Int64(Double(bytes) / max(elapsed, 0.001))))/s)")

    case "push":
        let args = require(2, "push <local> <remote>")
        let url = URL(fileURLWithPath: args[0])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let start = Date()
        try await client.push(url, to: args[1], on: try await resolveSelector())
        let elapsed = Date().timeIntervalSince(start)
        print("pushed \(humanSize(size)) in \(String(format: "%.2fs", elapsed))")

    case "mkdir":
        let args = require(1, "mkdir <remote>")
        try await client.makeDirectory(args[0], on: try await resolveSelector())
        print("created \(args[0])")

    case "rm":
        let args = require(1, "rm <remote>")
        try await client.remove(args[0], on: try await resolveSelector())
        print("removed \(args[0])")

    case "mv":
        let args = require(2, "mv <src> <dst>")
        try await client.move(from: args[0], to: args[1], on: try await resolveSelector())
        print("moved \(args[0]) -> \(args[1])")

    case "df":
        let args = require(1, "df <remote>")
        if let free = try await client.availableCapacity(at: args[0], on: try await resolveSelector()) {
            print("free: \(humanSize(free))")
        } else {
            print("free: unknown")
        }

    case "shell":
        let args = require(1, "shell <command...>")
        let result = try await client.shell(args.joined(separator: " "), on: try await resolveSelector())
        if !result.stdout.isEmpty { print(result.stdout, terminator: "") }
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
        exit(result.exitCode)

    case "watch":
        print("watching for device changes (ctrl-c to stop)…")
        for try await devices in client.deviceChanges() {
            let summary = devices.isEmpty
                ? "(none)"
                : devices.map { "\($0.displayName) [\($0.state.rawValue)]" }.joined(separator: ", ")
            print("\(Date().formatted(date: .omitted, time: .standard))  \(summary)")
        }

    case "bench":
        let megabytes = operands.first.flatMap(Int.init) ?? 256
        let directory = operands.count > 1 ? operands[1] : "/sdcard"
        try await Benchmark(client: client, selector: try await resolveSelector())
            .run(megabytes: megabytes, remoteDirectory: directory)

    case "selftest":
        let args = require(1, "selftest <remote-dir>")
        var test = SelfTest(client: client, selector: try await resolveSelector())
        try await test.run(in: args[0])

    default:
        print(usage)
        exit(2)
    }
} catch {
    fail((error as? AdbError)?.errorDescription ?? "\(error)")
}
