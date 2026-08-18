# finder-adb

Mount Android devices in macOS Finder over **adb** — no MTP, no macFUSE, no kext.

## Status

| Layer | State |
|---|---|
| `AdbKit` — native Swift adb client | ✅ built and verified against hardware |
| `adbctl` — CLI harness | ✅ 17/17 self-test checks pass |
| File Provider extension | ⬜ next |
| Container app (device discovery, domain registration) | ⬜ next |

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
  └─ File Provider extension (sandboxed)   ← next
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

## Measured on hardware

Xiaomi 25053PC47I (`onyx`), USB, platform-tools 37.0.0:

- push 64 MB — 1.71 s
- pull 64 MB — 1.69 s (≈40 MB/s, SHA-256 verified)

That is the USB link limit, so the optional `sendrecv_v2` compressed transfer
modes the device advertises (`lz4`, `zstd`, `brotli`) would buy nothing here.
