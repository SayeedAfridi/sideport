import Foundation
import Testing
@testable import AdbKit

// The strings in this file were read off a real device (toybox on Android 15)
// and off `adbd`'s sync service, not copied out of a header. That is the point:
// the mapping is only as good as the text it was built against, so the fixtures
// have to be the genuine article.

@Suite("Device errno recovery")
struct DeviceErrnoTests {
    @Test func recognisesToyboxStderr() {
        // Captured verbatim; note that each applet quotes the path differently,
        // which is exactly why matching is by containment and not by shape.
        let cases: [(String, Int32)] = [
            ("mkdir: '/system/nope': Read-only file system", EROFS),
            ("mkdir: '/storage/emulated/0/Download': File exists", EEXIST),
            ("rm: /storage/emulated/0/nope: No such file or directory", ENOENT),
            ("rmdir: /storage/emulated/0/Download: Directory not empty", ENOTEMPTY),
            ("cat: /data/data: Permission denied", EACCES),
            ("touch: '/sdcard/nope/file': No such file or directory", ENOENT)
        ]
        for (message, expected) in cases {
            #expect(DeviceErrno.inferred(from: message) == expected, "\(message)")
        }
    }

    @Test func recognisesSyncServiceFailures() {
        // adbd prefixes its own context before the strerror text.
        #expect(DeviceErrno.inferred(from: "couldn't create file: Read-only file system") == EROFS)
        #expect(DeviceErrno.inferred(from: "couldn't create file: Permission denied") == EACCES)
        #expect(DeviceErrno.inferred(from: "open failed: No such file or directory") == ENOENT)
        #expect(DeviceErrno.inferred(from: "failed to copy: No space left on device") == ENOSPC)
    }

    @Test func prefersTheLongerMatchWhenOneContainsAnother() {
        // "No such file or directory" also contains the word "directory"; a
        // shorter entry must not shadow it.
        #expect(DeviceErrno.inferred(from: "ls: /x: No such file or directory") == ENOENT)
        #expect(DeviceErrno.inferred(from: "cp: /x: Not a directory") == ENOTDIR)
        #expect(DeviceErrno.inferred(from: "cat: /x: Is a directory") == EISDIR)
    }

    @Test func returnsNilRatherThanGuessing() {
        #expect(DeviceErrno.inferred(from: "") == nil)
        #expect(DeviceErrno.inferred(from: "something went wrong") == nil)
        #expect(DeviceErrno.inferred(from: "closed") == nil)
    }

    @Test func isCaseInsensitive() {
        #expect(DeviceErrno.inferred(from: "PERMISSION DENIED") == EACCES)
    }

    @Test func separatesTransientFromPermanent() {
        #expect(DeviceErrno.isTransient(ETIMEDOUT))
        #expect(DeviceErrno.isTransient(ECONNRESET))
        #expect(DeviceErrno.isTransient(EBUSY))
        // A full disk and a denied permission both stay failed until someone
        // does something about them.
        #expect(!DeviceErrno.isTransient(ENOSPC))
        #expect(!DeviceErrno.isTransient(EACCES))
        #expect(!DeviceErrno.isTransient(ENOENT))
        #expect(!DeviceErrno.isTransient(EROFS))
    }
}

@Suite("AdbError classification")
struct AdbErrorClassificationTests {
    @Test func syncFailureCarriesItsErrno() {
        let error = AdbError.syncFailed("couldn't create file: No space left on device")
        #expect(error.posixCode == ENOSPC)
        #expect(!error.isTransient)
    }

    @Test func commandFailureReadsStderr() {
        let error = AdbError.commandFailed(command: "mkdir '/x'", exitCode: 1,
                                           stderr: "mkdir: '/x': Permission denied\n")
        #expect(error.posixCode == EACCES)
        #expect(!error.isTransient)
    }

    @Test func localFailureKeepsTheCodeItWasGiven() {
        let error = AdbError.localIOFailure(ENOSPC, "write")
        #expect(error.posixCode == ENOSPC)
        // The rendered message must still read like the platform's own.
        #expect(error.localizedDescription.contains("No space left on device"))
    }

    @Test func transportFaultsAreTransient() {
        #expect(AdbError.unexpectedEOF.isTransient)
        #expect(AdbError.socket("reset").isTransient)
        #expect(AdbError.serverUnreachable("nope").isTransient)
        // A desynced stream is cured by a fresh one, which the next attempt opens.
        #expect(AdbError.protocolViolation("bad packet").isTransient)
        // A path we rejected ourselves will be rejected identically next time.
        #expect(!AdbError.invalidPath("").isTransient)
    }

    @Test func unrecognisedTextYieldsNoCode() {
        #expect(AdbError.syncFailed("closed").posixCode == nil)
        #expect(!AdbError.syncFailed("closed").isTransient)
    }
}
