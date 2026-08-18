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
}

extension CoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .database(let message, let code): return "SQLite error \(code): \(message)"
        case .itemNotFound(let id): return "No item with identifier \(id)."
        case .notADirectory(let id): return "Item \(id) is not a directory."
        case .anchorExpired: return "Sync anchor is older than the retained change log."
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
