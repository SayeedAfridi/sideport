import Foundation
import os

/// Identifiers shared by the container app and the extension.
///
/// These are in the package rather than duplicated per target so a typo cannot
/// silently split the two processes into separate App Group containers.
public enum Sideport {
    public static let teamID = "NU2JM39S5P"
    public static let appBundleID = "dev.afridi.sideport"
    public static let extensionBundleID = "dev.afridi.sideport.FileProvider"

    /// **Team-ID prefixed on purpose.** iOS uses `group.<id>`; macOS requires the
    /// team identifier first, and since Sequoia the sandbox enforces it —
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil for an
    /// unprefixed group, with no diagnostic to explain why.
    public static let appGroup = "NU2JM39S5P.dev.afridi.sideport"

    public static let subsystem = "dev.afridi.sideport"

    /// Where a device's user storage lives once `/sdcard`'s two symlink hops are
    /// resolved. Used as a fallback; the real root is resolved per device.
    public static let defaultDeviceRoot = "/storage/emulated/0"

    /// The storage roots to try, in order, given what `readlink -f /sdcard` said.
    ///
    /// A *candidate*, never an answer. `readlink -f` will happily name a path
    /// that does not exist — a device answering while its user storage is still
    /// mounting resolves `/sdcard` to `/storage/self/primary` and stops there —
    /// so the caller has to prove each one listable before believing it. Taking
    /// the first plausible-looking string instead is what pinned a whole
    /// extension lifetime to a directory that could not be read.
    ///
    /// The default is always last, so a device that resolves to something
    /// unusable still gets the documented path tried before anyone gives up.
    public static func rootCandidates(resolved: String?, succeeded: Bool) -> [String] {
        var candidates: [String] = []
        if succeeded, let resolved {
            let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
            // Absolute paths only: a relative one would be resolved against
            // whatever directory the next shell happens to start in.
            if trimmed.hasPrefix("/") { candidates.append(trimmed) }
        }
        if !candidates.contains(defaultDeviceRoot) { candidates.append(defaultDeviceRoot) }
        return candidates
    }

    /// Per-device metadata database inside the shared container.
    ///
    /// One database per device, not one shared: unrelated devices should not
    /// queue behind each other's write lock.
    public static func storeURL(forSerial serial: String) throws -> URL {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw CoreError.appGroupUnavailable(appGroup)
        }
        let directory = container
            .appendingPathComponent("domains", isDirectory: true)
            .appendingPathComponent(sanitise(serial), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("metadata.sqlite")
    }

    /// Network device serials look like `192.168.1.5:5555`, which is not a
    /// filename anyone should build a path from unexamined.
    static func sanitise(_ serial: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(serial.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}

/// Structured logging, split by concern so `log stream` can be filtered to the
/// thing actually being debugged.
public enum Log {
    public static let enumeration = Logger(subsystem: Sideport.subsystem, category: "enumeration")
    public static let fetch = Logger(subsystem: Sideport.subsystem, category: "fetch")
    public static let write = Logger(subsystem: Sideport.subsystem, category: "write")
    public static let watch = Logger(subsystem: Sideport.subsystem, category: "watch")
    public static let adb = Logger(subsystem: Sideport.subsystem, category: "adb")
    public static let domain = Logger(subsystem: Sideport.subsystem, category: "domain")
}
