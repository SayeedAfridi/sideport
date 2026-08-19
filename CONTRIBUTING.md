# Contributing to finder-adb

Thanks for looking. This is a small, deliberately opinionated project: it mounts
an Android device in Finder by speaking adb's wire protocol directly, and almost
every design choice follows from one constraint — a File Provider extension is
sandboxed and **cannot spawn subprocesses**, so shelling out to `adb` is not an
option in the part that matters.

Read [README.md](README.md) first, then whichever of [`docs/`](docs/) covers
what you are touching — [architecture](docs/architecture.md), the [adb wire
protocol](docs/adb-protocol.md), the [File Provider side](docs/file-provider.md),
[change detection](docs/change-detection.md), or the [decision
log](docs/decisions.md). The protocol notes are not trivia; a wrong packet
trailer size desyncs the stream *silently* and the failure surfaces on a later
operation, not the one at fault.

## What you need

| | |
|---|---|
| macOS | 14.0 or newer |
| Xcode | 16 or newer (Swift 6 toolchain) |
| `adb` | `brew install --cask android-platform-tools` — verified against 37.0.0 |
| `xcodegen` | `brew install xcodegen` — only for the app targets |
| A device | Any Android phone with USB debugging on, for hardware tests |

The Swift package (`AdbKit`, `AdbFinderCore`, `adbctl`) builds and tests with
nothing but a toolchain. Only the container app and the extension need Xcode,
XcodeGen and a signing identity.

## The layers

```
Sources/AdbKit          adb wire protocol — host, sync, shell. No Finder, no AppKit.
Sources/AdbFinderCore   provider logic — metadata store, identifiers, error mapping.
Sources/adbctl          CLI harness — the fastest way to exercise a change.
Apps/FinderADB          menu bar container app: discovery, domain registration.
Apps/FinderADBFileProvider  the sandboxed extension Finder actually talks to.
```

Keep the dependency direction. `AdbKit` knows nothing about File Provider;
`AdbFinderCore` is where provider logic lives *so that it can be tested* without
Finder in the loop. If you find yourself putting decision-making code in the
extension target, that is usually a sign it belongs in the core.

## Build and test

```sh
swift build
swift test                # pure logic, no device required — must stay that way
make app                  # container app + extension (needs xcodegen + Xcode)
```

With a device attached:

```sh
.build/debug/adbctl devices
.build/debug/adbctl selftest /sdcard        # round-trips every operation
swift build -c release && .build/release/adbctl bench 256 /sdcard
```

`selftest` is the acceptance gate for anything touching the protocol — it works
in a scratch directory and cleans up after itself. `bench` reports throughput
*and peak RSS*; the RSS number is the one that catches regressions, because
throughput is pinned by the USB link and will look fine even when a change
starts buffering whole files in memory.

`swift test` must never require hardware. If a change can only be verified
against a device, put the verification in `adbctl` and say so in the PR.

## Generated files — do not commit them

`project.yml` is the source of truth for the Xcode side. These are generated and
git-ignored:

- `FinderADB.xcodeproj` (`make project`)
- `Apps/*/Info.plist`, `Apps/*/*.entitlements`

Edit `project.yml` and regenerate. A PR that changes the `.xcodeproj` will be
asked to move the change into `project.yml`.

## Signing, and why the team ID is hard-coded

`project.yml` and the release scripts pin `DEVELOPMENT_TEAM = NU2JM39S5P`. To
build the app targets you need your own Apple Developer team: change the team ID
locally, and **leave that change out of your commits**. The extension needs an
App Group whose identifier carries the team prefix, so there is no way around it
today. If you want to make the team ID configurable, that is a welcome PR.

Signed, notarized releases (`make release`) are maintainer-only — they need a
Developer ID certificate and a notarytool credential. `scripts/preflight-release.sh`
reports what a machine is missing and changes nothing, so it is safe to run.
`make dmg` builds a real Release DMG signed with whatever identity your Mac has;
it will not pass Gatekeeper anywhere else, but it is useful for testing the
release configuration.

## Working on the extension

Finder caches domains aggressively and a half-registered domain is worse than
none:

```sh
make reset-domains        # tear down every registered File Provider domain
```

Logs go through `os.Logger` under the subsystem `dev.afridi.finderadb`, with
categories `enumeration`, `fetch`, `write`, `watch`, `adb`, `domain`:

```sh
log stream --predicate 'subsystem == "dev.afridi.finderadb"' --level debug
```

[docs/troubleshooting.md](docs/troubleshooting.md) collects the failures that
point somewhere other than their cause — a cached `Info.plist`, a stale
DerivedData copy, a shadowed `log` command. It is worth reading once before you
need it.

Error mapping deserves special care. The File Provider API treats an error code
as an *instruction* — `.noSuchItem` tells Finder to drop the item from the
replica — so widening a transient failure into a permanent one loses user data.
`Sources/AdbFinderCore/ProviderError.swift` explains the rules; changes there
need a test.

## Code style

- Match the surrounding code: four-space indent, no trailing whitespace.
- The package targets are Swift 6 with strict concurrency. The AppKit and File
  Provider glue is deliberately Swift 5 mode; keep new logic in the package.
- Comments explain **why**, not what. The existing ones record measurements,
  protocol quirks and the reason a workaround exists — that is the bar.
- Numbers in comments (packet sizes, caps, timings) should say where they came
  from. `LIS2` trailer sizes were measured against platform-tools 37.0.0; if you
  change one, say what you measured it against.

## Commits

Conventional Commits, lowercase, imperative, and specific about the change:

```
fix(sync): stop reading an unreadable directory as an empty one
perf(watch): cut change propagation from 10-17s to 0.3s
feat(fetch): serve byte ranges without materialising whole files
```

Scopes in use: `adb`, `sync`, `watch`, `fetch`, `store`, `provider`, `app`,
`errors`, `release`, `git`. One concern per commit; a commit that both fixes a
bug and reformats a file is two commits.

## Pull requests

Before opening one:

1. `swift test` passes.
2. `adbctl selftest /sdcard` passes on a real device, if the change touches
   protocol, transfer or metadata code.
3. `make app` builds, if the change touches the app or extension.

In the description, say what you verified and on what — device model, `adb`
version, macOS version. "Compiles" is not verification for this codebase; the
failure modes here are silent stream desync and data loss, and neither shows up
at build time.

## Reporting bugs

Include:

- macOS version and Mac model
- device model and Android version, plus `adb version`
- what Finder did, and what `adbctl` does for the same path
- the relevant `log stream` output (predicate above)

A reproduction through `adbctl` is worth far more than one through Finder — it
takes the sandbox, the replica and Finder's caching out of the picture.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE) that covers this project.
