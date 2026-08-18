import AdbFinderCore
import FileProvider
import UniformTypeIdentifiers

/// Presents one `StoredItem` to Finder.
final class ProviderItem: NSObject, NSFileProviderItem {
    private let stored: StoredItem
    private let version: ItemVersion
    private let rootFilename: String

    init(_ stored: StoredItem, version: ItemVersion, rootFilename: String) {
        self.stored = stored
        self.version = version
        self.rootFilename = rootFilename
    }

    var itemIdentifier: NSFileProviderItemIdentifier { .init(itemID: stored.id) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .init(itemID: stored.parentID) }

    /// The *display* name, which differs from the on-device name only when a
    /// case-insensitive collision forced disambiguation. The root row has no
    /// name of its own, so it borrows the domain's.
    var filename: String { stored.isRoot ? rootFilename : stored.displayName }

    var contentType: UTType {
        if stored.isDirectory { return .folder }
        if stored.isSymlink { return .symbolicLink }
        let ext = (stored.name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .data }
        return type
    }

    /// Set even though the file is not downloaded, so Finder can show a size
    /// without materialising gigabytes to find it out.
    var documentSize: NSNumber? { stored.isDirectory ? nil : NSNumber(value: stored.size) }

    var contentModificationDate: Date? { stored.modified }
    var creationDate: Date? { stored.modified }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: version.content, metadataVersion: version.metadata)
    }

    /// Derived from the device's own mode bits rather than assumed.
    ///
    /// `adb` runs as uid 2000 (`shell`), which reaches user storage through
    /// supplementary groups such as `media_rw` and `ext_data_rw` — so the group
    /// write bit is the meaningful signal, not the owner bit. Anything genuinely
    /// unwritable still fails at the device, but advertising the truth up front
    /// stops Finder offering operations that would die halfway.
    private var isWritable: Bool { stored.mode & 0o220 != 0 }

    var capabilities: NSFileProviderItemCapabilities {
        guard isWritable else {
            return stored.isDirectory ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
        }
        if stored.isDirectory {
            var capabilities: NSFileProviderItemCapabilities =
                [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
            // The root is the volume itself: renaming or deleting it is not a
            // thing Finder should offer.
            if !stored.isRoot {
                capabilities.formUnion([.allowsRenaming, .allowsDeleting, .allowsReparenting])
            }
            return capabilities
        }
        return [.allowsReading, .allowsWriting, .allowsRenaming, .allowsDeleting, .allowsReparenting]
    }
}
