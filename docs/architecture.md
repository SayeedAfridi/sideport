# Architecture

## Process layout

```
┌──────────────────────────────────────────────────────────────┐
│ Finder                                                        │
└───────────────┬──────────────────────────────────────────────┘
                │ NSFileProvider (system-mediated)
┌───────────────▼──────────────────────────────────────────────┐
│ SideportFileProvider.appex        SANDBOXED, one per device  │
│   NSFileProviderReplicatedExtension                           │
│   ├─ AdbKit                                                   │
│   └─ MetadataStore (SQLite, in the App Group container)       │
└───────────────┬──────────────────────────────────────────────┘
                │ TCP 127.0.0.1:5037
┌───────────────▼──────────────────────────────────────────────┐
│ adb server            the user's own, shared with Studio      │
└───────────────┬──────────────────────────────────────────────┘
                │ USB
┌───────────────▼──────────────────────────────────────────────┐
│ Android device — adbd, running as uid 2000 (shell)            │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ Sideport.app          NOT sandboxed, menu bar, login item    │
│   ├─ AdbKit (deviceChanges → add/remove NSFileProviderDomain) │
│   ├─ finds and launches the user's adb binary                 │
│   └─ settings, transfer status, diagnostics                   │
└──────────────────────────────────────────────────────────────┘
```

## Why the split

**The extension must be sandboxed.** macOS gives app extensions no choice, and a
sandboxed process cannot spawn `adb`. That single fact is why `AdbKit` speaks
the wire protocol over TCP instead of shelling out — the component that matters
could not shell out even if we wanted it to.

**The container app must not be sandboxed.** Someone has to find the user's
`adb` binary, which lives wherever they installed platform-tools, and start the
server when it is not running. A sandboxed app cannot reach
`~/Library/Android/sdk/platform-tools/adb`. See
[`AdbServerController`](../Apps/Sideport/Sources/AdbServerController.swift) for
the search order — `ANDROID_HOME` and `ANDROID_SDK_ROOT` win over any guess.

**The adb server is the user's, not ours.** We never start a private server on a
private port; Android Studio, Gradle and command-line `adb` must keep working
while a device is mounted. The corollary is that any of them can run
`adb kill-server` underneath us at any moment, so disconnection is a routine
state, not an error path.

## Trust boundary

The extension is the only component Finder talks to, and it is the least
privileged: sandboxed, network-*client* only, loopback only, holding no
credentials. Everything it can do, the user could already do by typing `adb`
themselves. The product adds an interface, not authority.

## Modules

| Module | Kind | Responsibility |
|---|---|---|
| [`AdbKit`](../Sources/AdbKit) | library | adb host, sync and shell protocols. No macOS-specific types, no File Provider. |
| [`AdbFinderCore`](../Sources/AdbFinderCore) | library | Identity mapping, metadata store, change log, error mapping, fetch planning. Pure logic. |
| [`adbctl`](../Sources/adbctl) | executable | CLI harness: `devices`, `ls`, `pull`, `push`, `watch`, `selftest`, `bench`. |
| [`SideportFileProvider`](../Apps/SideportFileProvider) | appex | Translates `NSFileProvider` calls into `AdbFinderCore` + `AdbKit`. Thin by design. |
| [`Sideport`](../Apps/Sideport) | app | Device discovery, domain lifecycle, adb server management, menu bar UX. |

`AdbFinderCore` exists so the hard parts — stable identifiers, sync anchors,
change replay, error mapping, partial-fetch policy — can be tested in
milliseconds with no device attached and no domain registered. Debugging a File
Provider extension is slow and misleading; keeping logic out of it is the main
defence, and it is why
[`FileProviderExtension`](../Apps/SideportFileProvider/Sources/FileProviderExtension.swift)
reads as a translation layer and nothing else.

Keep the dependency direction: `AdbKit` knows nothing about File Provider, and
the extension target holds no decisions worth testing.

## Shared state

One App Group container, one SQLite database **per device domain**:

```
NU2JM39S5P.dev.afridi.sideport/
  domains/
    <device-serial>/
      metadata.sqlite      identity map, change log, sync anchor
```

The extension is the only writer; the app reads for diagnostics. A single
database across domains would put unrelated devices behind one write lock for no
benefit.

The App Group identifier is **team-ID prefixed on purpose**. iOS uses
`group.<id>`; macOS requires the team ID first, and since Sequoia the sandbox
enforces it — `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil
for an unprefixed group, with nothing to explain why. Settings live in the same
suite ([`Preferences`](../Sources/AdbFinderCore/Preferences.swift)) so the app
and the extension cannot end up reading different stores.

## Concurrency bounds

- **6 concurrent adb operations.** Each occupies a thread for the length of its
  socket I/O, and a single USB transport serialises underneath anyway.
- **4096-entry path cache** in the metadata store, because the extension is
  long-lived and an unbounded cache in a long-lived process is a leak.
- **200 inotify watches**, evicted oldest-first — inotify is not recursive and
  the per-user cap lives in a `/proc` file the `shell` user cannot read.

## Failure model

Every row below is a normal, expected state:

| Situation | Behaviour |
|---|---|
| adb server not running | The app starts it. The extension reports the device unavailable until it is. |
| Another tool ran `adb kill-server` | Reconnect with backoff; the domain stays registered but unreachable. |
| Device unplugged | Domain removed, in-flight operations cancelled, partial local files discarded. |
| Device unauthorized | No domain registered; the menu bar explains the USB debugging prompt. |
| Unplugged mid-transfer | Socket closes → `AdbError.unexpectedEOF` → a File Provider error. Never a truncated destination file. |
| Storage root not yet mounted | Each candidate root is proven listable before it is cached; a device that answers while storage is still mounting does not pin the whole extension lifetime to an unreadable path. |
| Two devices of the same model | Sidebar names disambiguated; naming is a user preference (device name vs model). |
