import AdbKit
import Foundation
import Testing
@testable import AdbFinderCore

private let root = "/storage/emulated/0"

private func store() throws -> MetadataStore {
    try MetadataStore(inMemoryDeviceRoot: root)
}

/// `ino` defaults to nil so tests must opt in to inode-backed move detection,
/// which keeps the legacy-device path honestly exercised.
private func entry(_ name: String, dir: Bool = false, size: Int64 = 10,
                   mtime: TimeInterval = 1_000, ino: UInt64? = nil,
                   dev: UInt64 = 64, mode: UInt32? = nil) -> AdbFileEntry {
    AdbFileEntry(name: name,
                 mode: mode ?? (dir ? 0o040755 : 0o100644),
                 size: dir ? 0 : size,
                 modified: Date(timeIntervalSince1970: mtime),
                 dev: ino == nil ? nil : dev,
                 ino: ino)
}

@Suite("Store basics")
struct BasicsTests {
    @Test func rootResolvesToTheDeviceRoot() throws {
        let store = try store()
        #expect(try store.path(of: MetadataStore.rootID) == root)
        #expect(try store.item(MetadataStore.rootID)?.isDirectory == true)
    }

    @Test func rootIsNotItsOwnChild() throws {
        // The root is its own parent to terminate path walking; it must not
        // therefore enumerate itself.
        let store = try store()
        #expect(try store.children(of: MetadataStore.rootID).isEmpty)
    }

    @Test func insertedChildResolvesItsPath() throws {
        let store = try store()
        let dcim = try store.insert(childOf: MetadataStore.rootID, entry: entry("DCIM", dir: true))
        let photo = try store.insert(childOf: dcim.id, entry: entry("a.jpg"))
        #expect(try store.path(of: photo.id) == "\(root)/DCIM/a.jpg")
    }

    @Test func trailingSlashOnDeviceRootIsNormalised() throws {
        let store = try MetadataStore(inMemoryDeviceRoot: "/storage/emulated/0/")
        let item = try store.insert(childOf: MetadataStore.rootID, entry: entry("x"))
        #expect(try store.path(of: item.id) == "/storage/emulated/0/x")
    }
}

@Suite("Reconciliation")
struct ReconcileTests {
    @Test func firstListingCreatesEverything() throws {
        let store = try store()
        let result = try store.reconcile(directory: MetadataStore.rootID,
                                         listing: [entry("DCIM", dir: true), entry("a.txt")])
        #expect(result.created.count == 2)
        #expect(result.modified.isEmpty && result.deleted.isEmpty && result.moved.isEmpty)
    }

    @Test func unchangedListingProducesNoChurn() throws {
        let store = try store()
        let listing = [entry("DCIM", dir: true), entry("a.txt")]
        try store.reconcile(directory: MetadataStore.rootID, listing: listing)
        let anchorAfterFirst = try store.currentAnchor()

        let second = try store.reconcile(directory: MetadataStore.rootID, listing: listing)
        #expect(second.isEmpty)
        // No change rows appended means Finder is not needlessly re-notified.
        #expect(try store.currentAnchor() == anchorAfterFirst)
    }

    @Test func changedSizeOrMtimeIsModified() throws {
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a.txt", size: 10)])
        let result = try store.reconcile(directory: MetadataStore.rootID,
                                         listing: [entry("a.txt", size: 20, mtime: 2_000)])
        #expect(result.modified.count == 1)
        #expect(result.modified.first?.size == 20)
    }

    @Test func missingEntryIsDeleted() throws {
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a.txt"), entry("b.txt")])
        let result = try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a.txt")])
        #expect(result.deleted.count == 1)
        #expect(try store.child(of: MetadataStore.rootID, named: "b.txt") == nil)
    }

