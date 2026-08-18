import AdbFinderCore
import AdbKit
import FileProvider
import Foundation

/// Keeps the set of registered File Provider domains in step with the set of
/// usable devices.
///
/// The domain identifier is the device serial, so a phone that is unplugged and
/// replugged reuses its metadata store instead of renumbering every file.
@MainActor
final class DomainController: ObservableObject {
    @Published private(set) var devices: [AdbDevice] = []
    @Published private(set) var serverReachable = false
    @Published private(set) var lastError: String?

    private let client = AdbClient()
    private var watcher: Task<Void, Never>?

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
                // A clean end of stream still means the server went away.
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
        let registered = (try? await NSFileProviderManager.domains()) ?? []

        for device in usable where !registered.contains(where: { $0.identifier.rawValue == device.serial }) {
            let domain = NSFileProviderDomain(identifier: .init(rawValue: device.serial),
                                              displayName: Self.displayName(for: device, among: usable))
            do {
                try await NSFileProviderManager.add(domain)
                Log.domain.info("added domain \(device.serial, privacy: .public)")
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

    /// Two phones of the same model would otherwise be indistinguishable in the
    /// sidebar, so only then is the serial appended.
    static func displayName(for device: AdbDevice, among all: [AdbDevice]) -> String {
        let base = device.displayName
        let duplicates = all.filter { $0.displayName == base }
        guard duplicates.count > 1 else { return base }
        return "\(base) (\(device.serial))"
    }

    /// Used on quit so a stale domain does not linger after the app is gone.
    static func removeAllDomains() async {
        let registered = (try? await NSFileProviderManager.domains()) ?? []
        for domain in registered { try? await NSFileProviderManager.remove(domain) }
    }
}
