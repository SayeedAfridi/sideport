import AppKit
import AdbFinderCore
import AdbKit
import FileProvider
import Foundation

/// Keeps the set of registered File Provider domains in step with the set of
/// usable devices.
///
/// The domain identifier is the device serial, so a phone that is unplugged and
/// replugged reuses its metadata store instead of renumbering every file. The
/// *display name* is separate and is what Finder shows in the sidebar.
/// What we can tell the user about one attached device.
struct DeviceStatus: Sendable, Equatable {
    var totalBytes: Int64?
    var freeBytes: Int64?
    var activity = TransferActivity()

    var capacityDescription: String? {
        guard let freeBytes, let totalBytes, totalBytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: freeBytes)) free of \(formatter.string(fromByteCount: totalBytes))"
    }
}

@MainActor
final class DomainController: ObservableObject {
    @Published private(set) var devices: [AdbDevice] = []
    @Published private(set) var statuses: [String: DeviceStatus] = [:]
    /// Nil until we have looked; empty string never — see `AdbServerController`.
    @Published private(set) var adbBinaryPath: String?
    @Published private(set) var serverReachable = false
    @Published private(set) var lastError: String?
    /// True when macOS has the extension switched off. Browsing still works in
    /// that state, but every write is rejected with
    /// `NSFileProviderErrorDomainDisabled`, so a mount that looks writable
    /// silently is not. Only the user can change this, in System Settings.
    @Published private(set) var needsUserEnable = false

    private let client = AdbClient()
    private let server = AdbServerController()
    private let preferences = Preferences()
    private var watcher: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    /// Resolved once per device: it costs a shell round trip and cannot change
    /// while the device stays plugged in.
    private var friendlyNames: [String: String] = [:]

    func start() {
        guard watcher == nil else { return }
        adbBinaryPath = server.binaryPath
        watcher = Task { await watch() }
        poller = Task { await pollActivity() }
    }

    func stop() {
        watcher?.cancel(); watcher = nil
        poller?.cancel(); poller = nil
    }

    /// Starts the shared adb server. Never a private one on a private port:
    /// Android Studio and the command line must keep working alongside us.
    func startAdbServer() async {
        guard await server.startServer() else { return }
        // The watch loop is sitting in its retry backoff; nudge it.
        stop()
        start()
    }

    func revealAdbBinary() { server.revealBinary() }

    /// Re-resolves display names and re-registers domains whose label changed.
    /// Used when the naming preference is switched.
    func refreshNames() {
        friendlyNames.removeAll()
        let snapshot = devices
        Task { await apply(snapshot) }
    }