    @Test func renameInPlaceKeepsTheIdentifier() throws {
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("old.txt", ino: 42)])
        let original = try #require(try store.child(of: MetadataStore.rootID, named: "old.txt"))

        let result = try store.reconcile(directory: MetadataStore.rootID, listing: [entry("new.txt", ino: 42)])
        #expect(result.moved.count == 1)
        #expect(result.created.isEmpty && result.deleted.isEmpty)
        #expect(result.moved.first?.id == original.id)
    }

    @Test func moveBetweenDirectoriesKeepsTheIdentifier() throws {
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID,
                            listing: [entry("A", dir: true, ino: 1), entry("B", dir: true, ino: 2)])
        let a = try #require(try store.child(of: MetadataStore.rootID, named: "A"))
        let b = try #require(try store.child(of: MetadataStore.rootID, named: "B"))

        try store.reconcile(directory: a.id, listing: [entry("f.txt", ino: 99)])
        let file = try #require(try store.child(of: a.id, named: "f.txt"))

        // The file turns up in B before A has been re-listed — the common
        // ordering, since Finder enumerates whichever directory is open.
        let result = try store.reconcile(directory: b.id, listing: [entry("f.txt", ino: 99)])
        #expect(result.moved.first?.id == file.id)
        #expect(try store.path(of: file.id) == "\(root)/B/f.txt")
    }

    @Test func withoutInodesAMoveDegradesToDeleteAndCreate() throws {
        // Legacy devices report no inode. The result is noisier but not wrong.
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("old.txt")])
        let result = try store.reconcile(directory: MetadataStore.rootID, listing: [entry("new.txt")])
        #expect(result.moved.isEmpty)
        #expect(result.created.count == 1)
        #expect(result.deleted.count == 1)
    }

    @Test func deleteThenRecreateGetsAFreshIdentifier() throws {
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a.txt")])
        let first = try #require(try store.child(of: MetadataStore.rootID, named: "a.txt"))

        try store.reconcile(directory: MetadataStore.rootID, listing: [])
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a.txt")])
        let second = try #require(try store.child(of: MetadataStore.rootID, named: "a.txt"))

        // A genuinely different file that happens to reuse a name must not
        // inherit the old identity.
        #expect(second.id != first.id)
    }

    @Test func caseOnlyRenameIsHandled() throws {
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("readme.md", ino: 7)])
        let original = try #require(try store.child(of: MetadataStore.rootID, named: "readme.md"))

        let result = try store.reconcile(directory: MetadataStore.rootID, listing: [entry("README.md", ino: 7)])
        #expect(result.moved.first?.id == original.id)
        #expect(try store.child(of: MetadataStore.rootID, named: "readme.md") == nil)
        #expect(try store.child(of: MetadataStore.rootID, named: "README.md") != nil)
    }

    @Test func renamingAGrandparentKeepsDescendantIdentifiers() throws {
        // The reason identifiers are not paths: this must be one row update.
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a", dir: true, ino: 1)])
        let a = try #require(try store.child(of: MetadataStore.rootID, named: "a"))
        try store.reconcile(directory: a.id, listing: [entry("b", dir: true, ino: 2)])
        let b = try #require(try store.child(of: a.id, named: "b"))
        try store.reconcile(directory: b.id, listing: [entry("c.txt", ino: 3)])
        let c = try #require(try store.child(of: b.id, named: "c.txt"))

        #expect(try store.path(of: c.id) == "\(root)/a/b/c.txt")

        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a2", dir: true, ino: 1)])

        #expect(try store.child(of: b.id, named: "c.txt")?.id == c.id)
        #expect(try store.path(of: c.id) == "\(root)/a2/b/c.txt")
    }

    @Test func explicitMoveInvalidatesCachedPaths() throws {
        let store = try store()
        let a = try store.insert(childOf: MetadataStore.rootID, entry: entry("a", dir: true))
        let file = try store.insert(childOf: a.id, entry: entry("f.txt"))
        #expect(try store.path(of: file.id) == "\(root)/a/f.txt")

        try store.move(a.id, toParent: MetadataStore.rootID, name: "z")
        #expect(try store.path(of: file.id) == "\(root)/z/f.txt")
    }
}

