import AdbFinderCore
import AdbKit
import FileProvider
import Foundation

/// Serves byte ranges instead of whole files.
///
/// Without this, opening a file means downloading all of it: a replicated
/// provider materialises or nothing. That is the difference between 76 ms and
/// 218 seconds for a reader that only wants the last 64 KB of a 7 GB archive —
/// which is exactly what Finder's preview, Archive Utility, and anything else
/// reading a container format does first.
///
/// The trade is real and worth stating: ranged reads go through `dd` over the
/// shell at about half `RECV`'s throughput, plus a fixed ~75 ms per call. So
/// this is a latency win, not a bandwidth one, and whole-file reads still go
/// through `fetchContents`. The system chooses.
extension FileProviderExtension: NSFileProviderPartialContentFetching {
    func fetchPartialContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion,
        request: NSFileProviderRequest,
        minimalRange: NSRange,
        aligningTo alignment: Int,
        options: NSFileProviderFetchContentsOptions = [],
        completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange,
                                      NSFileProviderMaterializationFlags, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task { [session, domain] in
            do {
                guard let id = itemIdentifier.itemID else { throw CoreError.itemNotFound(0) }
                let (stored, version) = try await session.itemAndVersion(id)

                let decision = await session.planPartialFetch(id,
                                                              wanted: minimalRange,
                                                              alignment: alignment,
                                                              fileSize: stored.size)

                let destination = Self.temporaryURL(for: domain, name: stored.name)
                let filledRange: NSRange

                switch decision {
                case .wholeFile:
                    // The faster transport, and the honest answer for a reader
                    // that is streaming rather than sampling.
                    progress.totalUnitCount = max(stored.size, 1)
                    try await session.pull(id, to: destination) { transferred in
                        guard !progress.isCancelled else { throw CancellationError() }
                        progress.completedUnitCount = min(transferred, progress.totalUnitCount)
                    }
                    // <0, file size> is how the API spells "fully materialised".
                    filledRange = NSRange(location: 0, length: Int(clamping: stored.size))

                case .range(let range):
                    guard range.length > 0 else {
                        completionHandler(nil, nil, NSRange(location: 0, length: 0), [],
                                          NSFileProviderError(.noSuchItem))
                        return
                    }
                    let data = try await session.readRange(id,
                                                           offset: Int64(range.location),
                                                           length: range.length)
                    guard !progress.isCancelled else { throw CancellationError() }
                    try Self.write(data, at: range.location, to: destination)
                    filledRange = NSRange(location: range.location, length: data.count)
                }

                // Report what we actually got, not what we asked for: a short
                // read at end of file is normal, and claiming the requested
                // length would hand the system bytes that do not exist.
                Log.fetch.debug("""
                    partial \(stored.name, privacy: .public): \
                    asked \(minimalRange.location, privacy: .public)+\
                    \(minimalRange.length, privacy: .public), \
                    served \(filledRange.location, privacy: .public)+\
                    \(filledRange.length, privacy: .public)
                    """)

                completionHandler(destination,
                                  ProviderItem(stored, version: version,
                                               rootFilename: session.rootFilename),
                                  filledRange, [], nil)
            } catch is CancellationError {
                completionHandler(nil, nil, NSRange(location: 0, length: 0), [],
                                  NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                Log.fetch.error("partial fetch failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, nil, NSRange(location: 0, length: 0), [],
                                  ProviderError.map(error))
            }
            progress.completedUnitCount = 1
        }

        return progress
    }

    /// Writes a fetched range at the offset it actually occupies in the file.
    ///
    /// Not at offset zero, which is the obvious reading and the wrong one: the
    /// system reads the returned file at the *same* offset the range claims, so
    /// bytes written at the start are silently taken as the file's first bytes.
    /// Getting this wrong looks like success for any range starting at zero and
    /// fails for every other one — a read of the first megabyte returned exactly
    /// 512 KB and then stopped, which is how it was caught.
    ///
    /// The gap before the range is a hole; APFS stores it sparsely, so a range
    /// at 6 GB does not cost 6 GB of disk.
    private static func write(_ data: Data, at offset: Int, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw AdbError.localIOFailure(errno, "cannot create \(destination.path)")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }
}
