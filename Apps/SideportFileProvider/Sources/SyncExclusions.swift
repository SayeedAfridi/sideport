import AdbKit
import Foundation

/// Files macOS creates for its own bookkeeping, which have no business on a phone.
///
/// Finder writes `.DS_Store` into every directory it displays, and on volumes
/// without native extended-attribute support it also writes AppleDouble `._`
/// sidecars beside real files. Left alone these would litter the device — and
/// worse, they would show up in Android's own file managers and gallery apps.
///
/// The system gives us a first-class way to refuse: returning
/// `NSFileProviderErrorExcludedFromSync` keeps the file in the Mac's local
/// replica, so Finder stays happy, while it is never uploaded.
enum SyncExclusions {
    private static let exactNames: Set<String> = [
        ".DS_Store",
        ".localized",
        ".Trashes",
        ".fseventsd",
        ".Spotlight-V100",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
        ".apdisk",
        ".VolumeIcon.icns",
        ".com.apple.timemachine.donotpresent",
    ]

    private static let prefixes: [String] = [
        "._",                        // AppleDouble resource-fork sidecars
        AdbClient.stagingPrefix,     // our own in-flight uploads
    ]

    static func excludes(_ filename: String) -> Bool {
        if exactNames.contains(filename) { return true }
        return prefixes.contains { filename.hasPrefix($0) }
    }
}
