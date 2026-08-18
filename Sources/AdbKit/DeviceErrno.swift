import Foundation

/// Recovers a POSIX `errno` from the text of a device-side failure.
///
/// adb gives us no error *codes* from the device — only strings. `adbd`'s sync
/// service answers `FAIL` with a body ending in `strerror(errno)`, sometimes
/// behind a prefix ("couldn't create file: Read-only file system"), and toybox
/// writes the same strings to stderr. Inverting `strerror` is therefore the only
/// way to tell "the file is gone" from "the volume is full" — and those two want
/// opposite responses from Finder, so guessing is not an option.
///
/// The strings below are Linux/bionic's, because that is what is on the other
/// end of the cable; Darwin's differ for a handful of codes and both spellings
/// are listed where they do. Every entry here was read off a real device rather
/// than copied from a header.
public enum DeviceErrno {
    /// Longest-first so that a specific message wins over a shorter one it
    /// happens to contain.
    private static let table: [(code: Int32, text: String)] = {
        var entries: [(Int32, String)] = [
            (EPERM, "Operation not permitted"),
            (ENOENT, "No such file or directory"),
            (ESRCH, "No such process"),
            (EINTR, "Interrupted system call"),
            (EIO, "Input/output error"),
            (EIO, "I/O error"),
            (ENXIO, "No such device or address"),
            (E2BIG, "Argument list too long"),
            (EBADF, "Bad file descriptor"),
            (EAGAIN, "Resource temporarily unavailable"),
            (ENOMEM, "Cannot allocate memory"),
            (ENOMEM, "Out of memory"),
            (EACCES, "Permission denied"),
            (EBUSY, "Device or resource busy"),
            (EBUSY, "Resource busy"),
            (EEXIST, "File exists"),
            (EXDEV, "Invalid cross-device link"),
            (EXDEV, "Cross-device link"),
            (ENODEV, "No such device"),
            (ENOTDIR, "Not a directory"),
            (EISDIR, "Is a directory"),
            (EINVAL, "Invalid argument"),
            (ENFILE, "Too many open files in system"),
            (EMFILE, "Too many open files"),
            (EFBIG, "File too large"),
            (ENOSPC, "No space left on device"),
            (ESPIPE, "Illegal seek"),
            (EROFS, "Read-only file system"),
            (EMLINK, "Too many links"),
            (EPIPE, "Broken pipe"),
            (ENAMETOOLONG, "File name too long"),
            (ENOTEMPTY, "Directory not empty"),
            (ELOOP, "Too many levels of symbolic links"),
            (ELOOP, "Symbolic link loop"),
            (EDQUOT, "Disk quota exceeded"),
            (ENOTSUP, "Operation not supported"),
            (ETIMEDOUT, "Connection timed out"),
            (ECONNRESET, "Connection reset by peer"),
            (ECONNREFUSED, "Connection refused"),
            (EHOSTUNREACH, "No route to host"),
            (ETXTBSY, "Text file busy"),
            (EOVERFLOW, "Value too large for defined data type"),
            (ESTALE, "Stale file handle")
        ]
        entries.sort { $0.1.count > $1.1.count }
        return entries.map { (code: $0.0, text: $0.1.lowercased()) }
    }()

    /// The errno a device-side message describes, or `nil` if it names none.
    ///
    /// Matching is by containment because the interesting part is always at the
    /// end, behind a prefix nobody documents: `adbd` and each toybox applet
    /// choose their own.
    public static func inferred(from message: String) -> Int32? {
        guard !message.isEmpty else { return nil }
        let haystack = message.lowercased()
        for entry in table where haystack.contains(entry.text) {
            return entry.code
        }
        return nil
    }

    /// True when the same request could plausibly succeed on a later attempt
    /// with nobody intervening. Drives whether Finder is told to retry or to
    /// stop and show the failure.
    public static func isTransient(_ code: Int32) -> Bool {
        switch code {
        case EAGAIN, EINTR, EBUSY, ETIMEDOUT, ECONNRESET, ECONNREFUSED,
             EHOSTUNREACH, EPIPE, EIO, ENFILE, EMFILE, ESTALE:
            return true
        default:
            return false
        }
    }
}
