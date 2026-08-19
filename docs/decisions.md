# Decisions

Why the load-bearing choices were made, and what would justify revisiting them.
If you are about to change one of these, the argument against it is here.

## D1 — File Provider extension, not FSKit or macFUSE

A Finder Sync extension cannot mount anything — it only badges existing folders —
so despite the name it was never a candidate. Of the three real options:

- **macFUSE** needs reduced security and a reboot on Apple Silicon, which
  disqualifies it for a tool aimed at ordinary use.
- **FSKit** gives the most native result — a real volume in `/Volumes` with an
  eject button — but needs a provisioning-gated entitlement and a much stricter
  filesystem contract: inode lifetimes, attribute caching, exact errno semantics.
- **File Provider** is Apple's supported path, needs no special entitlement, and
  puts the device in the sidebar where a network location belongs.

**Revisit if** whole-file materialisation proves intolerable in practice. FSKit
could serve range reads natively. Partial fetching has since taken most of the
sting out of this — see [file-provider.md](file-provider.md).

## D2 — Speak the adb wire protocol, not the `adb` binary

Forced: the extension is sandboxed and cannot spawn subprocesses. It is also
faster, since one sync session serves many operations where the CLI pays a
process launch each time. Verified end to end — the sandboxed extension reaches
the adb server over loopback and runs device shell commands.

## D3 — Unsandboxed container app, sandboxed extension

Someone must find and launch the user's `adb`, which lives outside any sandbox
container. Since Developer ID distribution was the plan anyway, the app stays
unsandboxed; the extension has no choice and needs none.

**Cost:** no App Store. Accepted — the audience installs platform-tools already.

## D4 — Opaque persistent identifiers, not device inodes

Inodes on a FUSE-backed volume are not contractually stable across remounts, and
identifier instability is a catastrophic-looking bug. Inodes are kept as a
move-detection *hint* only. See [change-detection.md](change-detection.md).

## D5 — `inotifyd` push, polling as fallback

Decided after measurement, not preference: events arrive live over `shell,v2`.
Polling stays as a backstop because inotify is not recursive and its per-user
caps live in `/proc` files the `shell` user cannot read.

## D6 — The domain root is the resolved storage root

`/sdcard` is a symlink to `/storage/self/primary`, itself a symlink. Resolve once
at domain setup rather than paying two indirections per operation — but prove the
resolved path listable before caching it, because `readlink -f` will happily name
a directory that does not exist yet.

## D7 — Atomic push via staging file plus `mv`

Prevents truncation of an existing file on an interrupted transfer, and sidesteps
the `SEND "path,mode"` comma ambiguity as a bonus. Non-negotiable.

## D8 — Team-ID-prefixed App Group

App `dev.afridi.finderadb`, extension `dev.afridi.finderadb.FileProvider`, group
`NU2JM39S5P.dev.afridi.finderadb`.

The team-ID prefix is a macOS requirement, not a style choice. iOS uses
`group.<id>`; macOS wants the team ID first, and since Sequoia the sandbox
enforces it — an unprefixed group makes
`containerURL(forSecurityApplicationGroupIdentifier:)` return nil with no
diagnostic at all.

## D9 — Immediate delete, no trash

*Decided 2026-08-18.* A `.Trash-finderadb/` directory would be invisible to the
phone's own gallery and file manager, so it would consume storage the user could
not find **from the phone** — a leak diagnosable only from the Mac.

Android's own `.trashed-<expiry>-<name>` convention was considered. The reference
device does expose `is_trashed` in MediaStore, but whether a bare rename engages
the trash reaper is unverified and may hold only for indexed media, so it was not
built on a guess.

Item capabilities therefore omit `.allowsTrashing` deliberately. That is what
makes Finder warn "this cannot be undone" rather than imply a trash that does not
exist.

## D10 — Refuse macOS bookkeeping files rather than upload them

`.DS_Store` and AppleDouble `._` sidecars would litter the device and appear in
its own file managers. `NSFileProviderErrorExcludedFromSync` keeps them in the
Mac's local replica, so Finder behaves normally and the phone never sees them.

## D11 — Partial fetching is a policy, not a passthrough

Serving the system's requested range verbatim is slower than not implementing
partial fetching at all for a sequential reader: it asks in 4 KB units and never
falls back on its own. The growth policy in `PartialFetchPlan` is what makes the
feature a win rather than a regression. Any change there needs both numbers — the
random-access case *and* the sequential one.

## Open questions

| # | Question | Notes |
|---|---|---|
| Q3 | Bundle `adb`, or require the user's? | Bundling means shipping Google's binary and keeping it current, plus version skew with Android Studio's server. Leaning: require theirs, detect and explain. |
| Q4 | Expose `/data/local/tmp` and other roots? | Useful to developers. Multiple roots per domain, or one domain per root? |
| Q6 | Surface wireless adb? | It already works if the user pairs it themselves — we only ever talk to the local server. The question is whether to offer pairing UI. |

Settled since: Q1 (identifiers — D8), Q2 (`NSExtensionFileProviderSupportsEnumeration`
is current, since iCloud Drive's own provider sets it), Q5 (trash — D9).

## Known risks

**Whole-file materialisation.** Partial fetching covers readers that want part of
a large file; a genuine full read of a 6 GB file still moves 6 GB. Inherent to
the API.

**A shared adb server.** Android Studio or a Gradle build can run
`adb kill-server` at any moment. Treated as routine: reconnect with backoff,
never assume the server seen a second ago still exists.

**inotify watch limits.** A device with a huge `Android/data` could exceed caps
we cannot read. Mitigated by lazy, bounded watching and by rescanning on
overflow.

**One-second mtime granularity.** Sub-second rewrites of identical size are
invisible to versioning; the watcher covers device-side writes and we know our
own.

**Case and normalisation mismatch.** The device is case-sensitive and holds NFC
and NFD names side by side; macOS collapses both. Handled at the presentation
layer — never let one file silently shadow another.

**Filenames macOS dislikes**, `:` in particular. Needs a presentation-layer
escape that round-trips.
