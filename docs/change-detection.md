# Identity, versioning, and change detection

The three problems most likely to produce Finder bugs that look like magic.

## 1. Stable identifiers

`NSFileProviderItemIdentifier` must survive renames and moves. A device path
cannot be the identifier: renaming a folder would change the identifier of
everything beneath it, and Finder would watch the whole subtree vanish and
reappear — collapsing open documents on the way.

**Rejected: Android inode numbers.** `DNT2` and `STA2` do carry `dev` and `ino`,
and they are genuinely stable per file. But `/storage/emulated/0` is FUSE-backed,
and inode stability across reboots and remounts is not contractual. Too
load-bearing to gamble on.

**Chosen: our own opaque identifiers**, persisted per device in
[`MetadataStore`](../Sources/AdbFinderCore/MetadataStore.swift):

```sql
CREATE TABLE items (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    parent_id    INTEGER NOT NULL REFERENCES items(id),
    name         TEXT    NOT NULL,   -- the device's bytes
    display_name TEXT    NOT NULL,   -- what Finder shows
    is_dir       INTEGER NOT NULL,
    size         INTEGER NOT NULL,
    mtime        INTEGER NOT NULL,
    mode         INTEGER NOT NULL,
    dev          INTEGER,            -- hint only, for move detection
    ino          INTEGER,            -- hint only
    deleted_at   INTEGER
);
CREATE UNIQUE INDEX items_live_name ON items(parent_id, name) WHERE deleted_at IS NULL;
```

- Row 1 is the root, is its own parent — which is what terminates path
  resolution — and maps to `NSFileProviderItemIdentifier.rootContainer`.
- A device path is reconstructed by walking `parent_id` upward.
- Rename updates `name`; move updates `parent_id`. The identifier never changes,
  so an entire subtree keeps its identity for free.

Two details in that schema are load-bearing:

- **`AUTOINCREMENT` is not decoration.** Without it SQLite reuses the highest
  freed rowid, so a purged tombstone could hand its identifier to an unrelated
  new file — and Finder would believe a deleted item had come back.
- **The uniqueness index is partial.** Tombstones must be allowed to share a name
  with the live entry that replaced them.
- The root seed mode is `0o40770`, not `0o40755`: capabilities derive from the
  group-write bit, and a root seeded without it advertises read-only until the
  device's real mode arrives — which is long enough for Finder to hide "New
  Folder".

## 2. Reconciliation

[`reconcile(directory:listing:)`](../Sources/AdbFinderCore/MetadataStore+Reconcile.swift)
folds a fresh `LIS2` into the store. **The order of the passes is the whole
algorithm:** match names first, then detect moves by inode, and only then treat
what is left as created or deleted.

| Situation | Result |
|---|---|
| Name present in both | compare; emit *modified* only if something Finder would notice differs |
| Stored name gone, `(dev, ino)` reappeared elsewhere | *moved* |
| New name, unseen inode | *created* |
| Stored name absent | *deleted* — a tombstone, never a hard delete |

Get the order wrong and a rename comes out as delete-plus-create, which destroys
the item's identity. When the device gives no inode, move detection degrades to
delete-plus-create — noisier, never incorrect. Tombstones matter because
`enumerateChanges` must be able to report a deletion to a client whose anchor
predates it.

### Names are bytes, not strings

The device filesystem is case-sensitive and normalisation-agnostic; macOS is
usually neither.

- `a.txt` and `A.txt` genuinely coexist on a phone.
  [`DisplayName`](../Sources/AdbFinderCore/DisplayName.swift) keeps the true name
  for talking to the device and disambiguates only what is displayed, ordered by
  exact bytes so a file cannot swap display names between refreshes.
- `café` in NFC and in NFD are two files on the phone and one `String` in Swift.
  Keying a directory by `String` therefore collapses them — and
  `Dictionary(uniqueKeysWithValues:)` *traps* on the duplicate, crashing the
  extension. [`ExactName`](../Sources/AdbFinderCore/ExactName.swift) makes
  byte-exactness part of the type so the next dictionary over filenames cannot
  quietly reintroduce it.

## 3. Content versioning

`NSFileProviderItemVersion` carries two hashes:

- **content** = SHA-256 of `(size, mtime)`
- **metadata** = SHA-256 of `(name, parent_id, mode)`

**Known weakness:** the sync protocol carries mtime in whole seconds. Two writes
to one file within the same second, ending at the same size, are
indistinguishable by stat alone.

What covers it:

- for *our own* writes we know the resulting version exactly and record it
- for device-side writes the watcher reports the change regardless of whether the
  version bytes moved

Only if both are unavailable — polling fallback plus a sub-second rewrite — can a
change be missed. Documented, not silently ignored.

## 4. Watching the device

[`InotifyWatcher`](../Apps/FinderADBFileProvider/Sources/InotifyWatcher.swift)
runs `inotifyd - <dir>:ncdwmyD` over one long-lived `shell,v2` connection.
Events arrive live — a photo taken on the phone reaches Finder without anyone
asking. Change propagation is ~0.3 s.

The watcher lives in the extension, not the app: the extension is what must serve
`enumerateChanges`, and routing events across an XPC hop would add a failure mode
for no gain.

Everything about its shape follows from two properties of inotify:

- **It is not recursive.** Each directory needs its own watch, so watches are
  lazy — only directories someone actually visited — capped at 200 and evicted
  least-recently-visited first.
- **The per-user watch cap is unreadable.** `/proc/sys/fs/inotify/*` is denied to
  the `shell` user, so the limit is respected by staying well under any plausible
  one rather than by querying it.

Details that were each a bug first:

- **`inotifyd` refuses to start if *any* argument is missing.** One deleted
  folder left in the watch set silently kills change detection for the whole
  device, so removals prune the set — including everything beneath the removed
  directory.
- **Re-arming is debounced by 500 ms.** Restarting per directory would thrash
  while someone clicks through a tree.
- **`c` fires repeatedly during a large write; `w` fires once when it closes.**
  Acting on `c` would re-list the directory for every buffer the writer flushes.
- **Events are batched for 250 ms.** Unzipping an archive on the phone produces
  hundreds of events for one directory.
- **`o` (overflow) or `x` (unwatchable) means the kernel dropped events.** The
  incremental picture is untrustworthy, so everything watched is rescanned rather
  than trusted.
- **A stream that ran for a while and then ended is a normal reconnect**, not
  evidence of a broken device. Only short-lived failures count toward backoff,
  and a successor watcher takes over from its predecessor rather than leaving a
  gap.
- **After four consecutive failures push is abandoned** for a 15-second poll of
  the most recently visited directories. A full directory scan of the reference
  device takes 0.59 s, so polling only what the user is looking at is an
  unglamorous but credible backstop for a device without `inotifyd`.

## 5. Sync anchors

```sql
CREATE TABLE changes (
    anchor      INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id     INTEGER NOT NULL,
    kind        INTEGER NOT NULL,
    recorded_at INTEGER NOT NULL
);
```

- `currentSyncAnchor` is `MAX(anchor)`.
- `enumerateChanges(from:)` replays the rows after a given anchor.
- Rows are pruned past 24 hours or 50,000 entries, and the pruned-through anchor
  is remembered.
- A request for a pruned anchor raises `CoreError.anchorExpired`, mapped to
  `NSFileProviderError.syncAnchorExpired`, which makes the system re-enumerate
  from scratch. Correct, just slower — this is the safety valve that stops a bad
  incremental state becoming permanent corruption.
