import AdbFinderCore
import AdbKit
import FileProvider

/// The Finder-facing surface. Deliberately thin: it translates File Provider
/// calls into `DeviceSession` work and maps errors back. Anything resembling
/// logic belongs in `AdbFinderCore`, where it can be tested without a domain
/// registered and without Finder in the loop.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let session: DeviceSession

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.session = DeviceSession(domain: domain)
        super.init()
        Log.domain.info("extension started for \(domain.identifier.rawValue, privacy: .public)")
    }

    func invalidate() {
        Log.domain.info("extension invalidated for \(self.domain.identifier.rawValue, privacy: .public)")
    }

    // MARK: - Reads

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task { [session] in
            do {
                guard let id = identifier.itemID else { throw CoreError.itemNotFound(0) }
                let (stored, version) = try await session.itemAndVersion(id)
                completionHandler(ProviderItem(stored, version: version, rootFilename: session.rootFilename), nil)
            } catch {
                completionHandler(nil, ProviderError.map(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard containerItemIdentifier != .workingSet,
              containerItemIdentifier != .trashContainer else {
            return EmptyEnumerator()
        }
        guard let id = containerItemIdentifier.itemID else {
            throw NSFileProviderError(.noSuchItem)
        }
        return DirectoryEnumerator(session: session, container: id)
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task { [session, domain] in
            do {
                guard let id = itemIdentifier.itemID else { throw CoreError.itemNotFound(0) }
                let (stored, version) = try await session.itemAndVersion(id)

                // A replicated provider materialises whole files — opening a
                // 6 GB archive downloads 6 GB. Honest progress and a working
                // cancel are the only mitigations this API allows.
                progress.totalUnitCount = max(stored.size, 1)
                let destination = Self.temporaryURL(for: domain, name: stored.name)

                try await session.pull(id, to: destination) { transferred in
                    guard !progress.isCancelled else { throw CancellationError() }
                    progress.completedUnitCount = min(transferred, progress.totalUnitCount)
                }

                completionHandler(destination,
                                  ProviderItem(stored, version: version, rootFilename: session.rootFilename),
                                  nil)
            } catch is CancellationError {
                completionHandler(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                Log.fetch.error("fetch failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, nil, ProviderError.map(error))
            }
        }
        return progress
    }

    // MARK: - Writes (M3)
    //
    // Item capabilities advertise read-only, so Finder should not reach these.
    // They exist because the protocol requires them, and they fail loudly rather
    // than silently doing nothing.

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, Self.notYetImplemented)
        return Progress(totalUnitCount: 0)
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, Self.notYetImplemented)
        return Progress(totalUnitCount: 0)
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(Self.notYetImplemented)
        return Progress(totalUnitCount: 0)
    }

    // MARK: - Helpers

    private static var notYetImplemented: Error {
        NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [
            NSLocalizedDescriptionKey: "Writing to the device is not supported yet."
        ])
    }

    private static func temporaryURL(for domain: NSFileProviderDomain, name: String) -> URL {
        let directory = (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL())
            .flatMap { $0 } ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}
