import AppKit
import AdbFinderCore
import AdbKit
import Foundation

/// Finds the user's `adb` binary and starts the server when it is not running.
///
/// This is the reason the container app is deliberately *not* sandboxed: the
/// binary lives wherever the user installed platform-tools, which is outside any
/// container. The extension can never do this — it is sandboxed by force, which
/// is exactly why AdbKit speaks the wire protocol instead of spawning anything.
@MainActor
final class AdbServerController {
    /// Where platform-tools normally ends up, in rough order of likelihood.
    private static var searchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            "\(home)/Android/Sdk/platform-tools/adb",
        ]
        // An explicit SDK location wins over any guess.
        for variable in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = ProcessInfo.processInfo.environment[variable] {
                candidates.insert("\(root)/platform-tools/adb", at: 0)
            }
        }
        return candidates
    }

    /// The binary's path, or nil when platform-tools is not installed.
    private(set) lazy var binaryPath: String? = Self.locate()

    private static func locate() -> String? {
        let manager = FileManager.default
        for candidate in searchPaths where manager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Last resort: ask the login shell, which knows about PATH additions we
        // cannot guess. A GUI app inherits almost nothing, so this is not
        // redundant with the list above.
        return askLoginShell()
    }

    private static func askLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v adb"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return path
        } catch {
            return nil
        }
    }

    /// Starts the shared adb server. We never run a private one on a private
    /// port: Android Studio and the command line must keep working normally
    /// while we are connected.
    @discardableResult
    func startServer() async -> Bool {
        guard let binaryPath else {
            Log.adb.error("no adb binary found; cannot start the server")
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["start-server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    process.waitUntilExit()
                    continuation.resume()
                }
            }
            Log.adb.info("adb start-server exited \(process.terminationStatus, privacy: .public)")
            return process.terminationStatus == 0
        } catch {
            Log.adb.error("could not run adb: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Reveals platform-tools in Finder, for the "where is it?" case.
    func revealBinary() {
        guard let binaryPath else { return }
        NSWorkspace.shared.selectFile(binaryPath,
                                      inFileViewerRootedAtPath: (binaryPath as NSString).deletingLastPathComponent)
    }
}
