import AdbFinderCore
import AdbKit
import ServiceManagement
import SwiftUI

@main
struct FinderADBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            Image(systemName: delegate.controller.devices.contains { $0.state.isUsable }
                  ? "iphone.gen3"
                  : "iphone.gen3.slash")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Device watching must begin at launch, not when someone opens the menu.
///
/// `MenuBarExtra` builds its content lazily, so anything started from the menu's
/// `onAppear` does not run until the icon is first clicked — which meant no
/// domain was ever registered until a person went looking for one.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let controller = DomainController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.domain.info("launched with args: \(CommandLine.arguments.joined(separator: " "), privacy: .public)")

        // Removing a domain through the API is the only way to make the system
        // discard its replica. Deleting cached state on disk leaves the replica
        // intact, so stale item capabilities survive and Finder keeps believing
        // a writable folder is read-only.
        if CommandLine.arguments.contains("--purge-domains") {
            Task {
                await DomainController.removeAllDomains()
                Log.domain.info("purged all domains")
                NSApplication.shared.terminate(nil)
            }
            return
        }

        Log.domain.info("FinderADB launched")
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Leaving a domain behind would show a device in Finder that nothing is
        // backing any more.
        controller.stop()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await DomainController.removeAllDomains(discardingReplica: false)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
    }
}

struct MenuContent: View {
    @ObservedObject var controller: DomainController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let preferences = Preferences()

    var body: some View {
        blockingProblems
        deviceSection
        Divider()
        serverSection
        Divider()
        settingsSection
        Divider()
        Button("Quit Finder ADB") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Things that make the app silently useless, surfaced first because none of
    /// them explain themselves.
    @ViewBuilder
    private var blockingProblems: some View {
        if controller.needsUserEnable {
            // Without this the device mounts and browses normally and every
            // write fails — a volume that looks writable and is not.
            Text("Turn on “Finder ADB” in System Settings")
            Text("Writing to the device is disabled until then.")
            Button("Open Login Items & Extensions…") { controller.openExtensionSettings() }
            Divider()
        }
    }

    @ViewBuilder
    private var deviceSection: some View {
        if !controller.serverReachable {
            Text("adb server not running")
        } else if controller.devices.isEmpty {
            Text("No devices connected")
            Text("Connect over USB with debugging enabled.")
        } else {
            ForEach(controller.devices, id: \.serial) { device in
                deviceRows(for: device)
            }
        }
    }

    @ViewBuilder
    private func deviceRows(for device: AdbDevice) -> some View {
        switch device.state {
        case .device:
            let status = controller.statuses[device.serial]
            Button(device.displayName) { controller.revealInFinder(device) }
            if let capacity = status?.capacityDescription {
                Text(capacity)
            }
            if status?.activity.isBusy == true {
                Text("Transferring…")
            }
        case .unauthorized:
            Text("\(device.displayName) — unauthorized")
            Text("Accept the USB debugging prompt on the device.")
        case .offline:
            Text("\(device.displayName) — offline")
            Text("Reconnect the cable, or unlock the device.")
        default:
            Text("\(device.displayName) — \(device.state.rawValue)")
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        if controller.serverReachable {
            Text("adb server: running")
        } else if controller.adbBinaryPath != nil {
            Button("Start adb server") {
                Task { await controller.startAdbServer() }
            }
        } else {
            // Nothing we can do for them beyond saying so plainly.
            Text("adb not found")
            Text("Install Android platform-tools, then reopen this menu.")
        }

        if let path = controller.adbBinaryPath {
            Button("Reveal adb in Finder") { controller.revealAdbBinary() }
                .help(path)
        }
    }

    @ViewBuilder
    private var settingsSection: some View {
        Toggle("Launch at Login", isOn: Binding(
            get: { launchAtLogin },
            set: { newValue in
                launchAtLogin = newValue
                do {
                    try newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                } catch {
                    // Registration can be refused; reflect reality rather than
                    // leaving the switch lying.
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                    Log.domain.error("login item change failed: \(error.localizedDescription, privacy: .public)")
                }
            }))

        Menu("Sidebar Name") {
            ForEach(Preferences.SidebarNaming.allCases, id: \.self) { option in
                Button {
                    preferences.sidebarNaming = option
                    controller.refreshNames()
                } label: {
                    // A checkmark is the only affordance a plain menu gives us.
                    Text(preferences.sidebarNaming == option ? "✓ \(option.label)" : option.label)
                }
            }
        }
    }
}
