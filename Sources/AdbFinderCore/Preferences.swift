import Foundation

/// Settings shared between the app and the extension.
///
/// Backed by the App Group suite rather than standard defaults, because the
/// extension is sandboxed into its own container and would otherwise read an
/// entirely different (empty) store.
// `UserDefaults` is thread-safe in practice but not marked `Sendable`; the
// unchecked conformance is the accurate description rather than a workaround.
public struct Preferences: @unchecked Sendable {
    public enum SidebarNaming: String, Sendable, CaseIterable {
        /// What the owner called the device — "POCO F7".
        case deviceName
        /// The model string adb reports — "25053PC47I".
        case model

        public var label: String {
            switch self {
            case .deviceName: return "Device name"
            case .model: return "Model number"
            }
        }
    }

    private let defaults: UserDefaults

    public init() {
        // Falling back to `.standard` keeps the app usable if the entitlement is
        // missing; it just will not agree with the extension.
        defaults = UserDefaults(suiteName: FinderADB.appGroup) ?? .standard
    }

    private enum Key {
        static let sidebarNaming = "sidebarNaming"
        static let startServerAutomatically = "startServerAutomatically"
    }

    public var sidebarNaming: SidebarNaming {
        get { SidebarNaming(rawValue: defaults.string(forKey: Key.sidebarNaming) ?? "") ?? .deviceName }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.sidebarNaming) }
    }

    /// Whether to start the adb server ourselves when it is not running.
    public var startServerAutomatically: Bool {
        get { defaults.object(forKey: Key.startServerAutomatically) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.startServerAutomatically) }
    }
}
