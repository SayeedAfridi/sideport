import Foundation

/// Result of a command run on the device.
public struct ShellResult: Sendable, Hashable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public var succeeded: Bool { exitCode == 0 }

    /// Throws `.commandFailed` unless the command exited zero.
    @discardableResult
    public func requireSuccess(_ command: String) throws -> ShellResult {
        guard succeeded else {
            throw AdbError.commandFailed(command: command, exitCode: exitCode, stderr: stderr)
        }
        return self
    }
}

/// Quotes a string for Android's shell.
///
/// Single quotes disable every expansion, so the only character needing care is
/// the single quote itself. This is the difference between deleting one file and
/// deleting a directory tree when a filename contains `;` or a space.
public func adbShellQuote(_ argument: String) -> String {
    "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

enum AdbShellRunner {
    /// Runs a command over the v2 shell protocol, which separates stdout from
    /// stderr and reports a real exit code.
    static func runV2(connection: AdbConnection, command: String) throws -> ShellResult {
        try connection.send("shell,v2,raw:\(command)")

        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32 = -1

        loop: while true {
            let header: [UInt8]
            do {
                header = try connection.readRaw(5)
            } catch AdbError.unexpectedEOF {
                break loop
            }
            let packetID = header[0]
            let length = Int(ByteCodec.readU32(header, at: 1))
            let payload = length > 0 ? try connection.readRaw(length) : []

            switch packetID {
            case 1: stdout.append(contentsOf: payload)
            case 2: stderr.append(contentsOf: payload)
            case 3:
                exitCode = payload.first.map(Int32.init) ?? 0
                break loop
            default: continue  // stdin/close/window-size echoes are not our concern
            }
        }

        return ShellResult(stdout: String(decoding: stdout, as: UTF8.self),
                           stderr: String(decoding: stderr, as: UTF8.self),
                           exitCode: exitCode)
    }

    /// Fallback for pre-shell-v2 devices (Android 6 and older). `exec:` gives a
    /// raw byte stream with no exit status, so we append a sentinel to recover it.
    static func runLegacy(connection: AdbConnection, command: String) throws -> ShellResult {
        let sentinel = "__adbkit_exit__:"
        try connection.send("exec:(\(command)) ; echo \"\(sentinel)$?\"")
        let output = String(decoding: try connection.readRawToEnd(), as: UTF8.self)

        guard let range = output.range(of: sentinel, options: .backwards) else {
            return ShellResult(stdout: output, stderr: "", exitCode: 0)
        }
        let code = Int32(output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return ShellResult(stdout: String(output[..<range.lowerBound]), stderr: "", exitCode: code)
    }
}
