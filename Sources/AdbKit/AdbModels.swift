import Foundation

/// A device as reported by `host:devices-l`.
public struct AdbDevice: Sendable, Hashable, Identifiable {
    public enum State: String, Sendable, Hashable {
        case device, offline, unauthorized, bootloader, recovery, sideload
        case host, rescue, connecting, authorizing, detached
        case unknown

        /// Only `.device` can serve file operations.
        public var isUsable: Bool { self == .device }
    }

    public let serial: String
    public let state: State
    public let product: String?
    public let model: String?
    public let device: String?
    public let transportId: String?

    public var id: String { serial }

    /// What a human should see in the Finder sidebar.
    public var displayName: String {
        if let model, !model.isEmpty {
            return model.replacingOccurrences(of: "_", with: " ")
        }
        return serial
    }

    public init(serial: String, state: State, product: String? = nil,
                model: String? = nil, device: String? = nil, transportId: String? = nil) {
        self.serial = serial
        self.state = state
        self.product = product
        self.model = model
        self.device = device
        self.transportId = transportId
    }

    /// Parses one line of `adb devices -l` output.
    static func parse(line: String) -> AdbDevice? {
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2 else { return nil }
        var attributes: [String: String] = [:]
        for field in fields.dropFirst(2) {
            let parts = field.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { attributes[String(parts[0])] = String(parts[1]) }
        }
        // Reject anything whose state is not one adb actually emits: it keeps
        // stray text (banners, error lines) from materialising as a "device".
        guard let state = State(rawValue: fields[1]) else { return nil }
        return AdbDevice(serial: fields[0],
                         state: state,
                         product: attributes["product"],
                         model: attributes["model"],
                         device: attributes["device"],
                         transportId: attributes["transport_id"])
    }
}

/// A file or directory on the device.
public struct AdbFileEntry: Sendable, Hashable {
    public let name: String
    public let mode: UInt32
    public let size: Int64
    public let modified: Date
    /// Device and inode numbers, present only on `ls_v2`/`stat_v2` devices.
    ///
    /// These are a *hint* for detecting that a file moved rather than being
    /// deleted and recreated. They are deliberately never used as identity:
    /// `/storage/emulated/0` is a FUSE mount and inode stability across
    /// remounts is not contractual.
    public let dev: UInt64?
    public let ino: UInt64?

    public init(name: String, mode: UInt32, size: Int64, modified: Date,
                dev: UInt64? = nil, ino: UInt64? = nil) {
        self.name = name
        self.mode = mode
        self.size = size
        self.modified = modified
        self.dev = dev
        self.ino = ino
    }

    private static let formatMask: UInt32 = 0o170000

    public var isDirectory: Bool { mode & Self.formatMask == 0o040000 }
    public var isRegularFile: Bool { mode & Self.formatMask == 0o100000 }
    public var isSymlink: Bool { mode & Self.formatMask == 0o120000 }
    /// `true` when the entry does not exist (adb reports mode 0).
    public var exists: Bool { mode != 0 }
    public var posixPermissions: UInt16 { UInt16(mode & 0o7777) }
    /// Dotfiles are hidden on Android just as they are on macOS.
    public var isHidden: Bool { name.hasPrefix(".") }
}

/// Feature flags advertised by the device+server pair, from `host:features`.
public struct AdbFeatures: Sendable, Hashable {
    public let raw: Set<String>

    public init(raw: Set<String>) { self.raw = raw }

    public func has(_ feature: String) -> Bool { raw.contains(feature) }

    /// 64-bit sizes and times in directory listings.
    public var listV2: Bool { has("ls_v2") }
    /// 64-bit `stat` with a real errno field.
    public var statV2: Bool { has("stat_v2") }
    /// Shell protocol with separated stderr and a real exit code.
    public var shellV2: Bool { has("shell_v2") }
}
