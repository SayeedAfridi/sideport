# Documentation

Reference material for anyone working on Sideport. The [top-level
README](../README.md) is the pitch and the quick start; this folder is the
explanation.

| Doc | What it answers |
|---|---|
| [architecture.md](architecture.md) | What the processes are, why the split exists, what each one is allowed to do |
| [adb-protocol.md](adb-protocol.md) | The wire protocol reference — packets, sizes, and the parts that fail silently |
| [file-provider.md](file-provider.md) | How Finder's calls become device operations: domains, items, enumeration, fetch, writes |
| [change-detection.md](change-detection.md) | Stable identifiers, content versions, and how the device tells us it changed |
| [decisions.md](decisions.md) | Why the load-bearing choices were made, and what would justify revisiting them |
| [troubleshooting.md](troubleshooting.md) | Build and runtime traps that misdirect — read this before doubting your code |
| [releasing.md](releasing.md) | Signing, notarization, and what `make release` verifies |

Want to change something? [CONTRIBUTING.md](../CONTRIBUTING.md) has the build,
the test gates, and the commit conventions.

## Reference hardware

Every measurement in these docs comes from one device. Re-verify before treating
any number as universal.

| | |
|---|---|
| Device | Xiaomi 25053PC47I (`onyx`) |
| Android | 16 (SDK 36), toybox 0.8.12-android |
| Host | macOS 26, Apple Silicon, platform-tools 37.0.0 |
| Transfer | ~40 MB/s both directions — the USB link limit |
| Tree | 339 directories, 6,460 entries under `/storage/emulated/0` |
| Full `find` of all directories | 0.59 s |
