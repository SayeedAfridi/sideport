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
@MainActor
final class DomainController: ObservableObject {
    @Published private(set) var devices: [AdbDevice] = []
    @Published private(set) var serverReachable = false
    @Published private(set) var lastError: String?

    private let client = AdbClient()
    private var watcher: Task<Void, Never>?
    /// Resolved once per device: it costs a shell round trip and cannot change
    /// while the device stays plugged in.
    private var friendlyNames: [String: String] = [:]

    func start() {
        guard watcher == nil else { return }
        watcher = Task { await watch() }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
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
                Log.domain.error("could not add domain: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
            }
        }

        for domain in registered where !usable.contains(where: { $0.serial == domain.identifier.rawValue }) {
            try? await NSFileProviderManager.remove(domain)
            Log.domain.info("removed domain \(domain.identifier.rawValue, privacy: .public)")
        }
    }

    /// What the device calls itself, falling back to the model string that
    /// `devices-l` reports — which is often a bare part number.
    private func friendlyName(for device: AdbDevice) async -> String {
        if let cached = friendlyNames[device.serial] { return cached }
        let resolved = (try? await client.deviceName(for: .serial(device.serial))) ?? nil
        let name = resolved ?? device.displayName
        friendlyNames[device.serial] = name
        return name
    }

    /// Used on quit so a stale domain does not linger after the app is gone.
    static func removeAllDomains() async {
        let registered = (try? await NSFileProviderManager.domains()) ?? []
        for domain in registered { try? await NSFileProviderManager.remove(domain) }
    }
}
