import Foundation

/// Little-endian scalar helpers. The adb sync protocol is little-endian on the
/// wire regardless of host or device architecture.
enum ByteCodec {
    static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF),
         UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF),
         UInt8((value >> 24) & 0xFF)]
    }

    static func readU32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    static func readU64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in (0..<8).reversed() {
            value = value << 8 | UInt64(bytes[offset + i])
        }
        return value
    }

    static func readI64(_ bytes: [UInt8], at offset: Int) -> Int64 {
        Int64(bitPattern: readU64(bytes, at: offset))
    }

    /// A 4-byte sync packet id such as `DENT`, `DATA`, `DONE`, `FAIL`.
    static func id(_ text: String) -> [UInt8] { Array(text.utf8) }
}
