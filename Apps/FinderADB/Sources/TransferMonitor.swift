import AdbFinderCore
import FileProvider
import Foundation

/// What the *system* knows about a domain's pending transfers.
///
/// This is a different question from "what is on the wire right now", and the
/// difference is the whole reason this file exists. A copy into the device
/// lands in the local replica first — at local-disk speed — and Finder's copy
/// sheet closes there. Only afterwards does the system start handing the
/// extension files one at a time, at USB speed. An 11 GB folder reported
/// "copied" and then spent four and a half more minutes going over the cable,
/// with nothing anywhere saying so.
///
/// The extension can only ever report the six sockets it holds open; the queued
/// nine hundred and something files behind them are the system's, and the
/// system's global progress is the only place they are counted.
struct TransferProgress: Equatable {
    var completedItems = 0
    var totalItems = 0
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0

    var isActive: Bool { totalItems > 0 || totalBytes > 0 }

    /// Reads as "Uploading 412 of 1072 — 6.8 GB left".
    ///
    /// Bytes *remaining* rather than bytes total, because the question someone
    /// opens this menu to ask is how much longer.
    func summary(verb: String) -> String? {
        guard isActive else { return nil }
        var parts = [verb]
        if totalItems > 0 { parts.append("\(completedItems) of \(totalItems)") }
        let remaining = totalBytes - completedBytes
        if remaining > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            parts.append("— \(formatter.string(fromByteCount: remaining)) left")
        }
        return parts.joined(separator: " ")
    }
}

/// Both directions for one device.
struct DeviceTransfers: Equatable {
    var uploading = TransferProgress()
    var downloading = TransferProgress()

    var isBusy: Bool { uploading.isActive || downloading.isActive }

    /// Uploads win when both are running: a copy *to* the phone is the one that
    /// outlives its Finder progress sheet, so it is the one worth reporting.
    var summary: String? {
        uploading.summary(verb: "Uploading") ?? downloading.summary(verb: "Downloading")
    }
}

/// Watches `NSFileProviderManager`'s global progress for the registered domains.
///
/// The progress objects are live: they must be **retained** and read through
/// KVO, not fetched and sampled. A fresh `globalProgress(for:)` on every poll
/// would hand back an object with nothing attached to it yet.
@MainActor
final class TransferMonitor {
    /// Fires when a device's figures move. Main actor, deduplicated.
    var onChange: ((String, DeviceTransfers) -> Void)?

    private final class Watch {
        let uploading: Progress
        let downloading: Progress
        var tokens: [NSKeyValueObservation] = []
        var uploadFloor = Floor()
        var downloadFloor = Floor()

        init(uploading: Progress, downloading: Progress) {
            self.uploading = uploading
            self.downloading = downloading
        }
    }

    /// The furthest a direction has got through the total it is working on.
    private struct Floor {
        var total: Int64 = -1
        var completed: Int64 = 0
    }

    private var watches: [String: Watch] = [:]
    private var latest: [String: DeviceTransfers] = [:]

    func transfers(for serial: String) -> DeviceTransfers { latest[serial] ?? DeviceTransfers() }

    /// Watches the domains belonging to `serials`, and forgets the rest.
    func track(_ serials: [String], domains: [NSFileProviderDomain]) {
        for serial in watches.keys where !serials.contains(serial) {
            watches.removeValue(forKey: serial)
            latest.removeValue(forKey: serial)
        }

        for domain in domains {
            let serial = domain.identifier.rawValue
            guard serials.contains(serial), watches[serial] == nil else { continue }
            guard let manager = NSFileProviderManager(for: domain) else {
                Log.domain.error("""
                    no manager for \(serial, privacy: .public); transfer progress unavailable
                    """)
                continue
            }
            let watch = Watch(uploading: manager.globalProgress(for: .uploading),
                              downloading: manager.globalProgress(for: .downloading))
            watches[serial] = watch
            watch.tokens = observe(watch, serial: serial)
            publish(serial)
        }
    }

