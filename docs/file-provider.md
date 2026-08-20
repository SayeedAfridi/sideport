# The File Provider side

How Finder's calls become device operations. The Finder-facing surface is
[`FileProviderExtension`](../Apps/SideportFileProvider/Sources/FileProviderExtension.swift),
which is deliberately thin: it translates and maps errors, and holds nothing
worth testing. The work happens in
[`DeviceSession`](../Apps/SideportFileProvider/Sources/DeviceSession.swift) and
in [`AdbFinderCore`](../Sources/AdbFinderCore).

## Bundles and entitlements

| Target | Bundle ID | Sandbox |
|---|---|---|
| Container app | `dev.afridi.sideport` | no |
| Extension | `dev.afridi.sideport.FileProvider` | yes, by force |
| App Group | `NU2JM39S5P.dev.afridi.sideport` | shared container |

Extension entitlements: `app-sandbox` (mandatory), `network.client` (loopback to
the adb server), `application-groups` (the shared metadata store). That is the
whole list — no file access, no credentials.

Four `Info.plist` keys are load-bearing, and each was found by reading iCloud
Drive's own plist rather than by guessing:

| Key | Why |
|---|---|
| `NSExtensionFileProviderSupportsEnumeration: true` | Current, not legacy — Apple's own provider sets it |
| `NSFileProviderDefaultDomainEnabled: false` | Otherwise the system creates a nameless default domain beside ours and Finder labels *that* with the app's name |
| `NSExtensionFileProviderEnabledByDefault: true` | Without it the domain can land disabled: browsing works, every write fails with `-2011` — a read-only mount that looks writable |
| `NSFileProviderHideExtensionName: true` | So the sidebar shows the device's name, not the provider's |

They live in [`project.yml`](../project.yml), which generates the plist. Never
edit the generated file.

### The icon in the sidebar

The domain has no icon of its own to set. `NSFileProviderDomain` carries a name
and nothing visual, and the FileProvider framework exposes no icon anywhere else
— `NSFileProviderItemDecoration` badges an item, it does not draw the sidebar
row. Left alone, a mounted phone gets the same generic folder icon as any
directory.

The one supported hook is a **fifth `Info.plist` key on the extension**:

| Key | Why |
|---|---|
| `CFBundleIcons` → `CFBundlePrimaryIcon` → `CFBundleSymbolName` | The Finder sidebar row for the domain. Names an SF Symbol, which Finder draws as a template glyph |

We name `iphone.gen3`: the bezel-less slab, with no notch and no home button, so
nothing about it says *iPhone* to someone looking at their Android. As a template
it tints with the sidebar like Network and iCloud Drive, instead of sitting there
as a full-colour app icon — which is the look Apple's own HIG argues against and
which providers that ship an `.icns` end up with.

Two plausible-looking routes are dead ends, and both were tried:

- **An icon on the root item's type.** Declaring an exported UTI for the root and
  giving it an `.icns` does register — `NSWorkspace.icon(for:)` hands back the
  custom picture — but Finder never asks. The sidebar row and the mount point in
  `~/Library/CloudStorage` both stay generic folders.
- **An app icon on the extension bundle.** `CFBundleIconName` plus an asset
  catalog in the `.appex` is how the *File Providers* pane in System Settings
  finds a picture, and an asset catalog is separately documented to stop template
  sidebar icons working at all.

For a custom glyph rather than a stock one, `CFBundleSymbolName` also accepts the
name of a custom symbol in the extension's asset catalog — the same route the
menu bar glyph would take if the phone ever needs to become
[`make-glyph.swift`](../scripts/make-glyph.swift)'s rail-and-pane shape.

## Domain lifecycle

One `NSFileProviderDomain` per device, owned by the container app
([`DomainController`](../Apps/Sideport/Sources/DomainController.swift)):

```
AdbClient.deviceChanges()
  → device appears, state == .device
      → NSFileProviderManager.add(domain(identifier: serial, displayName: name))
  → device leaves, or goes unauthorized
      → NSFileProviderManager.remove(domain, mode: .removeAll)
```

The **serial is the domain identifier**, so a phone that is unplugged and
replugged reuses its metadata store instead of renumbering every file. The
display name is separate, and follows the user's naming preference — what the
owner called the device, or the model number.

Removal uses `.removeAll` on purpose. Plain `remove(domain)` preserves the
system's replica, and cached item capabilities survive with it: a folder that has
since become writable keeps reading as read-only because Finder never asks again.

The extension receives the domain in `init(domain:)` and derives the serial from
it. That is its only configuration input.

## The storage root

The domain root maps to the device's user storage — normally
`/storage/emulated/0`. `/sdcard` is a symlink to `/storage/self/primary`, itself
a symlink, so it is resolved once at setup rather than costing two indirections
per operation.

Resolution does not trust `readlink -f`. A device that answers while its user
storage is still mounting resolves `/sdcard` to `/storage/self/primary` and stops
there, and taking that string on faith pinned an entire extension lifetime to a
directory that could not be read. Each candidate is **proven listable** before it
is cached, and the documented default is always tried last. See
[`Sideport.rootCandidates`](../Sources/AdbFinderCore/Identifiers.swift).

## The item model

[`ProviderItem`](../Apps/SideportFileProvider/Sources/ProviderItem.swift) maps a
stored row to `NSFileProviderItem`:

