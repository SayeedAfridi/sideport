import Foundation

/// A stable item identifier. Deliberately *not* a device path and *not* an
/// inode — see `MetadataStore` for why.
public typealias ItemID = Int64

public enum CoreError: Error, Sendable {
    case database(String, Int32)
    case itemNotFound(ItemID)
    case notADirectory(ItemID)
    /// The caller's sync anchor predates our change log. They must re-enumerate
    /// from scratch. Correct, just slower — this is the safety valve that stops
    /// a bad incremental state from becoming permanent.
    case anchorExpired
    /// The App Group container is unreachable — almost always a missing or
    /// misspelled `com.apple.security.application-groups` entitlement.
    case appGroupUnavailable(String)
    /// User storage is not there to be read. A device that answers before its
    /// volumes are mounted resolves `/sdcard` to a path it cannot then list,
    /// and neither the resolved path nor the default one is usable.
    case storageUnavailable(String)
}

extension CoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .database(let message, let code): return "SQLite error \(code): \(message)"
        case .itemNotFound(let id): return "No item with identifier \(id)."
        case .notADirectory(let id): return "Item \(id) is not a directory."
        case .anchorExpired: return "Sync anchor is older than the retained change log."
        case .appGroupUnavailable(let group):
            return "App Group \(group) is unavailable. Check the application-groups entitlement."
        case .storageUnavailable(let path):
            return "Device storage at \(path) is not readable. It may still be mounting, or locked."
        }
    }
}

/// One row of the identity map.
public struct StoredItem: Sendable, Hashable, Identifiable {
    public let id: ItemID
    public let parentID: ItemID
    /// The real name on the device — what we send back over adb.
    public let name: String
    /// What Finder should show. Differs from `name` only when a case-insensitive
    /// collision forced disambiguation.
    public let displayName: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date
    public let mode: UInt32
    public let dev: UInt64?
    public let ino: UInt64?

    public var isRoot: Bool { id == MetadataStore.rootID }

    private static let formatMask: UInt32 = 0o170000

    /// True only for an unresolved link. Enumeration resolves symlinks to their
    /// targets, so this is normally false by the time Finder sees an item.
    public var isSymlink: Bool { mode & Self.formatMask == 0o120000 }
    public var isRegularFile: Bool { mode & Self.formatMask == 0o100000 }
    public var posixPermissions: UInt16 { UInt16(mode & 0o7777) }
    /// Dotfiles are hidden on Android exactly as they are on macOS.
    public var isHidden: Bool { name.hasPrefix(".") }

    public init(id: ItemID, parentID: ItemID, name: String, displayName: String? = nil,
                isDirectory: Bool, size: Int64, modified: Date, mode: UInt32,
                dev: UInt64? = nil, ino: UInt64? = nil) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.displayName = displayName ?? name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.mode = mode
        self.dev = dev
        self.ino = ino
    }
}

public enum ChangeKind: Int, Sendable, Hashable {
    case created = 0
    case modified = 1
    case deleted = 2
    case moved = 3
}

public struct ItemChange: Sendable, Hashable {
    public let anchor: Int64
    public let itemID: ItemID
    public let kind: ChangeKind
}

/// What a single directory reconciliation concluded.
public struct ReconcileResult: Sendable, Hashable {
    public var created: [StoredItem] = []
    public var modified: [StoredItem] = []
    public var moved: [StoredItem] = []
    public var deleted: [ItemID] = []
    /// The change-log anchor after this reconciliation. Unchanged from before
    /// when nothing happened.
    public var anchor: Int64 = 0

    public var isEmpty: Bool {
        created.isEmpty && modified.isEmpty && moved.isEmpty && deleted.isEmpty
    }
}

/// Content and metadata versions, shaped for `NSFileProviderItemVersion`.
public struct ItemVersion: Sendable, Hashable {
    public let content: Data
    public let metadata: Data
}
