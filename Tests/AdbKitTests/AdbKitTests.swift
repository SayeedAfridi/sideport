import Foundation
import Testing
@testable import AdbKit

// Pure-logic tests only: anything requiring a device lives in `adbctl selftest`.

@Suite("Device list parsing")
struct DeviceParsingTests {
    @Test func parsesLongFormat() {
        let line = "d13ee35                device usb:0-1 product:onyx_in model:25053PC47I device:onyx transport_id:56"
        let device = AdbDevice.parse(line: line)
        #expect(device?.serial == "d13ee35")
        #expect(device?.state == .device)
        #expect(device?.model == "25053PC47I")
        #expect(device?.device == "onyx")
        #expect(device?.transportId == "56")
    }

    @Test func parsesShortFormat() {
        let device = AdbDevice.parse(line: "emulator-5554\toffline")
        #expect(device?.serial == "emulator-5554")
        #expect(device?.state == .offline)
        #expect(device?.model == nil)
    }

    @Test func rejectsGarbage() {
        #expect(AdbDevice.parse(line: "List of devices attached") == nil)
        #expect(AdbDevice.parse(line: "") == nil)
    }

    @Test func rejectsUnrecognisedStates() {
        #expect(AdbDevice.parse(line: "abc123 some-future-state") == nil)
        // `unknown` is itself a state adb emits, so it must still parse.
        #expect(AdbDevice.parse(line: "abc123 unknown")?.state == .unknown)
    }

    @Test func displayNamePrefersModel() {
        let named = AdbDevice(serial: "x", state: .device, model: "Pixel_8_Pro")
        #expect(named.displayName == "Pixel 8 Pro")
        #expect(AdbDevice(serial: "x", state: .device).displayName == "x")
    }
}

@Suite("File entry mode decoding")
struct FileEntryTests {
    @Test func classifiesByModeBits() {
        let directory = AdbFileEntry(name: "DCIM", mode: 0o040771, size: 0, modified: .now)
        #expect(directory.isDirectory)
        #expect(!directory.isRegularFile)
        #expect(directory.posixPermissions == 0o771)

        let file = AdbFileEntry(name: "a.jpg", mode: 0o100660, size: 12, modified: .now)
        #expect(file.isRegularFile)
        #expect(!file.isDirectory)

        let link = AdbFileEntry(name: "sdcard", mode: 0o120777, size: 21, modified: .now)
        #expect(link.isSymlink)
        #expect(!link.isDirectory)
    }

    @Test func zeroModeMeansMissing() {
        #expect(!AdbFileEntry(name: "gone", mode: 0, size: 0, modified: .now).exists)
    }

    @Test func dotfilesAreHidden() {
        #expect(AdbFileEntry(name: ".nomedia", mode: 0o100644, size: 0, modified: .now).isHidden)
    }
}

@Suite("Shell quoting")
struct QuotingTests {
    @Test func wrapsPlainArguments() {
        #expect(adbShellQuote("/sdcard/DCIM") == "'/sdcard/DCIM'")
    }

    @Test func neutralisesShellMetacharacters() {
        // The failure mode this guards against is a filename that ends a
        // command and starts a second one.
        let quoted = adbShellQuote("a; rm -rf /")
        #expect(quoted == "'a; rm -rf /'")
    }

    @Test func escapesEmbeddedSingleQuotes() {
        #expect(adbShellQuote("it's") == #"'it'\''s'"#)
    }

    @Test func handlesSpacesAndUnicode() {
        #expect(adbShellQuote("名前 file.txt") == "'名前 file.txt'")
    }
}

@Suite("Little-endian codec")
struct ByteCodecTests {
    @Test func roundTripsU32() {
        let bytes = ByteCodec.u32(0xDEADBEEF)
        #expect(bytes == [0xEF, 0xBE, 0xAD, 0xDE])
        #expect(ByteCodec.readU32(bytes, at: 0) == 0xDEADBEEF)
    }

    @Test func readsU64AtOffset() {
        let bytes: [UInt8] = [0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        #expect(ByteCodec.readU64(bytes, at: 2) == UInt64.max)
    }

    @Test func readsNegativeI64() {
        let bytes = [UInt8](repeating: 0xFF, count: 8)
        #expect(ByteCodec.readI64(bytes, at: 0) == -1)
    }

    @Test func sizesOverFourGigabytesSurvive() {
        // The whole reason LIS2/STA2 exist instead of the v1 packets.
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[4] = 0x02  // 8 GiB
        #expect(ByteCodec.readU64(bytes, at: 0) == 8_589_934_592)
    }
}

@Suite("Device selectors")
struct SelectorTests {
    @Test func buildsTransportRequests() {
        #expect(DeviceSelector.serial("abc").transportRequest == "host:transport:abc")
        #expect(DeviceSelector.only.transportRequest == "host:transport-any")
    }

    @Test func buildsHostPrefixes() {
        #expect(DeviceSelector.serial("abc").hostPrefix == "host-serial:abc:")
        #expect(DeviceSelector.only.hostPrefix == "host:")
    }
}
