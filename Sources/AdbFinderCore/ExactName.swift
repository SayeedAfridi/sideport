import Foundation

/// A filename compared by its exact bytes rather than by Unicode equivalence.
///
/// Swift's `String` equality is canonical: `café` written NFC (`é`) and NFD
/// (`e` + combining acute) are `==`, hash alike, and compare as neither less
/// nor greater. Android's filesystem has no such opinion — both names can sit
/// in one directory as two unrelated files, and macOS itself produces NFD
/// names, so a phone that has ever seen a file from a Mac can hold the pair.
///
/// Keying a directory's contents by `String` therefore collapses two real files
/// into one. That is not a display glitch: `Dictionary(uniqueKeysWithValues:)`
/// traps on the duplicate, which crashes the File Provider extension outright.
///
/// Wrapping the name makes the byte-exactness part of the type, so the next
/// dictionary built over filenames cannot quietly reintroduce the bug.
struct ExactName: Hashable, Sendable {
    let value: String
    private let bytes: [UInt8]

    init(_ value: String) {
        self.value = value
        self.bytes = Array(value.utf8)
    }

    static func == (lhs: ExactName, rhs: ExactName) -> Bool { lhs.bytes == rhs.bytes }

    func hash(into hasher: inout Hasher) { hasher.combine(bytes) }

    /// Byte order, not collation order.
    ///
    /// `sorted()` on canonically-equivalent strings is not merely arbitrary but
    /// *unstable*, so display-name disambiguation built on it could hand the
    /// same file a different suffix on the next refresh.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        Array(lhs.utf8).lexicographicallyPrecedes(Array(rhs.utf8))
    }
}
