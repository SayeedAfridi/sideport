import Foundation

/// Works out which bytes to actually fetch for a partial read.
///
/// Lives here rather than beside the extension so it can be tested: the failure
/// modes are all off-by-one — a range that stops mid-block is rejected by the
/// system, and one that runs past the end claims bytes the file does not have.
public enum RangeAlignment {
    /// Grows `wanted` outward to `alignment`, then to `minimum`, then clips to
    /// the file.
    ///
    /// `minimum` exists to amortise the fixed cost of a ranged read: fetching
    /// exactly what a reader asked for would pay ~75 ms of setup for every 4 KB
    /// it wants. Over-fetching is free to the caller because the system keeps
    /// whatever range it is given.
    public static func fetch(covering wanted: NSRange,
                             alignment: Int,
                             fileSize: Int64,
                             atLeast minimum: Int) -> NSRange {
        let alignment = max(alignment, 1)
        let size = max(fileSize, 0)
        guard size > 0, wanted.location >= 0 else {
            return NSRange(location: 0, length: 0)
        }

        let clampedSize = Int(clamping: size)
        // A read starting past the end has nothing to return; saying so beats
        // handing back a zero-length range at a nonsensical offset.
        guard wanted.location < clampedSize else {
            return NSRange(location: 0, length: 0)
        }

        let start = (wanted.location / alignment) * alignment
        // A zero-length request still means "at least one byte here" — the
        // caller wants to know what is at that offset.
        let wantedEnd = wanted.location + max(wanted.length, 1)
        let span = max(wantedEnd - start, minimum)

        var end = start + ((span + alignment - 1) / alignment) * alignment
        // Clipping to the file is what makes the final block legal despite not
        // being aligned: end of file is the one permitted exception.
        end = min(end, clampedSize)

        return NSRange(location: start, length: max(end - start, 0))
    }
}
