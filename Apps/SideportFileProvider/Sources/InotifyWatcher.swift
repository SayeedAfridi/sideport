import AdbFinderCore
import AdbKit
import Foundation

/// Watches device directories and reports which ones changed.
///
/// Android's toybox ships `inotifyd`, so change detection is push rather than
/// polling: a photo taken on the phone reaches Finder without anyone asking.
///
/// Two properties of inotify shape everything here. It is **not recursive** —
/// each directory needs its own watch — and the per-user watch count is capped
/// by a `/proc` limit we cannot even read as the `shell` user. So watches are
/// lazy (only directories actually visited), bounded, and evicted oldest-first.
actor InotifyWatcher {
    /// Which directories to arm, and what to report.
    private let client: AdbClient
    private let selector: DeviceSelector
    private let onChange: @Sendable ([String]) async -> Void

    /// Watched directory paths, with when each was last visited.
    private var watched: [String: Date] = [:]
    private static let watchLimit = 200

    private var streamTask: Task<Void, Never>?
    private var rearmTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pending: Set<String> = []

    /// Only *short-lived* stream failures count. A stream that ran for a while
    /// and then ended is a normal reconnect, not evidence of a broken device.
    private var consecutiveFailures = 0
    private var pollingFallback: Task<Void, Never>?
    /// Bumped on every re-arm. A superseded stream must not trigger recovery:
    /// counting an intentional restart as a failure drove the exponential
    /// backoff up to 16s and then into the polling fallback, which is exactly
    /// how a sub-second watcher turned into a ten-second one.
    private var generation = 0

    /// Events we care about, in toybox's mask alphabet:
    /// `n` created · `c` modified · `d` deleted · `w` closed-writable ·
    /// `m`/`y` moved out/in · `D` the directory itself deleted.
    private static let mask = "ncdwmyD"

    init(client: AdbClient,
         selector: DeviceSelector,
         onChange: @escaping @Sendable ([String]) async -> Void) {
        self.client = client
        self.selector = selector
        self.onChange = onChange
    }

    // MARK: - Registration

    /// Registers a directory, restarting the watcher if the set actually grew.
    ///
    /// Called on every enumeration, so the common case — a directory we already
    /// watch — must be free beyond refreshing its timestamp.
    func watch(_ path: String) {
        let isNew = watched[path] == nil
        watched[path] = Date()

        if watched.count > Self.watchLimit {
            // Evict the least recently visited; the user is not looking there.
            let excess = watched.sorted { $0.value < $1.value }
                .prefix(watched.count - Self.watchLimit)
            for (path, _) in excess { watched.removeValue(forKey: path) }
        }
        guard isNew else { return }
        scheduleRearm()
    }

    /// Drops a directory that no longer exists.
    ///
    /// This is not housekeeping, it is correctness: `inotifyd` refuses to start
    /// at all if any of its arguments is missing, so a single deleted folder
    /// left in the set silently kills change detection for the whole device.
    func unwatch(_ paths: [String]) {
        var removed = false
        for path in paths where watched.removeValue(forKey: path) != nil { removed = true }
        // Anything beneath a removed directory is gone too.
        for key in watched.keys where paths.contains(where: { key.hasPrefix($0 + "/") }) {
            watched.removeValue(forKey: key)
            removed = true
        }
        if removed { scheduleRearm() }
    }

    func stop() {
        streamTask?.cancel(); streamTask = nil
        rearmTask?.cancel(); rearmTask = nil
        flushTask?.cancel(); flushTask = nil
        pollingFallback?.cancel(); pollingFallback = nil
    }

    /// Restarting `inotifyd` per directory would thrash while someone clicks
    /// through a tree, so changes to the watch set are batched.
    private func scheduleRearm() {
        rearmTask?.cancel()
        rearmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.restart(catchUp: false)
        }
    }

    /// Arms the watch set, handing over from whatever stream is already running.
    ///
    /// `catchUp` reconciles every watched directory once the stream is up. That
    /// is worth its cost only when there was a real gap — after a failure, or on
    /// the first arm — and ruinous otherwise: every directory the user opens
    /// re-arms, so catching up on each one re-listed every directory watched so
    /// far. Browsing 55 directories took 36 s that way, almost all of it
    /// re-listing folders nothing had happened in.
    ///
    /// A deliberate re-arm has no gap to cover, because the outgoing stream
    /// keeps reporting until the incoming one is established.
    private func restart(catchUp: Bool) {
        pollingFallback?.cancel()
        pollingFallback = nil
        generation += 1
        let mine = generation

        guard !watched.isEmpty else {
            streamTask?.cancel()
            streamTask = nil
            return
        }

        let outgoing = streamTask
        let needsCatchUp = catchUp || outgoing == nil

        streamTask = Task { [weak self] in
            guard let self else { outgoing?.cancel(); return }
            // One round trip to drop paths the device no longer has. Cheaper
            // than the 30s backoff that a single missing path would otherwise
            // cost, and re-arming is debounced anyway.
            let paths = await self.existingPaths(from: await self.watchedPaths())
            guard !paths.isEmpty else { outgoing?.cancel(); return }
            await self.runStream(paths: paths, generation: mine,
                                 catchUp: needsCatchUp, outgoing: outgoing)
        }
    }

    private func watchedPaths() -> [String] { watched.keys.sorted() }

    /// Filters the watch set down to directories that still exist.
    private func existingPaths(from candidates: [String]) async -> [String] {
        guard !candidates.isEmpty else { return [] }
        let probe = candidates
            .map { "[ -d \(adbShellQuote($0)) ] && echo \(adbShellQuote($0))" }
            .joined(separator: "; ")
        guard let result = try? await client.shell(probe, on: selector) else { return candidates }

        let alive = Set(result.stdout.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        let gone = candidates.filter { !alive.contains($0) }
        if !gone.isEmpty {
            Log.watch.info("dropping \(gone.count, privacy: .public) watch(es) for missing directories")
            for path in gone { watched.removeValue(forKey: path) }
        }
        return candidates.filter { alive.contains($0) }
    }

    // MARK: - Event stream

    private func runStream(paths: [String], generation mine: Int,
                          catchUp: Bool, outgoing: Task<Void, Never>?) async {
        let spec = paths.map { "\(adbShellQuote($0)):\(Self.mask)" }.joined(separator: " ")
        Log.watch.info("arming \(paths.count, privacy: .public) watches")
        let openedAt = Date()

        // Hand over rather than swap: the outgoing stream keeps reporting until
        // this one is established. Its events are still real events, and a
        // duplicate costs nothing because `pending` is a set — whereas a gap
        // costs a change nobody ever hears about.
        let handover = Task {
            try? await Task.sleep(for: .milliseconds(750))
            outgoing?.cancel()
        }
        let catchUpTask: Task<Void, Never>? = catchUp
            ? Task { [onChange] in await onChange(paths) }
            : nil

        var superseded = false
        do {
            for try await line in client.shellLines("inotifyd - \(spec)", on: selector) {
                // Deliberately not gated on `generation`: while a successor is
                // starting up this stream is still the one holding the fort.
                if Task.isCancelled { superseded = true; break }
                handle(line: line, watched: paths)
            }
            if !Task.isCancelled { Log.watch.info("watcher stream ended") }
        } catch {
            if Task.isCancelled || mine != generation {
                superseded = true
            } else {
                Log.watch.error("watcher failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        handover.cancel()
        outgoing?.cancel()
        _ = await catchUpTask?.value

        // Superseded by a newer arm: that stream owns recovery now.
        guard !superseded, !Task.isCancelled, mine == generation else { return }

        // A stream that survived a while was working; its ending is a reconnect,
        // not a failure. Only rapid, repeated collapse means something is wrong.
        if Date().timeIntervalSince(openedAt) > 10 {
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
        }
        await recover()
    }

    /// `inotifyd` prints `EVENT<TAB>DIRECTORY[<TAB>NAME]`.
    private func handle(line: String, watched paths: [String]) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let event = fields.first, fields.count >= 2 else { return }
        Log.watch.debug("event \(event, privacy: .public) in \(fields[1], privacy: .public)")

        // Overflow means the kernel dropped events, and unwatchable means a
        // watch died. Either way our incremental picture is untrustworthy, so
        // rescan everything rather than pretend.
        if event.contains("o") || event.contains("x") {
            Log.watch.info("event queue overflowed — rescanning all watches")
            pending.formUnion(paths)
            scheduleFlush()
            return
        }

        // `c` fires repeatedly while a large file is being written; `w`
        // (closed-writable) fires once when it is finished. Acting on `c` would
        // re-list the directory for every buffer the writer flushes.
        guard event.contains(where: { "nwdmyD".contains($0) }) else { return }

        pending.insert(fields[1])
        scheduleFlush()
    }

    /// Batches bursts — unzipping an archive on the phone produces hundreds of
    /// events for one directory.
    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() async {
        Log.watch.debug("flush of \(self.pending.count, privacy: .public) path(s)")
        let batch = pending
        pending.removeAll()
        guard !batch.isEmpty else { return }
        Log.watch.debug("changed: \(batch.count, privacy: .public) director(ies)")
        await onChange(Array(batch))
    }

    // MARK: - Recovery

    /// Reconnects with backoff, and gives up on push after repeated failures.
    private func recover() async {
        // A healthy reconnect should be near-instant; only repeated failure
        // earns a wait.
        let delay = consecutiveFailures == 0
            ? 0.2
            : Double(min(30, Int(pow(2.0, Double(min(consecutiveFailures, 5))))))
        Log.watch.info("reconnecting watcher in \(delay, privacy: .public)s (failures: \(self.consecutiveFailures, privacy: .public))")
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }

        if consecutiveFailures >= 4 {
            startPollingFallback()
            return
        }
        // A recovery *did* have a gap, so this one earns its catch-up.
        restart(catchUp: true)
    }

    /// Used when `inotifyd` is missing or refused — older devices, or a locked
    /// down build. A full directory scan of the reference device takes 0.59 s,
    /// so polling only what the user is looking at is cheap enough to be a
    /// credible backstop.
    private func startPollingFallback() {
        guard pollingFallback == nil else { return }
        Log.watch.info("falling back to polling")
        pollingFallback = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                await self.pollMostRecent()
            }
        }
    }

    private func pollMostRecent() async {
        let recent = watched.sorted { $0.value > $1.value }.prefix(5).map(\.key)
        guard !recent.isEmpty else { return }
        await onChange(recent)
    }
}
