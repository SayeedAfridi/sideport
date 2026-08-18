import AdbKit
import Foundation

/// Exercises what happens when the ground moves underneath a transfer.
///
/// The failures this looks for are the ones that only appear when something
/// goes wrong at the wrong moment: a half-written file presented to Finder as
/// complete, a socket leaked per failure until the process runs out, or an
/// error classified as permanent so the system gives up on an item that is
/// perfectly fine and will be reachable again in a second.
///
/// `adb kill-server` stands in for the whole family of transport deaths —
/// unplugging the cable, the phone sleeping, the server being restarted by
/// another tool. All of them arrive the same way at our end: a socket that
/// stops answering mid-conversation.
struct Resilience {
    let client: AdbClient
    let selector: DeviceSelector
    let adb: String

    private var passed = 0
    private var failed = 0

    init(client: AdbClient, selector: DeviceSelector) throws {
        self.client = client
        self.selector = selector
        self.adb = try Self.locateAdb()
    }

    /// The same search order the container app uses; `which` last, because a
    /// shim on PATH is less trustworthy than a real SDK install.
    static func locateAdb() throws -> String {
        let home = NSHomeDirectory()
        var candidates = [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Android/Sdk/platform-tools/adb"
        ]
        if let root = ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"] {
            candidates.insert("\(root)/platform-tools/adb", at: 0)
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw AdbError.serverUnreachable("cannot find the adb binary to drive the harness")
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

    @discardableResult
    func adbCommand(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Counts our own open file descriptors.
    ///
    /// A leak here is invisible in every functional test — everything keeps
    /// working until the process hits its limit hours later, at which point the
    /// failure looks like something else entirely.
    static func openDescriptors() -> Int {
        var count = 0
        for descriptor in 0..<getdtablesize() where fcntl(descriptor, F_GETFD) != -1 {
            count += 1
        }
        return count
    }

    /// Waits for the device to be listed and usable again.
    func waitForDevice(timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let devices = try? await client.devices(),
               devices.contains(where: { $0.state.isUsable }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    mutating func run(in parent: String) async throws {
        let root = "\(parent)/adbkit-resilience"
        print("device:  \(selector)")
        print("adb:     \(adb)")
        print("scratch: \(root)\n")

        try? await client.remove(root, on: selector)
        try await client.makeDirectory(root, on: selector)

        // Big enough that a pull is still running a second later, which is what
        // makes "kill it mid-transfer" a real test rather than a race we lose.
        let payloadSize = 96 * 1024 * 1024
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("adbkit-resilience-payload.bin")
        var payload = Data(count: payloadSize)
        payload.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            arc4random_buf(base, payloadSize)
        }
        try payload.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let remote = "\(root)/payload.bin"
        try await client.push(local, to: remote, on: selector)
        print("staged \(humanSize(Int64(payloadSize))) on the device\n")

        let descriptorsAtStart = Self.openDescriptors()

        // MARK: server death

        print("server death")
        adbCommand(["kill-server"])

        var deathError: AdbError?
        do {
            _ = try await client.list(root, on: selector)
        } catch let error as AdbError {
            deathError = error
        }
        check("an operation against a dead server fails rather than hanging", deathError != nil)
        check("...and reports it as a server problem", deathError?.isServerNotRunning == true,
              "got \(deathError.map { "\($0)" } ?? "no error")")
        // The mapping layer turns this into `.serverUnreachable`, which is what
        // makes Finder hold the change and retry instead of dropping the item.
        check("...and as transient, so the item is not written off",
              deathError?.isTransient == true)
        check("...and carries no errno, because no file was involved",
              deathError?.posixCode == nil)

        adbCommand(["start-server"])
        let recovered = await waitForDevice()
        check("the device is usable again once the server is back", recovered)

        // MARK: death mid-transfer

        print("\ndeath mid-transfer")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("adbkit-resilience-pulled.bin")
        try? FileManager.default.removeItem(at: destination)

        let killAfter = Int64(8 * 1024 * 1024)
        let killer = adb
        var transferError: Error?
        do {
            _ = try await client.pull(remote, to: destination, on: selector) { transferred in
                // Killed from inside the transfer so the socket dies with bytes
                // still in flight — the case that would leave a truncated file.
                if transferred > killAfter {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: killer)
                    process.arguments = ["kill-server"]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try? process.run()
                    process.waitUntilExit()
                }
            }
        } catch {
            transferError = error
        }

        check("a transfer interrupted mid-flight fails", transferError != nil)
        if let adbError = transferError as? AdbError {
            check("...transiently, because the file is still on the phone", adbError.isTransient,
                  "got \(adbError)")
        } else {
            check("...transiently, because the file is still on the phone", false,
                  "got \(transferError.map { "\($0)" } ?? "no error")")
        }
        // The one that matters: a partial file handed to Finder is indistinguishable
        // from a complete one, and the user finds out when they open it.
        check("no partial file is left behind",
              !FileManager.default.fileExists(atPath: destination.path))

        adbCommand(["start-server"])
        _ = await waitForDevice()

        // MARK: a storm

        print("\nstorm")
        var transientFailures = 0
        var permanentFailures = 0
        var successes = 0
        for round in 0..<8 {
            if round % 2 == 0 { adbCommand(["kill-server"]) }
            do {
                _ = try await client.list(root, on: selector)
                successes += 1
            } catch let error as AdbError {
                if error.isTransient { transientFailures += 1 } else { permanentFailures += 1 }
            } catch {
                permanentFailures += 1
            }
            if round % 2 == 0 { adbCommand(["start-server"]) }
        }
        check("no failure during a storm is classified as permanent",
              permanentFailures == 0, "\(permanentFailures) permanent")
        check("the storm actually broke something, so the check meant anything",
              transientFailures > 0, "\(transientFailures) transient, \(successes) succeeded")

        _ = await waitForDevice()
        let afterStorm = try? await client.list(root, on: selector)
        check("everything works again after the storm", afterStorm != nil)

        // MARK: transport reset

        print("\ntransport reset")
        // `reconnect` tears down the transport and rebuilds it — the same thing
        // the kernel does on a replug, minus the hands.
        adbCommand(["reconnect"])
        let afterReset = await waitForDevice()
        check("the device returns after a transport reset", afterReset)
        let listAfterReset = try? await client.list(root, on: selector)
        check("operations work after a transport reset", listAfterReset != nil)

        // MARK: descriptors

        print("\ndescriptors")
        let descriptorsAtEnd = Self.openDescriptors()
        let leaked = descriptorsAtEnd - descriptorsAtStart
        check("no descriptors leaked across the failures", leaked <= 2,
              "\(descriptorsAtStart) -> \(descriptorsAtEnd)")

        print("\ncleanup")
        try? FileManager.default.removeItem(at: destination)
        try await client.remove(root, on: selector)
        check("scratch directory removed", try await !client.stat(root, on: selector).exists)

        print("\n\(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