| Field | Source |
|---|---|
| `itemIdentifier` / `parentItemIdentifier` | our stable ids; the root is `.rootContainer` |
| `filename` | the display name — differs from the device name only when a case collision forced disambiguation; the root borrows the domain's name |
| `contentType` | `UTType` from the extension; `.folder` for directories, `.symbolicLink` for links |
| `documentSize` | set even when not downloaded, so Finder shows a size without materialising gigabytes to find it |
| `contentModificationDate` | the device's mtime |
| `itemVersion` | see [change-detection.md](change-detection.md) |
| `capabilities` | derived from the device's mode bits |

**Capabilities come from the mode bits, not from an assumption.** adb runs as uid
2000 (`shell`) and reaches user storage through supplementary groups such as
`media_rw` and `ext_data_rw`, so the *group* write bit is the meaningful signal.
Anything genuinely unwritable still fails at the device; advertising the truth up
front stops Finder offering an operation that would die halfway. The root
advertises no renaming or deleting — it is the volume.

`.allowsTrashing` is deliberately absent. See [decisions.md](decisions.md#d9--immediate-delete-no-trash).

## Enumeration

```
enumerator(for:request:)
  → resolve the identifier to a device path
  → one sync session, LIS2 the directory
  → reconcile against the metadata store (creates / deletes / renames / moves)
  → emit items to the observer
  → finishEnumerating(upTo: nil)
```

adb returns whole directories, so paging is not needed for correctness. If a
pathological directory ever demands it, chunk the *emission*, not the fetch.

Batch inside a single `withSyncSession` call. Session setup is a TCP connect plus
a transport handshake, and one session per directory makes deep traversal
visibly slow.

## Fetching content

`fetchContents` pulls to a temp file in the extension's container, reports bytes
through `Progress` as chunks arrive, closes the socket from
`Progress.cancellationHandler`, and returns the version it actually fetched so
the system can detect a race with a device-side change.

### Partial fetching

A replicated provider materialises whole files or nothing, which means opening a
7 GB archive downloads 7 GB before anything can read its footer.
[`PartialFetching`](../Apps/SideportFileProvider/Sources/PartialFetching.swift)
implements `NSFileProviderPartialContentFetching` over ranged `dd` reads: 76 ms
instead of 218 seconds for a reader that wants the last 64 KB.

Serving exactly what the system asks for is a trap, though. It asks in 4 KB units
and never falls back to whole-file fetching on its own, so a plain `cat` of a
181 MB file became 362 ranged reads at 0.7 MB/s against 33 MB/s for the path it
displaced. [`PartialFetchPlan`](../Sources/AdbFinderCore/PartialFetchPlan.swift)
is the policy that prevents it:

- files under 32 MB are always fetched whole — at 33 MB/s that is under a second
- the first window is 512 KB, enough to amortise the ~75 ms setup
- a reader that keeps going gets geometrically larger windows, up to a ceiling
- a reader that is plainly streaming the file is handed the whole thing over the
  faster transport

## Writes

### Atomic push

Never `SEND` onto a live path — an interrupted transfer would truncate the file
the user already had.

```
SEND → <dir>/.sideport-tmp-<uuid>
mv   → <dir>/<final name>
```

`mv` within a directory is atomic on the device's filesystem. On failure the
staging file is removed; on unplug it is orphaned, and the sweep on reconnect
clears stale `.sideport-tmp-*`. This also sidesteps the `SEND "path,mode"` comma
ambiguity, since the staging name never contains one.

### Operation mapping

| File Provider call | Device operation |
|---|---|
| `createItem` (file) | atomic push |
| `createItem` (folder) | `mkdir -p` |
| `modifyItem` content | atomic push |
| `modifyItem` rename or reparent | `mv` |
| `deleteItem` | `rm -rf` |

Every path goes through `adbShellQuote`.

### What never reaches the device

Finder writes `.DS_Store` into every directory it displays, and AppleDouble `._`
sidecars beside real files on volumes without native xattr support. Left alone
they would litter the phone and show up in its own gallery and file manager.
[`SyncExclusions`](../Apps/SideportFileProvider/Sources/SyncExclusions.swift)
returns `NSFileProviderErrorExcludedFromSync`, which keeps the file in the Mac's
local replica — so Finder stays happy — while it is never uploaded.

## Errors are instructions

The File Provider API treats an error code as an *instruction*, not a
description:

- `.noSuchItem` — "this is gone, drop it from the replica"
- `.serverUnreachable` — "hold the change and retry"
- `.insufficientQuota` — "tell the user the destination is full"

So answering "no such item" to a failed upload does not mislabel the failure; it
**discards the file the user was copying**. The rules in
[`ProviderError`](../Sources/AdbFinderCore/ProviderError.swift) follow from that:
never widen a transient failure into a permanent one, and never claim an item is
missing unless the device said exactly that. Changes there need a test — the
consequence of a wrong code is a lost file, and "it compiled" is not evidence.

## Progress the user can believe

A copy *into* the device lands in the local replica first, at local-disk speed,
and Finder's copy sheet closes there. Only afterwards does the system hand the
extension files one at a time, at USB speed — an 11 GB folder once reported
"copied" and then spent four and a half more minutes on the cable with nothing
saying so.

The extension can only ever see the six sockets it holds open; the queue behind
them belongs to the system, and the system's own progress is the only place it is
counted. [`TransferMonitor`](../Apps/Sideport/Sources/TransferMonitor.swift)
reads that and reports it in the menu bar, phrased as work remaining — "Uploading
412 of 1072 — 6.8 GB left" — because that is the question someone opens the menu
to ask.
