# Traps

Every entry here cost real time, and every one fails in a way that points
somewhere else. Read this before concluding your code is wrong.

## The meta-lesson

File Provider failures rarely name their cause. A stale cached domain, a second
DerivedData directory, or a shell alias will each produce symptoms that look
exactly like a bug in the source you are staring at. When something makes no
sense, suspect the environment before the code.

## Build traps

**A target named `FileProvider` collides with Apple's framework module.** The
compiler treats `import FileProvider` as a self-import and drops it; the errors
that follow are "cannot find type 'NSObject'", which reads like a broken
toolchain.

**`ENABLE_DEBUG_DYLIB` (Xcode 16+) breaks appex signing.** It splits the
executable for faster incremental builds, and signing then fails with "code
object is not signed at all" — which reads like a certificate problem and is not.
Disabled for both targets in [`project.yml`](../project.yml).

**Two DerivedData directories silently run a stale build.** Regenerating the
Xcode project can create a second one, and any script that finds the app with
`find … | head -1` may launch the *old* binary. Every symptom afterwards looks
like a bug in the current source. Resolve the product with
`xcodebuild -showBuildSettings`, never by searching.

**LaunchServices keeps deleted paths registered.** After removing a stale
DerivedData copy, its registration survives and the system may resolve the bundle
to the dead path. `NSFileProviderManager.add` then fails with `-2001`
ProviderNotFound wrapping `-2014` ApplicationExtensionNotFound — "no launchable
extension for this domain's app bundle" — while the live bundle is present and
validly signed. `lsregister -u <dead path>` fixes it; a global rebuild is not
needed.

**`NSImage.lockFocus` renders at the display's backing scale.** Icons generated
that way come out 2× sized, and `actool` then rejects the whole catalog
*silently*: the build succeeds, `CompileAssetCatalog` runs, and
`Contents/Resources` is simply empty. Render into an `NSBitmapImageRep` whose
`size` matches its pixel dimensions — see
[`scripts/make-icon.swift`](../scripts/make-icon.swift).

## Runtime traps

**`Info.plist` changes are cached in the provider's state directory.** Editing
the plist and relaunching does nothing; the old configuration persists until that
directory is removed and `fileproviderd` restarted. That is what
[`scripts/reset-domain.sh`](../scripts/reset-domain.sh) — `make reset-domains` —
is for.

**An implicit default domain steals the sidebar label.** Without
`NSFileProviderDefaultDomainEnabled: false` the system creates a nameless default
domain beside the real ones and Finder labels *that* with the containing app's
name. The symptom is a sidebar entry reading "Sideport" while `Domains.plist`
plainly shows the device's name — the setting looks correct because it is; a
second domain is simply winning.

**A disabled domain looks like a read-only mount.** Without
`NSExtensionFileProviderEnabledByDefault: true` the domain can land disabled:
browsing works, every write fails with `NSFileProviderErrorDomainDisabled`
(`-2011`).

**`remove(domain)` preserves the system's replica.** Cached item capabilities
survive every other kind of reset, so a folder that has become writable still
reads as read-only because Finder never asks again. Use
`remove(domain, mode: .removeAll)`.

**`MenuBarExtra` content is lazy.** Work started from its `onAppear` does not run
until someone clicks the icon. The symptom is that no domain is ever registered
while the app looks like it launched fine. Start device watching from the app
delegate.

**`log` may be shadowed by a shell function or alias.** Every diagnostic comes
back empty, which reads as "the extension never launched" when it has been
working the whole time. Use `/usr/bin/log`, and doubt an empty log before you
doubt the code.

## Diagnostics

```sh
# Live logs from both processes
/usr/bin/log stream --predicate 'subsystem == "dev.afridi.sideport"' --level debug

# Just one area: enumeration, fetch, write, watch, adb, domain
/usr/bin/log stream --predicate 'subsystem == "dev.afridi.sideport" AND category == "watch"'

# Start clean
make reset-domains

# Take Finder out of the picture entirely
.build/debug/adbctl ls /sdcard/DCIM
.build/debug/adbctl selftest /sdcard
```

A reproduction through `adbctl` is worth far more than one through Finder: it
removes the sandbox, the replica, and Finder's caching from the picture. If
`adbctl` is fine and Finder is not, the bug is in the extension or in the state
the system is holding — and the second one is fixed by `make reset-domains`, not
by editing code.