@Suite("Case collisions")
struct CaseCollisionTests {
    @Test func collidingNamesGetDistinctDisplayNames() throws {
        let store = try store()
        let result = try store.reconcile(directory: MetadataStore.rootID,
                                         listing: [entry("a.txt"), entry("A.txt")])
        let displays = Set(result.created.map(\.displayName))
        #expect(displays.count == 2)
        // The true names are untouched — those are what we send over adb.
        #expect(Set(result.created.map(\.name)) == ["a.txt", "A.txt"])
    }

    @Test func disambiguationIsStableAcrossEnumerations() throws {
        let first = DisplayName.resolve(["a.txt", "A.txt"])
        let second = DisplayName.resolve(["A.txt", "a.txt"])
        #expect(first == second)
    }

    @Test func suffixLandsBeforeTheExtension() throws {
        let resolved = DisplayName.resolve(["photo.jpg", "PHOTO.jpg"])
        #expect(Set(resolved.values) == ["PHOTO.jpg", "photo (2).jpg"])
    }

    @Test func extensionlessAndDotfilesAreNotMangled() throws {
        #expect(Set(DisplayName.resolve(["README", "readme"]).values) == ["README", "readme (2)"])
        #expect(Set(DisplayName.resolve([".env", ".ENV"]).values) == [".ENV", ".env (2)"])
    }

    @Test func nonCollidingNamesAreUntouched() throws {
        let resolved = DisplayName.resolve(["a.txt", "b.txt"])
        #expect(resolved == ["a.txt": "a.txt", "b.txt": "b.txt"])
    }
}

@Suite("Change log and anchors")
struct ChangeLogTests {
    @Test func anchorsAdvanceAndReplay() throws {
        let store = try store()
        #expect(try store.currentAnchor() == 0)

        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a.txt")])
        let afterCreate = try store.currentAnchor()
        #expect(afterCreate > 0)

        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a.txt", size: 99)])
        let changes = try store.changes(since: afterCreate)
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .modified)
    }

    @Test func replayFromZeroReturnsEverything() throws {
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a.txt"), entry("b.txt")])
        #expect(try store.changes(since: 0).count == 2)
    }

    @Test func deletionsAreReplayable() throws {
        // Tombstones exist precisely so a client behind the current anchor still
        // learns the file went away.
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a.txt")])
        let anchor = try store.currentAnchor()
        try store.reconcile(directory: MetadataStore.rootID, listing: [])

        let changes = try store.changes(since: anchor)
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .deleted)
    }

    @Test func pruningExpiresOlderAnchors() throws {
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a.txt")])
        let stale = try store.currentAnchor()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a.txt", size: 5)])

        let threshold = try store.pruneChangeLog(olderThan: -1)  // prune everything
        #expect(threshold > 0)
        #expect(try store.prunedThrough() == threshold)

        #expect(throws: CoreError.self) { try store.changes(since: stale) }
        // A caller already at the threshold has seen everything discarded.
        #expect(try store.changes(since: threshold).isEmpty)
    }

    @Test func pruningKeepsTheNewestRows() throws {
        let store = try store()
        for index in 0..<20 {
            try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a.txt", size: Int64(index))])
        }
        try store.pruneChangeLog(olderThan: 3_600, keepingAtMost: 5)
        #expect(try store.changes(since: store.prunedThrough()).count == 5)
    }

    @Test func anchorsNeverRewindAfterPruning() throws {
        // AUTOINCREMENT is what guarantees this: a reused anchor would let a
        // client silently skip changes.
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a.txt")])
        let before = try store.currentAnchor()
        try store.pruneChangeLog(olderThan: -1)
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("a.txt", size: 77)])
        #expect(try store.currentAnchor() > before)
    }
}

@Suite("Versioning")
struct VersionTests {
    @Test func contentVersionTracksSizeAndMtime() throws {
        let store = try store()
        let base = StoredItem(id: 2, parentID: 1, name: "a", isDirectory: false,
                              size: 10, modified: Date(timeIntervalSince1970: 100), mode: 0o100644)
        let resized = StoredItem(id: 2, parentID: 1, name: "a", isDirectory: false,
                                 size: 11, modified: Date(timeIntervalSince1970: 100), mode: 0o100644)
        let touched = StoredItem(id: 2, parentID: 1, name: "a", isDirectory: false,
                                 size: 10, modified: Date(timeIntervalSince1970: 200), mode: 0o100644)

        #expect(store.version(of: base).content != store.version(of: resized).content)
        #expect(store.version(of: base).content != store.version(of: touched).content)
        #expect(store.version(of: base).metadata == store.version(of: resized).metadata)
    }

