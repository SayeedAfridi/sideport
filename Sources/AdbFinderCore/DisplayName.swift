import Foundation

/// Resolves case-insensitive filename collisions.
///
/// The device filesystem is case-sensitive; the Mac's usually is not. `a.txt`
/// and `A.txt` can genuinely coexist in one Android directory, and presenting
/// both unchanged would let one silently shadow the other in Finder. We keep the
/// true name for talking to the device and disambiguate only what is displayed.
///
/// The same applies to Unicode normalisation, which is why the *result* is keyed
/// by `ExactName`: `café` in NFC and NFD are two files on the phone but one name
/// to both Swift and APFS. Grouping still uses ordinary string equality, because
/// grouping is exactly what we want — it is only the lookup afterwards that has
/// to tell the two apart.
enum DisplayName {
    /// Maps true name → display name for one directory's worth of entries.
    ///
    /// Ordering is by exact name so the result is stable across enumerations:
    /// the same file must not swap display names between refreshes.
    static func resolve(_ names: [String]) -> [ExactName: String] {
        var groups: [String: [String]] = [:]
        for name in names {
            groups[name.lowercased(), default: []].append(name)
        }

        var result: [ExactName: String] = [:]
        for (_, collided) in groups {
            guard collided.count > 1 else {
                result[ExactName(collided[0])] = collided[0]
                continue
            }
            // Byte order, so a file keeps its suffix across refreshes even when
            // the collision is a normalisation one and `sorted()` would be free
            // to return either order.
            for (offset, name) in collided.sorted(by: ExactName.precedes).enumerated() {
                result[ExactName(name)] = offset == 0 ? name : suffixed(name, offset + 1)
            }
        }
        return result
    }

    /// `photo.jpg` → `photo (2).jpg`, matching how Finder itself disambiguates.
    private static func suffixed(_ name: String, _ counter: Int) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        // A dotfile with no extension must not become ` (2).bashrc`.
        guard !base.isEmpty, !ext.isEmpty else { return "\(name) (\(counter))" }
        return "\(base) (\(counter)).\(ext)"
    }
}
