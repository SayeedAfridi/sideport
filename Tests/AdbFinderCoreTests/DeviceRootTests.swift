import Foundation
import Testing
@testable import AdbFinderCore

@Suite("Device root resolution")
struct DeviceRootTests {
    @Test func theResolvedPathIsTriedFirst() {
        let candidates = FinderADB.rootCandidates(resolved: "/storage/emulated/0\n", succeeded: true)
        #expect(candidates == ["/storage/emulated/0"])
    }

    /// The regression. `readlink -f /sdcard` answered `/storage/self/primary` on
    /// a device whose storage had not finished mounting — a well-formed absolute
    /// path that could not be listed. The old code checked only for the leading
    /// slash and cached it, so every enumeration for the rest of that extension's
    /// life failed with "No such file or directory".
    ///
    /// The fix is not that this path is rejected here — it may well be the right
    /// root on another device — but that the documented default is *always* a
    /// candidate behind it, for the caller to fall back to when the first proves
    /// unlistable.
    @Test func anUnmountedResolutionStillLeavesTheDefaultToFallBackOn() {
        let candidates = FinderADB.rootCandidates(resolved: "/storage/self/primary", succeeded: true)
        #expect(candidates == ["/storage/self/primary", "/storage/emulated/0"])
    }

    @Test func aFailedOrEmptyResolutionFallsStraightToTheDefault() {
        #expect(FinderADB.rootCandidates(resolved: "/storage/emulated/0", succeeded: false)
                == ["/storage/emulated/0"])
        #expect(FinderADB.rootCandidates(resolved: nil, succeeded: true)
                == ["/storage/emulated/0"])
        #expect(FinderADB.rootCandidates(resolved: "", succeeded: true)
                == ["/storage/emulated/0"])
    }

    /// A relative answer would be resolved against whatever directory the next
    /// shell happened to start in, which is a different bug wearing the same hat.
    @Test func aRelativeAnswerIsNotACandidate() {
        #expect(FinderADB.rootCandidates(resolved: "emulated/0", succeeded: true)
                == ["/storage/emulated/0"])
    }

    @Test func theDefaultIsNeverListedTwice() {
        let candidates = FinderADB.rootCandidates(resolved: "  /storage/emulated/0  ", succeeded: true)
        #expect(candidates == ["/storage/emulated/0"])
    }
}