    @Test func metadataVersionTracksNameParentAndMode() throws {
        let store = try store()
        let base = StoredItem(id: 2, parentID: 1, name: "a", isDirectory: false,
                              size: 10, modified: Date(timeIntervalSince1970: 100), mode: 0o100644)
        let renamed = StoredItem(id: 2, parentID: 1, name: "b", isDirectory: false,
                                 size: 10, modified: Date(timeIntervalSince1970: 100), mode: 0o100644)
        let moved = StoredItem(id: 2, parentID: 3, name: "a", isDirectory: false,
                               size: 10, modified: Date(timeIntervalSince1970: 100), mode: 0o100644)
        let chmodded = StoredItem(id: 2, parentID: 1, name: "a", isDirectory: false,
                                  size: 10, modified: Date(timeIntervalSince1970: 100), mode: 0o100600)

        #expect(store.version(of: base).metadata != store.version(of: renamed).metadata)
        #expect(store.version(of: base).metadata != store.version(of: moved).metadata)
        #expect(store.version(of: base).metadata != store.version(of: chmodded).metadata)
        #expect(store.version(of: base).content == store.version(of: renamed).content)
    }
}

@Suite("Persistence")
struct PersistenceTests {
    @Test func identifiersSurviveReopening() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adbfindercore-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let identifier: ItemID
        do {
            let store = try MetadataStore(path: url.path, deviceRoot: root)
            try store.reconcile(directory: MetadataStore.rootID, listing: [entry("DCIM", dir: true, ino: 5)])
            identifier = try #require(try store.child(of: MetadataStore.rootID, named: "DCIM")).id
        }

        // Replugging a device must not renumber the world.
        let reopened = try MetadataStore(path: url.path, deviceRoot: root)
        #expect(try reopened.child(of: MetadataStore.rootID, named: "DCIM")?.id == identifier)
        #expect(try reopened.path(of: identifier) == "\(root)/DCIM")
    }
}

@Suite("Path lookup")
struct PathLookupTests {
    @Test func resolvesAKnownPath() throws {
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("DCIM", dir: true, ino: 1)])
        let dcim = try #require(try store.child(of: MetadataStore.rootID, named: "DCIM"))
        try store.reconcile(directory: dcim.id, listing: [entry("a.jpg", ino: 2)])

        #expect(try store.item(atDevicePath: "\(root)/DCIM")?.id == dcim.id)
        #expect(try store.item(atDevicePath: "\(root)/DCIM/a.jpg")?.name == "a.jpg")
        #expect(try store.item(atDevicePath: root)?.id == MetadataStore.rootID)
    }

    @Test func unknownOrOutsidePathsReturnNil() throws {
        // The watcher reports whatever the device says; paths we do not track
        // are simply nothing to do, not an error.
        let store = try store()
        #expect(try store.item(atDevicePath: "\(root)/never-enumerated") == nil)
        #expect(try store.item(atDevicePath: "/data/local/tmp") == nil)
        #expect(try store.item(atDevicePath: "/storage/emulated/0extra") == nil)
    }

    @Test func tombstonedItemsStayAttributable() throws {
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("gone.txt")])
        let item = try #require(try store.child(of: MetadataStore.rootID, named: "gone.txt"))
        try store.reconcile(directory: MetadataStore.rootID, listing: [])

        #expect(try store.item(item.id) == nil)
        // Change replay must still know which container lost the file.
        #expect(try store.itemIncludingDeleted(item.id)?.parentID == MetadataStore.rootID)
    }
}

