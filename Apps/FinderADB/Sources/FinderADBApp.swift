import AdbFinderCore
import AdbKit
import SwiftUI

@main
struct FinderADBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            Image(systemName: "iphone.gen3")
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
        Log.domain.info("FinderADB launched")
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Leaving a domain behind would show a device in Finder that nothing is
        // backing any more.
        controller.stop()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await DomainController.removeAllDomains()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
    }
}

struct MenuContent: View {
    @ObservedObject var controller: DomainController

    var body: some View {
        if controller.needsUserEnable {
            // Worth shouting about: without this the device mounts and browses
            // normally, and every write fails.
            Text("Turn on “Finder ADB” in System Settings")
            Text("File writing is disabled until then.").font(.caption)
            Button("Open Login Items & Extensions…") { controller.openExtensionSettings() }
            Divider()
        }

        if !controller.serverReachable {
            Text("adb server unreachable")
            if let error = controller.lastError {
                Text(error).font(.caption)
            }
        } else if controller.devices.isEmpty {
            Text("No devices connected")
        } else {
            ForEach(controller.devices, id: \.serial) { device in
                Text(label(for: device))
            }
        }

        Divider()
        Button("Quit Finder ADB") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// The unusable states are the ones needing explanation — an unauthorized
    /// device looks identical to a working one from the outside.
    private func label(for device: AdbDevice) -> String {
        switch device.state {
        case .device: return device.displayName
        case .unauthorized: return "\(device.displayName) — check the USB debugging prompt"
        default: return "\(device.displayName) — \(device.state.rawValue)"
        }
    }
}
