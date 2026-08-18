import Foundation
import Testing
@testable import AdbFinderCore

// The system rejects a range that stops mid-block, and trusts us about the
// bytes we claim to have fetched. Both failure modes are off-by-one, so these
// check boundaries rather than typical cases.

@Suite("Partial fetch ranges")
struct RangeAlignmentTests {
    private let alignment = 4096
    private let minimum = 512 * 1024

    private func fetch(_ location: Int, _ length: Int, size: Int64) -> NSRange {
        RangeAlignment.fetch(covering: NSRange(location: location, length: length),
                             alignment: alignment, fileSize: size, atLeast: minimum)
    }

    @Test func startsOnAnAlignmentBoundary() {
        let r = fetch(5000, 100, size: 10_000_000)
        #expect(r.location % alignment == 0)
        #expect(r.location <= 5000)
    }

    @Test func coversEverythingThatWasAskedFor() {
        let r = fetch(5000, 100, size: 10_000_000)
        #expect(r.location <= 5000)
        #expect(r.location + r.length >= 5100)
    }

    @Test func endsOnABoundaryUnlessItIsEndOfFile() {
        let interior = fetch(5000, 100, size: 10_000_000)
        #expect((interior.location + interior.length) % alignment == 0)

        // The last block of a file is the one legitimate exception, and the
        // range must stop at the file rather than past it.
        let size: Int64 = 1_000_003
        let tail = fetch(999_000, 100, size: size)
        #expect(tail.location + tail.length == Int(size))
    }

    @Test func neverClaimsBytesPastTheEnd() {
        let size: Int64 = 100_000
        for offset in stride(from: 0, to: 100_000, by: 7919) {
            let r = fetch(offset, 64, size: size)
            #expect(r.location + r.length <= Int(size), "offset \(offset)")
        }
    }

    @Test func amortisesTinyReads() {
        // A 4 KB request should not cost a round trip for 4 KB.
        let r = fetch(0, 4096, size: 10_000_000)
        #expect(r.length >= minimum)
    }

    @Test func doesNotOverfetchBeyondASmallFile() {
        let r = fetch(0, 16, size: 1000)
        #expect(r == NSRange(location: 0, length: 1000))
    }

    @Test func aStartPastTheEndReturnsNothing() {
        #expect(fetch(200_000, 64, size: 100_000).length == 0)
        #expect(fetch(0, 64, size: 0).length == 0)
    }

    @Test func aZeroLengthRequestStillFetchesTheByteThere() {
        let r = fetch(8192, 0, size: 10_000_000)
        #expect(r.length > 0)
        #expect(r.location <= 8192 && r.location + r.length > 8192)
    }

    @Test func handlesAnAlignmentOfOne() {
        let r = RangeAlignment.fetch(covering: NSRange(location: 7, length: 3),
                                     alignment: 1, fileSize: 10_000, atLeast: 0)
        #expect(r.location == 7)
        #expect(r.length >= 3)
    }
}
