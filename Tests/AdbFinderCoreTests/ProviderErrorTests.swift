import AdbKit
import FileProvider
import Foundation
import Testing
@testable import AdbFinderCore

// The File Provider API reads the error code as an instruction, so these tests
// are about consequences, not labels: `.noSuchItem` tells the system to drop the
// item from the replica, and answering that to a failed upload throws away the
// file the user was copying.

@Suite("Error mapping")
struct ProviderErrorTests {
    private func code(_ error: Error) -> (domain: String, code: Int) {
        let ns = error as NSError
        return (ns.domain, ns.code)
    }

    private func isProvider(_ error: Error, _ expected: NSFileProviderError.Code) -> Bool {
        let ns = error as NSError
        return ns.domain == NSFileProviderErrorDomain && ns.code == expected.rawValue
    }

    private func isPosix(_ error: Error, _ expected: Int32) -> Bool {
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain && ns.code == Int(expected)
    }

    @Test func aFullPhoneIsNotAMissingFile() {
        // The bug this guards: ENOSPC mapped to `.noSuchItem` makes the system
        // conclude the upload's destination vanished and discard the file.
        let error = ProviderError.map(AdbError.syncFailed("couldn't create file: No space left on device"))
        #expect(isProvider(error, .insufficientQuota))
    }

    @Test func aDeniedWriteIsNotAMissingFile() {
        let error = ProviderError.map(AdbError.syncFailed("couldn't create file: Permission denied"))
        #expect(isPosix(error, EACCES))
    }

    @Test func onlyARealAbsenceBecomesNoSuchItem() {
        #expect(isProvider(ProviderError.map(AdbError.syncFailed("open failed: No such file or directory")),
                           .noSuchItem))
        #expect(isProvider(ProviderError.map(CoreError.itemNotFound(42)), .noSuchItem))
    }

    @Test func transportFaultsAskForARetry() {
        for error in [AdbError.unexpectedEOF,
                      .socket("reset by peer"),
                      .serverUnreachable("connection refused"),
                      .protocolViolation("short packet"),
                      .deviceNotFound("nothing connected")] {
            #expect(isProvider(ProviderError.map(error), .serverUnreachable), "\(error)")
        }
    }

    @Test func aTransientErrnoAlsoAsksForARetry() {
        let error = ProviderError.map(AdbError.localIOFailure(ETIMEDOUT, "read"))
        #expect(isProvider(error, .serverUnreachable))
    }

    @Test func anUnauthorizedDeviceNeedsTheUserNotARetry() {
        // Retrying cannot press the USB-debugging dialog on the phone.
        let error = ProviderError.map(AdbError.deviceUnavailable(serial: "d13ee35", state: "unauthorized"))
        #expect(isProvider(error, .notAuthenticated))
        // Every other stuck state is worth another attempt: the phone may still
        // be booting, or the transport may be mid-handshake.
        let offline = ProviderError.map(AdbError.deviceUnavailable(serial: "d13ee35", state: "offline"))
        #expect(isProvider(offline, .serverUnreachable))
    }

    @Test func anchorExpiryAsksForAFullRescan() {
        #expect(isProvider(ProviderError.map(CoreError.anchorExpired), .syncAnchorExpired))
    }

    /// Unreadable storage is the device, not the file — and the path that fails
    /// is the *root*, so `.noSuchItem` here would be an instruction to drop the
    /// entire phone from the replica. It also clears on its own once the device
    /// finishes mounting, which is exactly what `.serverUnreachable` is for.
    @Test func unmountedStorageIsHeldAndRetriedNotDeclaredMissing() {
        let error = ProviderError.map(CoreError.storageUnavailable("/storage/self/primary"))
        #expect(isProvider(error, .serverUnreachable))
        #expect(!isProvider(error, .noSuchItem))
    }

    @Test func unrecognisedFailuresAreSurfacedNotGuessedAt() {
        let error = ProviderError.map(AdbError.syncFailed("closed"))
        #expect(isProvider(error, .cannotSynchronize))
    }

    @Test func theOriginalErrorSurvivesTheTranslation() {
        // Without this the log a week later says only "code -1005", which is the
        // same message for six unrelated causes.
        let original = AdbError.socket("reset by peer")
        let ns = ProviderError.map(original) as NSError
        #expect(ns.userInfo[NSUnderlyingErrorKey] != nil)
        #expect(ns.localizedDescription.contains("reset by peer"))
    }

    @Test func cancellationStaysCancellation() {
        let mapped = code(ProviderError.map(CancellationError()))
        #expect(mapped.domain == NSCocoaErrorDomain)
        #expect(mapped.code == NSUserCancelledError)
        // And it survives a second trip through, which is what happens when a
        // cancelled transfer's error is re-mapped by an outer handler.
        let again = code(ProviderError.map(ProviderError.map(CancellationError())))
        #expect(again.code == NSUserCancelledError)
    }

    @Test func mappingIsIdempotent() {
        // Errors pass through more than one layer; a second mapping must not
        // turn `.serverUnreachable` into `.cannotSynchronize`.
        let once = ProviderError.map(AdbError.unexpectedEOF)
        #expect(isProvider(ProviderError.map(once), .serverUnreachable))
    }

    @Test func deleteOfSomethingAlreadyGoneCountsAsDone() {
        #expect(ProviderError.isAlreadyGone(CoreError.itemNotFound(7)))
        #expect(ProviderError.isAlreadyGone(AdbError.syncFailed("open failed: No such file or directory")))
        #expect(ProviderError.isAlreadyGone(ProviderError.map(CoreError.itemNotFound(7))))
        // A denial is not an absence: the file is still there and still ours to
        // report on.
        #expect(!ProviderError.isAlreadyGone(AdbError.syncFailed("couldn't create file: Permission denied")))
        #expect(!ProviderError.isAlreadyGone(AdbError.unexpectedEOF))
    }
}