    /// The item counts are deliberately absent from this list.
    ///
    /// `fileTotalCount` and `fileCompletedCount` are Swift-side conveniences
    /// over `userInfo`, not `@objc dynamic` properties, so they have no
    /// Objective-C key path — and `observe(_:)` does not fail softly on one. It
    /// traps: *"Could not extract a String from KeyPath \NSProgress.<computed…>"*,
    /// which takes the whole menu bar app down at launch.
    ///
    /// They are still perfectly readable; they just have to be read from a
    /// handler woken by something that is observable. Every change to them
    /// arrives alongside a unit-count change, so nothing is missed.
    private func observe(_ watch: Watch, serial: String) -> [NSKeyValueObservation] {
        var tokens: [NSKeyValueObservation] = []
        for progress in [watch.uploading, watch.downloading] {
            // `fractionCompleted` alone is not enough. A queue that grows while
            // the fraction happens to hold still would never report, and it is
            // `isFinished` that clears the line from the menu at the end.
            tokens.append(progress.observe(\.fractionCompleted) { [weak self] _, _ in
                Task { @MainActor in self?.publish(serial) }
            })
            tokens.append(progress.observe(\.completedUnitCount) { [weak self] _, _ in
                Task { @MainActor in self?.publish(serial) }
            })
            tokens.append(progress.observe(\.totalUnitCount) { [weak self] _, _ in
                Task { @MainActor in self?.publish(serial) }
            })
            tokens.append(progress.observe(\.isFinished) { [weak self] _, _ in
                Task { @MainActor in self?.publish(serial) }
            })
        }
        return tokens
    }

    private func publish(_ serial: String) {
        guard let watch = watches[serial] else { return }
        let current = DeviceTransfers(uploading: snapshot(watch.uploading, floor: &watch.uploadFloor),
                                      downloading: snapshot(watch.downloading, floor: &watch.downloadFloor))
        guard current != latest[serial] else { return }
        // Debug rather than info: this fires per progress update, which during a
        // large copy is several times a second.
        Log.domain.debug("""
            transfers \(serial, privacy: .public): \
            up \(current.uploading.completedItems, privacy: .public)/\
            \(current.uploading.totalItems, privacy: .public) items \
            \(current.uploading.completedBytes, privacy: .public)/\
            \(current.uploading.totalBytes, privacy: .public) bytes · \
            down \(current.downloading.completedItems, privacy: .public)/\
            \(current.downloading.totalItems, privacy: .public) items \
            \(current.downloading.completedBytes, privacy: .public)/\
            \(current.downloading.totalBytes, privacy: .public) bytes
            """)
        latest[serial] = current
        onChange?(serial, current)
    }

    /// Idle is spelled "finished, with every count set to 1". Reading that as a
    /// real figure would leave the menu claiming one item forever, so the
    /// finished state is turned back into zeroes before anything else looks.
    private func snapshot(_ progress: Progress, floor: inout Floor) -> TransferProgress {
        guard !progress.isFinished else {
            floor = Floor()
            return TransferProgress()
        }

        // Indeterminate is -1, which would print as a negative amount remaining.
        let total = max(progress.totalUnitCount, 0)

        // The system re-sums as items complete, and the raw byte counter steps
        // *backwards* when it does: 336 MB back to 251 MB of the same 503 MB
        // mid-copy, and all the way to zero on the last file. Rendered as bytes
        // remaining, that reads as the copy growing just before it finishes —
        // which is the same kind of lie this whole file exists to stop telling.
        //
        // So a direction is held to its high-water mark for as long as the
        // total it belongs to is unchanged. A total that moves is new work
        // arriving, and resets it.
        if total != floor.total { floor = Floor(total: total, completed: 0) }
        let completed = min(max(max(progress.completedUnitCount, 0), floor.completed), total)
        floor.completed = completed

        return TransferProgress(completedItems: progress.fileCompletedCount ?? 0,
                                totalItems: progress.fileTotalCount ?? 0,
                                completedBytes: completed,
                                totalBytes: total)
    }
}