    /// Transfer activity is written by the extension, so it can only be polled.
    /// A second is frequent enough for a menu nobody stares at.
    private func pollActivity() async {
        while !Task.isCancelled {
            for device in devices where device.state.isUsable {
                let activity = TransferReporter.read(serial: device.serial)
                if statuses[device.serial]?.activity != activity {
                    statuses[device.serial, default: DeviceStatus()].activity = activity
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Follows the adb server's own hot-plug stream, reconnecting if the server
    /// goes away — Android Studio or a Gradle build may run `adb kill-server`
    /// underneath us at any moment, and that is routine, not exceptional.
    private func watch() async {
        while !Task.isCancelled {
            do {
                for try await snapshot in client.deviceChanges() {
                    serverReachable = true
                    lastError = nil
                    await apply(snapshot)
                }
                serverReachable = false
            } catch {
                serverReachable = false
                lastError = (error as? AdbError)?.errorDescription ?? error.localizedDescription
                Log.domain.error("device stream failed: \(self.lastError ?? "", privacy: .public)")

                // A missing server is the ordinary case, not a failure: another
                // tool may have run `adb kill-server`, or nothing started one yet.
                if (error as? AdbError)?.isServerNotRunning == true,
                   preferences.startServerAutomatically {
                    _ = await server.startServer()
                }
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func apply(_ snapshot: [AdbDevice]) async {
        devices = snapshot
        let usable = snapshot.filter { $0.state.isUsable }

        // Resolve every name first so collisions can be judged against the
        // complete picture rather than whichever device was seen first.
        var resolved: [String: String] = [:]
        for device in usable {
            resolved[device.serial] = await friendlyName(for: device)
        }
        let occurrences = Dictionary(grouping: resolved.values, by: { $0 }).mapValues(\.count)

        let registered = (try? await NSFileProviderManager.domains()) ?? []

        for device in usable {
            let base = resolved[device.serial] ?? device.displayName
            // Only when two devices would be indistinguishable is the serial
            // appended — "POCO F7" beats "POCO F7 (d13ee35)" when it is unique.
            let label = (occurrences[base] ?? 0) > 1 ? "\(base) (\(device.serial))" : base

            let existing = registered.first { $0.identifier.rawValue == device.serial }
            // Adding again under the same identifier updates the domain in
            // place, which is how a corrected name reaches the sidebar without
            // tearing down the store.
            guard existing?.displayName != label else { continue }

            let domain = NSFileProviderDomain(identifier: .init(rawValue: device.serial),
                                              displayName: label)
            do {
                try await NSFileProviderManager.add(domain)
                Log.domain.info("registered \(device.serial, privacy: .public) as \(label, privacy: .public)")
            } catch {
                let ns = error as NSError
                Log.domain.error("could not add domain: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) — \(ns.localizedDescription, privacy: .public) | \(ns.userInfo.description, privacy: .public)")
                lastError = error.localizedDescription
            }
        }

        for domain in registered where !usable.contains(where: { $0.serial == domain.identifier.rawValue }) {
            try? await NSFileProviderManager.remove(domain)
            Log.domain.info("removed domain \(domain.identifier.rawValue, privacy: .public)")
        }

        statuses = statuses.filter { key, _ in usable.contains { $0.serial == key } }
        for device in usable { await refreshCapacity(for: device) }

        await checkUserEnabled()
    }

    /// Reads back whether macOS considers our domains switched on.
    private func checkUserEnabled() async {
        let current = (try? await NSFileProviderManager.domains()) ?? []
        let live = current.filter { domain in
            devices.contains { $0.serial == domain.identifier.rawValue && $0.state.isUsable }
        }
        guard !live.isEmpty else {
            needsUserEnable = false
            return
        }
        for domain in live {
            Log.domain.info("domain \(domain.identifier.rawValue, privacy: .public) userEnabled=\(domain.userEnabled, privacy: .public) disconnected=\(domain.isDisconnected, privacy: .public)")
        }
        needsUserEnable = live.contains { !$0.userEnabled }
    }

    /// Where Finder mounts a device, so the menu can open it directly.
    func revealInFinder(_ device: AdbDevice) {
        let name = (friendlyNames[device.serial] ?? device.displayName)
            .replacingOccurrences(of: " ", with: "")
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/FinderADB-\(name)")
        NSWorkspace.shared.open(url)
    }

    /// Opens the pane holding the File Providers switch.
    func openExtensionSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
            "x-apple.systempreferences:com.apple.preference.general",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Free and total space, refreshed when a device appears. It changes slowly
    /// enough that polling it would be noise.
    private func refreshCapacity(for device: AdbDevice) async {
        guard statuses[device.serial]?.totalBytes == nil else { return }
        guard let capacity = try? await client.capacity(at: FinderADB.defaultDeviceRoot,
                                                        on: .serial(device.serial)) else { return }
        statuses[device.serial, default: DeviceStatus()].totalBytes = capacity.total
        statuses[device.serial, default: DeviceStatus()].freeBytes = capacity.free
    }

    /// What the device calls itself, falling back to the model string that
    /// `devices-l` reports — which is often a bare part number.
    private func friendlyName(for device: AdbDevice) async -> String {
        if preferences.sidebarNaming == .model { return device.displayName }
        if let cached = friendlyNames[device.serial] { return cached }
        let resolved = (try? await client.deviceName(for: .serial(device.serial))) ?? nil
        let name = resolved ?? device.displayName
        friendlyNames[device.serial] = name
        return name
    }

    /// Used on quit so a stale domain does not linger after the app is gone.
    ///
    /// `.removeAll` matters: the plain removal preserves the user data, which
    /// means the system keeps its replica — and with it every cached item
    /// capability. A folder that has since become writable would still read as
    /// read-only, because Finder never asks us again.
    static func removeAllDomains(discardingReplica: Bool = true) async {
        let registered = (try? await NSFileProviderManager.domains()) ?? []
        for domain in registered {
            if discardingReplica {
                _ = try? await NSFileProviderManager.remove(domain, mode: .removeAll)
            } else {
                try? await NSFileProviderManager.remove(domain)
            }
            Log.domain.info("removed domain \(domain.identifier.rawValue, privacy: .public)")
        }
    }
}