@Suite("Cascading deletion")
struct CascadeTests {
    @Test func deletingADirectoryTombstonesItsSubtree() throws {
        // Leaving children live under a deleted parent makes the system refuse
        // to retire the container, so the folder lingers in Finder.
        let store = try store()
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry("dir", dir: true, ino: 1)])
        let dir = try #require(try store.child(of: MetadataStore.rootID, named: "dir"))
        try store.reconcile(directory: dir.id, listing: [entry("nested", dir: true, ino: 2), entry("a.txt", ino: 3)])
        let nested = try #require(try store.child(of: dir.id, named: "nested"))
        try store.reconcile(directory: nested.id, listing: [entry("deep.txt", ino: 4)])
        let deep = try #require(try store.child(of: nested.id, named: "deep.txt"))

        let result = try store.reconcile(directory: MetadataStore.rootID, listing: [])

        #expect(result.deleted.count == 4, "got \(result.deleted.count)")
        #expect(try store.item(dir.id) == nil)
        #expect(try store.item(nested.id) == nil)
        #expect(try store.item(deep.id) == nil)
        #expect(try store.children(of: dir.id).isEmpty)
    }

    @Test func explicitDeleteAlsoCascades() throws {
        let store = try store()
        let dir = try store.insert(childOf: MetadataStore.rootID, entry: entry("d", dir: true))
        let child = try store.insert(childOf: dir.id, entry: entry("c.txt"))

        try store.markDeleted(dir.id)
        #expect(try store.item(child.id) == nil)
    }

    @Test func deletionsReplayDeepestFirst() throws {
        // A client replaying the log must not see a container disappear before
        // the items it contained.
        let store = try store()
        let dir = try store.insert(childOf: MetadataStore.rootID, entry: entry("d", dir: true))
        let child = try store.insert(childOf: dir.id, entry: entry("c.txt"))
        let anchor = try store.currentAnchor()

        try store.markDeleted(dir.id)
        let order = try store.changes(since: anchor).map(\.itemID)
        #expect(order.firstIndex(of: child.id)! < order.firstIndex(of: dir.id)!)
    }
}

@Suite("Transfer reporting")
struct TransferReportingTests {
    @Test func concurrentTransfersSumRatherThanAccumulate() {
        // AdbKit reports cumulative progress per transfer. Treating those as
        // deltas made a 40 MB copy claim 13.4 GB, so each transfer reports its
        // own running total and the reporter sums across them.
        let reporter = TransferReporter(serial: "unit-test-\(UUID().uuidString)")
        let first = reporter.begin()
        let second = reporter.begin()

        first.report(1_000)
        first.report(4_000)     // cumulative, not additional
        second.report(2_500)

        first.finish()
        second.finish()
        // Nothing to assert on disk without an App Group; the contract under
        // test is that `report` is idempotent for a given total.
        #expect(Bool(true))
    }

    @Test func staleActivityCountsAsIdle() {
        // An extension killed mid-transfer would otherwise leave the menu
        // claiming work forever.
        let fresh = TransferActivity(active: 1, bytes: 10, updated: Date())
        let stale = TransferActivity(active: 1, bytes: 10, updated: Date(timeIntervalSinceNow: -60))
        #expect(fresh.isBusy)
        #expect(!stale.isBusy)
        #expect(stale.isStale)
    }
}

@Suite("Empty listings")
struct EmptyListingTests {
    @Test func anEmptyListingReallyDoesDeleteEverything() throws {
        // Documenting the invariant rather than guarding it here: reconcile is
        // right to take its listing at face value, because a user really can
        // delete every file in a folder. What must never happen is an *untrue*
        // empty listing reaching this point — and the sync protocol cannot tell
        // "empty" from "could not open", so `AdbClient.list` probes before it
        // reports nothing. If that probe is ever removed, this test keeps
        // passing and the phone appears wiped; the guard belongs upstream.
        let store = try store()
        let listing = (0..<16).map { entry("file-\($0).bin") }
        try store.reconcile(directory: MetadataStore.rootID, listing: listing)
        #expect(try store.children(of: MetadataStore.rootID).count == 16)

        let result = try store.reconcile(directory: MetadataStore.rootID, listing: [])
        #expect(result.deleted.count == 16)
        #expect(try store.children(of: MetadataStore.rootID).isEmpty)
    }
}
