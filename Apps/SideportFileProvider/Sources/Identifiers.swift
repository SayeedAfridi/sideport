import AdbFinderCore
import FileProvider

extension NSFileProviderItemIdentifier {
    /// Our root row is identifier 1; Finder insists its root be the well-known
    /// `.rootContainer` constant, so the two are bridged here and nowhere else.
    init(itemID: ItemID) {
        self = itemID == MetadataStore.rootID
            ? .rootContainer
            : NSFileProviderItemIdentifier(String(itemID))
    }

    var itemID: ItemID? {
        if self == .rootContainer { return MetadataStore.rootID }
        return ItemID(rawValue)
    }
}
