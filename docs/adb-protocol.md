# The adb wire protocol, as this project uses it

[`AdbKit`](../Sources/AdbKit) talks to the local adb server on
`127.0.0.1:5037` the same way the `adb` binary does. Nothing here is
reverse-engineered guesswork — it is what platform-tools 37.0.0 actually sends
and expects, verified against hardware by `adbctl selftest`.

Read this before changing anything under `Sources/AdbKit`. **A wrong packet size
does not fail where you wrote it.** It desyncs the stream, and the error
surfaces on some later operation that is entirely innocent.

## Three protocols, one socket

| Protocol | Opened with | Used for |
|---|---|---|
| Host | plain request to the server | server version, device list, hot-plug stream, feature negotiation |
| Sync | `sync:` after a transport | list, stat, pull, push |
| Shell v2 | `shell,v2,raw:<cmd>` after a transport | everything sync cannot do: `mkdir`, `mv`, `rm`, `cp`, `df`, `inotifyd`, `dd` |

A connection starts as a conversation with the *server* and becomes a stream to
the *device* once a transport is selected — that is how `sync:` and `shell:`
sessions are born. See
[`AdbConnection`](../Sources/AdbKit/AdbConnection.swift).

## Host protocol

Requests are ASCII, prefixed with their length as four hex digits (`%04x`).
Replies are `OKAY` or `FAIL`, and `FAIL` carries a length-prefixed reason.

| Request | Purpose |
|---|---|
| `host:version` | Server version — also the cheapest "is the server up?" probe |
| `host:devices-l` | Device list with model and product fields |
| `host:track-devices-l` | Hot-plug stream; falls back to `host:track-devices` on older servers |
| `host-serial:<serial>:features` | Feature set, without opening a transport |
| `host:transport:<serial>` | Bind this connection to one device |

Transport selection also has `host:transport-usb`, `-local` and `-any`, exposed
as `DeviceSelector` cases.

`host:devices-l` reports `ro.product.model`, which on many phones is the sales
model number rather than what the owner named the device — hence the separate
`deviceName` lookup over the shell, and the sidebar naming preference.

## Sync protocol

Every packet is a 4-byte ASCII id followed by a fixed-size body. The body sizes
are **not guessable**, and getting one wrong is the failure mode described
above. Measured against platform-tools 37.0.0:

| Packet | Bytes after the 4-byte id |
|---|---|
| `DNT2` (list entry) | 72, then `namelen` bytes of name |
| `DONE` ending a `LIS2` | 72 |
| `STA2` / `LST2` reply | **68** — `sync_dent_v2` minus its trailing `namelen` |
| `DONE` ending a `RECV` | 4 |
| `DATA` | 4-byte length, then payload, never more than 64 KiB |

### Commands

- **`LIS2 <path>`** — list a directory. Streams `DNT2` entries until `DONE`.
  64-bit sizes and timestamps, so files over 4 GiB list correctly (verified with
  a 6.03 GB file).
- **`STA2 <path>` / `LST2 <path>`** — stat, following symlinks or not.
- **`RECV <path>`** — pull. Streams `DATA` chunks until `DONE`.
- **`SEND <path>,<mode>`** — push. `DATA` chunks, then `DONE` carrying the mtime
  as a `uint32`, then `OKAY` or `FAIL`.

### Things that bite

- **`SEND` takes `"path,mode"`** and the device splits on the *last* comma, so a
  filename containing a comma is ambiguous. We always `SEND` to a UUID-derived
  staging name and `mv` afterwards, which sidesteps it — one of two reasons the
  atomic-push design is not optional.
- **`LIS2` reports `lstat`**, so symlinks appear as symlinks. Follow with `STA2`
  when the kind matters.
- **A per-entry `error` field in `DNT2`** means *that child* failed. Skip it;
  aborting the whole listing turns one unreadable file into an empty folder.
- **Any `FAIL` poisons the session.** The device may not have drained our
  writes, so the session is closed rather than reused.
- **mtime is whole seconds.** Two writes to one file within the same second,
  ending at the same size, are indistinguishable by stat alone. See
  [change-detection.md](change-detection.md) for what covers that gap.
- **Sessions are worth reusing.** Setup is a TCP connect plus a transport
  handshake; opening one per directory makes tree traversal visibly slow.
  `withSyncSession` exists to batch.

## Shell protocol

`shell,v2,raw:<command>` gives separated stdout and stderr and a real exit code,
which is what makes error mapping possible at all. `raw` mode is binary-safe.

Used for:

| Need | Command |
|---|---|
| Create a directory | `mkdir -p` |
| Rename / move | `mv` |
| Delete | `rm -rf` |
| Duplicate | `cp` |
| Capacity | `df` |
| Change detection | `inotifyd - <dir>:ncdwmyD` |
| Ranged read | `dd if=<path> bs=... skip=... count=...` |

Every path goes through `adbShellQuote`. The self-test covers quotes, spaces,
`$`, `&`, unicode, and a filename that *begins* with a space.

`shell,v2` streams: `inotifyd` events arrive live, which is why change detection
is push rather than polling.

## Ranged reads

The sync protocol's `RECV` cannot do ranges, but the shell can — `dd` over
`shell,v2,raw` streams an arbitrary window. See
[`AdbClient+Range`](../Sources/AdbKit/AdbClient+Range.swift).

The trade is worth stating plainly: ranged reads run at roughly half `RECV`'s
throughput plus about 75 ms of fixed setup. They are a **latency** win for a
reader that wants a little of a lot — Finder's preview, Archive Utility, any
container format that reads its footer first — and a catastrophe for one that
wants the whole file. [`PartialFetchPlan`](../Sources/AdbFinderCore/PartialFetchPlan.swift)
is what keeps the second case from happening.

## Memory

Both transfer directions stream through a single reusable frame buffer — an
8-byte header plus payload, filled in place by `read(2)` and written with one
`send` — so peak RSS is independent of file size.

| | before | after |
|---|---|---|
| push 256 MB, peak RSS | 269 MB | **10.5 MB** |
| push 1 GB, peak RSS | — | **11.1 MB** |
| push 256 MB, CPU time | 0.09 s | **0.02 s** |
| throughput | 40 MB/s | 40 MB/s (USB limit) |

The original loop used `FileHandle.read(upToCount:)`, which held the whole file
resident. Throughput never revealed it, because the link was the bottleneck
either way. This is why `adbctl bench` reports peak RSS, and why that is the
number to watch in a transfer change.

## Verified on hardware

Recorded because it was measured, not assumed:

- 64-bit sizes — a 6.03 GB file lists and stats correctly
- `Android/data` and `Android/obb` are readable: `shell` holds `ext_data_rw` and
  `ext_obb_rw`
- live `inotifyd` events over `shell,v2`
- ~40 MB/s both directions, SHA-256 verified, at the USB link limit
- awkward filenames survive push, move and stat
- the sandboxed extension reaches the adb server over loopback and runs device
  shell commands — the whole premise of speaking the protocol directly
- multiple operations on one sync session stay correctly framed

The device advertises the `sendrecv_v2` compressed modes (`lz4`, `zstd`,
`brotli`). They would buy nothing here: the link, not the CPU, is the limit.
