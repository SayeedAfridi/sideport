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

    /// Async cleanup on quit, done the way AppKit actually supports it.
    ///
    /// The obvious version — spawn a `Task` in `applicationWillTerminate` and
    /// block on a semaphore until it finishes — cannot work here and fails
    /// silently. `applicationWillTerminate` runs on the main actor, an
    /// unstructured `Task` inherits that isolation, and the semaphore is
    /// holding the main actor hostage: the task cannot start until the wait
    /// ends, and the wait cannot end until the task runs. Making
    /// `removeAllDomains` `nonisolated` is not enough, because it is the task's
    /// own body that is isolated, not just the function it calls.
    ///
    /// The visible consequence was every device staying in the Finder sidebar
    /// after quitting, backed by nothing.
    ///
    /// `.terminateLater` is the supported answer: AppKit keeps the app alive,
    /// off the main thread, until we say otherwise.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.stop()

        Task {
            // A device that stopped answering must not be able to prevent the
            // app from quitting, so the reply is on a timer too.
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                Log.domain.error("domain cleanup timed out; quitting anyway")
                NSApp.reply(toApplicationShouldTerminate: true)
            }

            await DomainController.removeAllDomains(discardingReplica: false)
            watchdog.cancel()
            Log.domain.info("domains removed; quitting")
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
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
            let labels = controller.labels(for: device)
            Button(labels.name) { controller.revealInFinder(device) }
            // Model and capacity share a line: three rows per device turns a
            // menu into a table.
            Text([labels.model, status?.capacityDescription]
                .compactMap { $0 }
                .joined(separator: " · "))
            if status?.activity.isBusy == true {
                Text("Transferring…")
            }
        case .unauthorized:
            Text("\(controller.labels(for: device).name) — unauthorized")
            Text("Accept the USB debugging prompt on the device.")
        case .offline:
            Text("\(controller.labels(for: device).name) — offline")
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

        // Governs the Finder sidebar only; the menu above always shows both.
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
