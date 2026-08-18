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

    private var consecutiveFailures = 0
    private var pollingFallback: Task<Void, Never>?

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
            await self?.restart()
        }
    }

    private func restart() {
        streamTask?.cancel()
        let paths = watched.keys.sorted()
        guard !paths.isEmpty else { return }

        streamTask = Task { [weak self] in
            await self?.runStream(paths: paths)
        }
    }

    // MARK: - Event stream

    private func runStream(paths: [String]) async {
        let spec = paths.map { "\(adbShellQuote($0)):\(Self.mask)" }.joined(separator: " ")
        Log.watch.info("arming \(paths.count, privacy: .public) watches")

        do {
            for try await line in client.shellLines("inotifyd - \(spec)", on: selector) {
                guard !Task.isCancelled else { return }
                consecutiveFailures = 0
                handle(line: line, watched: paths)
            }
            // A clean end means inotifyd exited — every watch became
            // unwatchable, or the device went away.
            Log.watch.info("watcher stream ended")
        } catch {
            guard !Task.isCancelled else { return }
            Log.watch.error("watcher failed: \(error.localizedDescription, privacy: .public)")
        }

        guard !Task.isCancelled else { return }
        consecutiveFailures += 1
        await recover()
    }

    /// `inotifyd` prints `EVENT<TAB>DIRECTORY[<TAB>NAME]`.
    private func handle(line: String, watched paths: [String]) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let event = fields.first, fields.count >= 2 else { return }

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
        let batch = pending
        pending.removeAll()
        guard !batch.isEmpty else { return }
        Log.watch.debug("changed: \(batch.count, privacy: .public) director(ies)")
        await onChange(Array(batch))
    }

    // MARK: - Recovery

    /// Reconnects with backoff, and gives up on push after repeated failures.
    private func recover() async {
        let delay = min(30, Int(pow(2.0, Double(min(consecutiveFailures, 5)))))
        Log.watch.info("retrying watcher in \(delay, privacy: .public)s")
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }

        if consecutiveFailures >= 4 {
            startPollingFallback()
            return
        }
        restart()
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
