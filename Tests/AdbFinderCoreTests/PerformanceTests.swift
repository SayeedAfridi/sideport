import AdbKit
import Foundation
import Testing
@testable import AdbFinderCore

/// The milestone gate: a directory that Finder re-enumerates on every visit must
/// reconcile fast enough to feel instant. The steady-state (nothing changed)
/// case is the one that runs constantly; the cold case runs once per directory.
@Suite("Reconciliation performance", .serialized)
struct PerformanceTests {
    private static let count = 10_000

    private func listing(changing changed: Int = 0) -> [AdbFileEntry] {
        (0..<Self.count).map { index in
            AdbFileEntry(name: "file-\(index).bin",
                         mode: 0o100644,
                         size: Int64(index < changed ? index + 1_000_000 : index),
                         modified: Date(timeIntervalSince1970: 1_000),
                         dev: 64,
                         ino: UInt64(index + 1_000))
        }
    }

    private func measure(_ label: String, _ body: () throws -> Void) rethrows -> Double {
        let start = Date()
        try body()
        let elapsed = Date().timeIntervalSince(start) * 1_000
        let padded = label.padding(toLength: max(label.count, 34), withPad: " ", startingAt: 0)
        print("  \(padded)  \(String(format: "%7.1f", elapsed)) ms")
        return elapsed
    }

    @Test func tenThousandEntries() throws {
        let store = try MetadataStore(inMemoryDeviceRoot: "/storage/emulated/0")
        let full = listing()

        let cold = try measure("cold — 10k creates") {
            let result = try store.reconcile(directory: MetadataStore.rootID, listing: full)
            #expect(result.created.count == Self.count)
        }

        let steady = try measure("steady state — 10k unchanged") {
            let result = try store.reconcile(directory: MetadataStore.rootID, listing: full)
            #expect(result.isEmpty)
        }

        let incremental = try measure("one change among 10k") {
            let result = try store.reconcile(directory: MetadataStore.rootID, listing: listing(changing: 1))
            #expect(result.modified.count == 1)
        }

        // Steady state is the gate: it happens on every enumeration.
        #expect(steady < 50, "steady-state reconcile of 10k entries took \(steady) ms")
        #expect(incremental < 50, "incremental reconcile took \(incremental) ms")
        // Cold is a one-off per directory, so it gets a looser budget.
        #expect(cold < 500, "cold reconcile of 10k entries took \(cold) ms")
    }

    @Test func deepPathResolutionStaysCheap() throws {
        let store = try MetadataStore(inMemoryDeviceRoot: "/storage/emulated/0")
        var parent = MetadataStore.rootID
        for depth in 0..<64 {
            parent = try store.insert(childOf: parent,
                                      entry: AdbFileEntry(name: "d\(depth)", mode: 0o040755,
                                                          size: 0, modified: Date())).id
        }

        let elapsed = try measure("1000 resolutions at depth 64") {
            for _ in 0..<1_000 { _ = try store.path(of: parent) }
        }
        #expect(try store.path(of: parent).hasSuffix("/d63"))
        #expect(elapsed < 50, "cached path resolution took \(elapsed) ms")
    }
}
