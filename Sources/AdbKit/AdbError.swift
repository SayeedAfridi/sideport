import Foundation

/// Every failure surfaced by AdbKit.
///
/// These map deliberately onto the two protocol layers involved: the adb *host*
/// protocol spoken to the local adb server, and the *sync* protocol spoken to
/// the device once a transport has been selected.
public enum AdbError: Error, Sendable, Hashable {
    /// The local adb server could not be reached at all (usually: not running).
    case serverUnreachable(String)
    /// Socket-level failure after a connection was established.
    case socket(String)
    /// The peer closed the stream while we still expected bytes.
    case unexpectedEOF
    /// The server sent something the protocol does not allow.
    case protocolViolation(String)
    /// The adb server answered `FAIL` to a host request.
    case requestFailed(String)
    /// The device's sync service answered `FAIL`.
    case syncFailed(String)
    /// No device matched, or no device is connected at all.
    case deviceNotFound(String)
    /// A device is present but not usable (offline, unauthorized, recovery...).
    case deviceUnavailable(serial: String, state: String)
    /// A shell command exited non-zero.
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    /// A path was empty, relative, or otherwise unusable on the device.
    case invalidPath(String)
    /// The local filesystem side of a push/pull failed.
    case localIO(String)
}

extension AdbError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .serverUnreachable(let detail):
            return "Cannot reach the adb server: \(detail)"
        case .socket(let detail):
            return "Socket error: \(detail)"
        case .unexpectedEOF:
            return "The connection closed unexpectedly."
        case .protocolViolation(let detail):
            return "adb protocol violation: \(detail)"
        case .requestFailed(let message):
            return "adb server rejected the request: \(message)"
        case .syncFailed(let message):
            return "Device file transfer failed: \(message)"
        case .deviceNotFound(let hint):
            return "No matching Android device: \(hint)"
        case .deviceUnavailable(let serial, let state):
            return "Device \(serial) is not ready (state: \(state))."
        case .commandFailed(let command, let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`\(command)` exited \(code)\(detail.isEmpty ? "" : ": \(detail)")"
        case .invalidPath(let path):
            return "Invalid device path: \(path)"
        case .localIO(let detail):
            return "Local file error: \(detail)"
        }
    }

    /// True when retrying after the caller starts the adb server could succeed.
    public var isServerNotRunning: Bool {
        if case .serverUnreachable = self { return true }
        return false
    }
}
