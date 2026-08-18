import Foundation

/// Decides whether a partial read should stay partial.
///
/// Serving exactly what the system asks for is a trap. It asks in 4 KB units
/// and never falls back to whole-file fetching on its own, so a plain
/// `cat` of a 181 MB file became 362 ranged reads at 0.7 MB/s — against
/// 33 MB/s for the whole-file path it displaced. Partial fetching is a latency
/// win for a reader that wants a little of a lot; it is a catastrophe for one
/// that wants all of it.
///
/// So the plan grows: the first read of a region is small and cheap, a reader
/// that keeps going gets geometrically larger windows, and one that is plainly
/// streaming the file is given the whole thing over the faster transport.
public enum PartialFetchPlan {
    public enum Decision: Equatable {
        /// Fetch this aligned range over the ranged-read path.
        case range(NSRange)
        /// Stop pretending: pull the file and report full materialisation.
        case wholeFile
    }

    /// Below this a whole-file pull beats any sequence of ranges — at 33 MB/s
    /// it is under a second, which no number of round trips will match.
    public static let alwaysWholeFile: Int64 = 32 * 1024 * 1024

    /// First window. Small enough not to waste a random probe, large enough to
    /// amortise the ~75 ms setup over more than one 4 KB read.
    public static let initialWindow = 512 * 1024

    /// Ceiling on the geometric growth: past this, a single ranged read already
    /// takes about a second and further growth only delays first bytes.
    public static let maximumWindow = 8 * 1024 * 1024

    /// Sequential bytes served before a reader is treated as streaming.
    public static let streamingThreshold = 32 * 1024 * 1024

    /// What one item's reads have looked like so far.
    public struct History: Equatable, Sendable {
        /// Where the last served range ended; the next request starting here is
        /// what "sequential" means.
        public var nextExpectedOffset: Int
        /// Bytes served in the current sequential run.
        public var sequentialBytes: Int
        /// The window used for the last sequential read.
        public var window: Int

        public init(nextExpectedOffset: Int = -1, sequentialBytes: Int = 0, window: Int = 0) {
            self.nextExpectedOffset = nextExpectedOffset
            self.sequentialBytes = sequentialBytes
            self.window = window
        }
    }

    /// Plans one fetch and reports the history to carry into the next.
    public static func plan(for wanted: NSRange,
                            alignment: Int,
                            fileSize: Int64,
                            history: History) -> (decision: Decision, next: History) {
        guard fileSize > 0 else { return (.range(NSRange(location: 0, length: 0)), History()) }
        guard fileSize > alwaysWholeFile else { return (.wholeFile, History()) }

        let continues = wanted.location == history.nextExpectedOffset
        let window = continues
            ? min(max(history.window * 2, initialWindow), maximumWindow)
            : initialWindow
        let sequentialBytes = continues ? history.sequentialBytes : 0

        // A reader this far into a file in order is reading the file, not
        // sampling it. Give it the fast transport.
        if continues && sequentialBytes >= streamingThreshold {
            return (.wholeFile, History())
        }

        let range = RangeAlignment.fetch(covering: wanted,
                                         alignment: alignment,
                                         fileSize: fileSize,
                                         atLeast: window)
        let next = History(nextExpectedOffset: range.location + range.length,
                           sequentialBytes: sequentialBytes + range.length,
                           window: window)
        return (.range(range), next)
    }
}
