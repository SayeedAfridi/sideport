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
    /// The local filesystem side of a push/pull failed. Carries the real
    /// `errno` because the Mac side is the one place we actually get a code
    /// rather than a sentence, and throwing that away would mean re-deriving
    /// it from our own `strerror` output later.
    case localIO(String, errno: Int32)
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
        case .localIO(let detail, _):
            return "Local file error: \(detail)"
        }
    }

    /// True when retrying after the caller starts the adb server could succeed.
    public var isServerNotRunning: Bool {
        if case .serverUnreachable = self { return true }
        return false
    }

    /// The POSIX `errno` behind this failure, when one can be recovered.
    ///
    /// Local failures carry it outright. Device-side ones arrive only as text,
    /// so they go through `DeviceErrno` — see there for why that inversion is
    /// necessary rather than merely convenient.
    public var posixCode: Int32? {
        switch self {
        case .localIO(_, let code):
            return code
        case .syncFailed(let message), .requestFailed(let message):
            return DeviceErrno.inferred(from: message)
        case .commandFailed(_, _, let stderr):
            return DeviceErrno.inferred(from: stderr)
        case .serverUnreachable, .socket, .unexpectedEOF, .protocolViolation,
             .deviceNotFound, .deviceUnavailable, .invalidPath:
            return nil
        }
    }

    /// True when the same request could plausibly succeed on a later attempt
    /// without anyone intervening.
    ///
    /// Transport faults qualify: every one of them is answered by opening a
    /// fresh connection, which the next attempt does anyway. A protocol
    /// violation counts too — it means *this* stream is desynced, and the cure
    /// is a new one.
    public var isTransient: Bool {
        switch self {
        case .serverUnreachable, .socket, .unexpectedEOF, .protocolViolation,
             .deviceNotFound, .deviceUnavailable:
            return true
        case .invalidPath:
            return false
        case .localIO, .syncFailed, .requestFailed, .commandFailed:
            return posixCode.map(DeviceErrno.isTransient) ?? false
        }
    }
}

extension AdbError {
    /// Builds a `.localIO` from the failure that just happened.
    ///
    /// `code` is passed rather than read inside so that it is captured before
    /// the caller's message is built — string interpolation is a chance for
    /// something else to overwrite `errno`, and a wrong code here is worse than
    /// no code.
    public static func localIOFailure(_ code: Int32, _ context: String) -> AdbError {
        .localIO("\(context): \(String(cString: strerror(code)))", errno: code)
    }
}
