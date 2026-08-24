# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Sideport mounts an Android device in macOS Finder by speaking adb's wire protocol over TCP to the user's own adb server — no MTP, no macFUSE, no kext.

## Commands

```sh
swift build                       # AdbKit + AdbFinderCore + adbctl
swift test                        # pure logic, no device — must stay that way
swift test --filter DeviceParsingTests    # one suite (swift-testing, not XCTest)
make app                          # container app + extension (needs xcodegen + Xcode 16)
make project                      # regenerate Sideport.xcodeproj from project.yml
make reset-domains                # tear down every registered File Provider domain
make preflight                    # report what a machine lacks for a signed release (read-only)
make dmg / make release           # local-signed DMG / signed+notarized (maintainer only)
```

With a device attached — `adbctl` is the fastest way to exercise a change:

```sh
.build/debug/adbctl devices | ls <p> | pull | push | watch | watchfs <dir>
.build/debug/adbctl selftest /sdcard      # acceptance gate for protocol/transfer/metadata changes
.build/debug/adbctl resilience /sdcard    # kills the server underneath live transfers
swift build -c release && .build/release/adbctl bench 256 /sdcard   # throughput + peak RSS
```

`-s SERIAL` picks a device. `bench`'s peak RSS is the regression signal, not throughput (throughput is pinned by USB).

Logs: `log stream --predicate 'subsystem == "dev.afridi.sideport"' --level debug` (categories: `enumeration`, `fetch`, `write`, `watch`, `adb`, `domain`).

## Architecture

```
Finder ─NSFileProvider→ SideportFileProvider.appex (SANDBOXED, one per device)
                          └─ AdbKit ─TCP 127.0.0.1:5037→ adb server ─USB→ device
                          └─ MetadataStore (SQLite, App Group container)
Sideport.app (NOT sandboxed, menu bar): finds/launches adb, registers domains
```

| Layer | Rule |
|---|---|
| `Sources/AdbKit` | adb host/sync/shell protocols. Knows nothing about File Provider or AppKit. |
| `Sources/AdbFinderCore` | Identifiers, metadata store, change log, error mapping, fetch planning. Pure, testable logic. |
| `Sources/adbctl` | CLI harness. Hardware-only verification goes here, never in `swift test`. |
| `Apps/SideportFileProvider` | Translation layer only — no decisions worth testing. |
| `Apps/Sideport` | Discovery, domain lifecycle, adb server management, menu bar UX. |

Keep the dependency direction. Decision-making code in the extension target almost always belongs in `AdbFinderCore` — debugging an appex is slow and misleading.

**Why the split:** an app extension is sandboxed by force and cannot spawn subprocesses, so `adb push` is not an option in the component that matters; the container app must *not* be sandboxed so it can find the user's `adb` binary. The adb server is the user's shared one — anyone can `adb kill-server` underneath us, so disconnection is a routine state, not an error path.

`docs/` carries the real reference: [architecture](docs/architecture.md), [adb-protocol](docs/adb-protocol.md), [file-provider](docs/file-provider.md), [change-detection](docs/change-detection.md), [decisions](docs/decisions.md), [troubleshooting](docs/troubleshooting.md), [releasing](docs/releasing.md). Read the relevant one before touching that layer.

## Traps that fail silently

- **Packet trailer sizes desync the stream silently** and surface on the *next* operation. Measured against platform-tools 37.0.0: `DNT2` 72 + namelen, `DONE` after `LIS2` 72, `STA2`/`LST2` **68**, `DONE` after `RECV` 4. Any `FAIL` poisons the session.
- **File Provider error codes are instructions, not descriptions.** `.noSuchItem` tells Finder to drop the item from the replica — widening a transient failure into a permanent one destroys user data. Rules live in [ProviderError.swift](Sources/AdbFinderCore/ProviderError.swift); changes there need a test.
- **Identifiers are opaque rows in SQLite**, not paths or device inodes; `AUTOINCREMENT` and the partial uniqueness index are load-bearing (see [change-detection.md](docs/change-detection.md)). Reconcile pass order — names, then inode moves, then create/delete — *is* the algorithm.
- Generated, git-ignored, never commit: `Sideport.xcodeproj`, `Apps/*/Info.plist`, `Apps/*/*.entitlements`. Edit [project.yml](project.yml) and regenerate.
- `DEVELOPMENT_TEAM = NU2JM39S5P` is pinned; change it locally to build, keep it out of commits. The App Group must stay team-ID-prefixed or `containerURL(forSecurityApplicationGroupIdentifier:)` silently returns nil.

## Conventions

- Package targets are Swift 6 strict concurrency; the AppKit/File Provider glue is deliberately Swift 5 mode. Put new logic in the package.
- Four-space indent. Comments explain **why** and cite where a number came from (packet size, cap, timing, what it was measured against).
- Conventional Commits, lowercase, imperative, one concern each. Scopes in use: `adb`, `sync`, `watch`, `fetch`, `store`, `provider`, `app`, `errors`, `release`, `git`.
- "Compiles" is not verification here. Say what you verified and on what hardware — device model, `adb` version, macOS version.

**note**: don't put co-authored text in commit messages