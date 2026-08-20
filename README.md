# Sideport

Mount Android devices in macOS Finder over **adb** — no MTP, no macFUSE, no kext.

## Status

| Layer | State |
|---|---|
| `AdbKit` — native Swift adb client | ✅ built and verified against hardware |
| `adbctl` — CLI harness | ✅ 35/35 self-test checks pass on hardware |
| File Provider extension | ✅ browse, fetch, ranged reads, writes, live change detection |
| Container app (device discovery, domain registration) | ✅ menu bar app, transfer status, settings |
| Signed and notarized DMG | ✅ `make release` |

## Install

| | |
|---|---|
| macOS | 14 (Sonoma) or newer |
| `adb` | Android platform-tools — `brew install --cask android-platform-tools` |
| Device | Android phone with USB debugging turned on |

Sideport does not bundle `adb`. It finds the platform-tools you already have —
Homebrew, an Android Studio SDK, or anything on your login shell's `PATH` — and
starts the *shared* adb server, so Android Studio and the command line keep
working while a device is mounted.

1. Download `Sideport.dmg` from the
   [releases page](https://github.com/SayeedAfridi/sideport/releases). Sideport
   is in beta: releases are tagged `-beta.N`, and GitHub marks them
   pre-releases, which is why they do not appear as the *latest* release.
2. Open it and drag **Sideport** onto **Applications**. The build is signed and
   notarized, so it opens normally — no right-click-Open detour.
3. Launch it. There is no Dock icon: Sideport lives in the menu bar as a small
   phone, drawn with a slash through it while no device is usable.
4. Plug the phone in over USB and accept the debugging prompt on its screen.
   Until you do, the menu lists the device as *unauthorized*.

The device then appears in the Finder sidebar, and its files live under
`~/Library/CloudStorage/Sideport-<Device>`. Nothing is copied to the Mac until
you open it.

If the menu says *Turn on "Sideport" in System Settings*, macOS has switched the
File Provider extension off — it is registered enabled, but that can be
overridden. Use the button beside the message; it opens the right pane directly.
While the extension is off the device still browses, but every write is
rejected, which reads as a mount that is silently read-only.

Not working? [docs/troubleshooting.md](docs/troubleshooting.md) collects the
failures that point somewhere other than their cause. To build from source
instead, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Why the wire protocol instead of the `adb` binary

The Finder integration is an `NSFileProviderReplicatedExtension` — a **sandboxed
app extension**, which cannot spawn subprocesses. Shelling out to `adb push`
is therefore not an option in the component that matters.

Instead `AdbKit` speaks adb's own protocols over TCP to the local adb server on
`127.0.0.1:5037`. That is also what makes per-directory enumeration cheap: one
sync session serves many operations, where the CLI would pay a process launch
each time.

## Architecture

```
Finder
  └─ File Provider extension (sandboxed)
       └─ AdbKit ──TCP──▶ adb server :5037 ──USB──▶ device
  └─ Container app (registers the domain, starts adb server)
```

- **Host protocol** — `%04x`-length-prefixed requests, `OKAY`/`FAIL` replies.
  Used for `host:version`, `host:devices-l`, `host:track-devices-l` (hot-plug),
  `host-serial:<s>:features`, and `host:transport:<serial>`.
- **Sync protocol** (`sync:`) — `LIS2`/`STA2`/`RECV`/`SEND` for listing, stat,
  pull, push. 64-bit sizes and timestamps.
- **Shell protocol** (`shell,v2,raw:`) — separated stdout/stderr and a real exit
  code, for the operations sync cannot do: `mkdir`, `mv`, `rm`, `cp`, `df`.

## Protocol notes worth keeping

Packet trailer sizes are not guessable and a wrong one desyncs the stream
*silently* — the failure surfaces on the **next** operation, not the one at
fault. Measured against platform-tools 37.0.0:

| Packet | Bytes after the 4-byte id |
|---|---|
| `DNT2` (list entry) | 72, then `namelen` bytes of name |
| `DONE` ending a `LIS2` | 72 |
| `STA2` / `LST2` reply | **68** — `sync_dent_v2` minus its trailing `namelen` |
| `DONE` ending a `RECV` | 4 |
| `DATA` | 4-byte length, then payload (max 64 KiB) |

Other things that bite:

- `SEND` takes `"path,mode"` — a literal comma in a filename is ambiguous.
- `LIS2` reports `lstat`, so symlinks show as symlinks; use `STA2` to follow.
- A per-entry `error` field in `DNT2` means *that child* failed; skip it rather
  than aborting the listing.
- Any `FAIL` poisons the session — the device may not have drained our writes.

## Usage

```sh
swift build
swift test                          # pure-logic tests, no device needed

.build/debug/adbctl devices
.build/debug/adbctl ls /sdcard
.build/debug/adbctl pull /sdcard/DCIM/foo.jpg ./foo.jpg
.build/debug/adbctl watch            # hot-plug stream
.build/debug/adbctl selftest /sdcard # full round trip on real hardware
```

`-s SERIAL` selects a device when more than one is attached.

## Performance

Transfer speed is pinned by the USB link, so the number worth watching is
memory. `adbctl bench` measures both and flags buffering:

```sh
.build/release/adbctl bench 256 /sdcard
```

Both directions stream through a single reusable frame buffer — an 8-byte
header plus payload, filled in place by `read(2)` and written with one `send` —
so peak RSS is independent of file size.

| | before | after |
|---|---|---|
| push 256 MB, peak RSS | 269 MB | **10.5 MB** |
| push 1 GB, peak RSS | — | **11.1 MB** |
| push 256 MB, CPU time | 0.09 s | **0.02 s** |
| throughput | 40 MB/s | 40 MB/s (USB limit) |

The original loop used `FileHandle.read(upToCount:)`, which held the whole file
resident. Throughput never revealed it, because the link was the bottleneck
either way.

Other bounds worth knowing: concurrent adb operations are capped at 6, since
each occupies a thread for the length of its socket I/O and a single USB
transport serialises underneath anyway; and the metadata store's path cache is
capped at 4096 entries because the extension is long-lived.

## Measured on hardware

Xiaomi 25053PC47I (`onyx`), USB, platform-tools 37.0.0:

- push 64 MB — 1.71 s
- pull 64 MB — 1.69 s (≈40 MB/s, SHA-256 verified)

That is the USB link limit, so the optional `sendrecv_v2` compressed transfer
modes the device advertises (`lz4`, `zstd`, `brotli`) would buy nothing here.

## Documentation

[`docs/`](docs/) explains the parts that are not obvious from the code:

- [architecture.md](docs/architecture.md) — the process split and why it exists
- [adb-protocol.md](docs/adb-protocol.md) — the wire protocol reference
- [file-provider.md](docs/file-provider.md) — how Finder's calls become device operations
- [change-detection.md](docs/change-detection.md) — identifiers, versions, and the watcher
- [decisions.md](docs/decisions.md) — why the load-bearing choices were made
- [troubleshooting.md](docs/troubleshooting.md) — traps that misdirect
- [releasing.md](docs/releasing.md) — signing, notarization, and the release workflow

## Contributing

Bug reports and patches are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for
the build, the test gates, and the parts of the protocol that fail silently when
they are wrong.

## License

[MIT](LICENSE) © Sayeed Afridi
