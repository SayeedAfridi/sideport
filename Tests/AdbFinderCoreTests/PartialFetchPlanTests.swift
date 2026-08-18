import Foundation
import Testing
@testable import AdbFinderCore

// The system asks in 4 KB units and never falls back to whole-file fetching by
// itself, so these tests are really about one question: does a reader that is
// working through a file end up on the fast transport before it has paid for
// hundreds of round trips?

@Suite("Partial fetch planning")
struct PartialFetchPlanTests {
    private let alignment = 4096
    private let big: Int64 = 500 * 1024 * 1024

    private func plan(_ location: Int, _ length: Int = 4096,
                      size: Int64? = nil,
                      history: PartialFetchPlan.History = .init())
    -> (PartialFetchPlan.Decision, PartialFetchPlan.History) {
        PartialFetchPlan.plan(for: NSRange(location: location, length: length),
                              alignment: alignment,
                              fileSize: size ?? big,
                              history: history)
    }

    @Test func smallFilesSkipRangesEntirely() {
        // Under a second over the whole-file transport; no sequence of ranged
        // reads can beat that.
        let (decision, _) = plan(0, size: 8 * 1024 * 1024)
        #expect(decision == .wholeFile)
    }

    @Test func aFirstReadOfALargeFileIsASmallRange() {
        let (decision, _) = plan(100_000_000)
        guard case .range(let r) = decision else { Issue.record("expected a range"); return }
        #expect(r.length == PartialFetchPlan.initialWindow)
        #expect(r.location <= 100_000_000)
    }

    @Test func randomReadsStaySmall() {
        var history = PartialFetchPlan.History()
        for offset in [10_000_000, 400_000_000, 50_000_000, 300_000_000] {
            let (decision, next) = plan(offset, history: history)
            guard case .range(let r) = decision else { Issue.record("expected a range"); return }
            #expect(r.length == PartialFetchPlan.initialWindow, "offset \(offset)")
            history = next
        }
    }

    @Test func sequentialReadsGrowGeometrically() {
        var history = PartialFetchPlan.History()
        var lengths: [Int] = []
        var offset = 0
        for _ in 0..<5 {
            let (decision, next) = plan(offset, history: history)
            guard case .range(let r) = decision else { Issue.record("expected a range"); return }
            lengths.append(r.length)
            offset = r.location + r.length
            history = next
        }
        #expect(lengths == [524_288, 1_048_576, 2_097_152, 4_194_304, 8_388_608])
    }

    @Test func theWindowStopsGrowing() {
        var history = PartialFetchPlan.History()
        var offset = 0
        var last = 0
        for _ in 0..<8 {
            let (decision, next) = plan(offset, history: history)
            guard case .range(let r) = decision else { return }
            last = r.length
            offset = r.location + r.length
            history = next
        }
        #expect(last <= PartialFetchPlan.maximumWindow)
    }

    @Test func aReaderStreamingTheFileGetsTheFastTransport() {
        // This is the regression the whole file exists for: without it, reading
        // a 181 MB file took 362 ranged reads and 243 seconds.
        var history = PartialFetchPlan.History()
        var offset = 0
        var calls = 0
        var escalated = false
        while calls < 100 {
            let (decision, next) = plan(offset, history: history)
            calls += 1
            if decision == .wholeFile { escalated = true; break }
            guard case .range(let r) = decision else { break }
            offset = r.location + r.length
            history = next
        }
        #expect(escalated, "a sequential reader never escalated")
        #expect(calls <= 12, "took \(calls) ranged reads before escalating")
    }

    @Test func seekingAwayResetsTheGrowth() {
        var history = PartialFetchPlan.History()
        var offset = 0
        for _ in 0..<4 {
            let (decision, next) = plan(offset, history: history)
            guard case .range(let r) = decision else { return }
            offset = r.location + r.length
            history = next
        }
        // A jump elsewhere is a different access pattern, not a continuation.
        let (decision, _) = plan(400_000_000, history: history)
        guard case .range(let r) = decision else { Issue.record("expected a range"); return }
        #expect(r.length == PartialFetchPlan.initialWindow)
    }
}
