import AdbKit
import Foundation
import Testing
@testable import AdbFinderCore

// macOS writes NFD, most other systems write NFC, and Android's filesystem
// keeps whatever bytes it was handed. So a phone that has ever received a file
// from a Mac can hold both spellings of one name — two files that Swift and
// APFS each consider a single name.

private let nfc = "caf\u{00E9}.txt"      // é as one scalar
private let nfd = "cafe\u{0301}.txt"     // e + combining acute

private func entry(_ name: String, size: Int64 = 1) -> AdbFileEntry {
    AdbFileEntry(name: name, mode: 0o100644, size: size,
                 modified: Date(timeIntervalSince1970: 1000), dev: nil, ino: nil)
}

@Suite("Unicode normalization")
struct NormalizationTests {
    @Test func swiftConsidersTheTwoSpellingsOneName() {
        // The premise, asserted rather than assumed: this is why the rest of
        // this file exists.
        #expect(nfc == nfd)
        #expect(nfc.hashValue == nfd.hashValue)
        #expect(Array(nfc.utf8) != Array(nfd.utf8))
    }

    @Test func reconcilingBothDoesNotTrap() throws {
        // Before `ExactName`, the second pass died with "Fatal error: Duplicate
        // values for key" and took the extension with it.
        let store = try MetadataStore(inMemoryDeviceRoot: "/storage/emulated/0")
        let listing = [entry(nfc), entry(nfd)]

        try store.reconcile(directory: MetadataStore.rootID, listing: listing)
        #expect(try store.children(of: MetadataStore.rootID).count == 2)

        // The second pass is the dangerous one: the store now holds both rows.
        try store.reconcile(directory: MetadataStore.rootID, listing: listing)
        #expect(try store.children(of: MetadataStore.rootID).count == 2)
    }

    @Test func bothKeepTheirOwnBytes() throws {
        let store = try MetadataStore(inMemoryDeviceRoot: "/storage/emulated/0")
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry(nfc), entry(nfd)])
        let stored = try store.children(of: MetadataStore.rootID).map { Array($0.name.utf8) }
        #expect(stored.contains(Array(nfc.utf8)))
        #expect(stored.contains(Array(nfd.utf8)))
    }

    @Test func theyGetDistinctDisplayNames() {
        // APFS is normalisation-insensitive, so showing both as "café.txt" would
        // have one shadow the other exactly as a case collision would.
        let resolved = DisplayName.resolve([nfc, nfd])
        #expect(Set(resolved.values).count == 2)
    }

    @Test func displayNamesDoNotSwapBetweenRefreshes() {
        // `sorted()` on canonically-equivalent strings is unstable, so the
        // ordering has to come from the bytes.
        let first = DisplayName.resolve([nfc, nfd])
        let second = DisplayName.resolve([nfd, nfc])
        #expect(first == second)
    }

    @Test func aModifiedEntryStillMatchesItsOwnRow() throws {
        // Pass 1 must pair each entry with the row carrying the same bytes, not
        // merely a canonically-equal one, or an edit to one file would be
        // written onto the other.
        let store = try MetadataStore(inMemoryDeviceRoot: "/storage/emulated/0")
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry(nfc), entry(nfd)])
        let result = try store.reconcile(directory: MetadataStore.rootID,
                                         listing: [entry(nfc, size: 99), entry(nfd)])
        #expect(result.modified.count == 1)
        #expect(Array(result.modified.first!.name.utf8) == Array(nfc.utf8))
        #expect(result.modified.first!.size == 99)
        #expect(result.deleted.isEmpty)
        #expect(result.created.isEmpty)
    }

    @Test func deletingOneLeavesTheOther() throws {
        let store = try MetadataStore(inMemoryDeviceRoot: "/storage/emulated/0")
        try store.reconcile(directory: MetadataStore.rootID, listing: [entry(nfc), entry(nfd)])
        let result = try store.reconcile(directory: MetadataStore.rootID, listing: [entry(nfd)])
        #expect(result.deleted.count == 1)
        let survivors = try store.children(of: MetadataStore.rootID)
        #expect(survivors.count == 1)
        #expect(Array(survivors[0].name.utf8) == Array(nfd.utf8))
    }
}
