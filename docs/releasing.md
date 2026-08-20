# Releasing

Maintainer-facing. A signed, notarized release needs a Developer ID certificate
and a notarization credential, so contributors cannot produce one — and do not
need to. Everything below `make release` is automated and verified.

```sh
make preflight    # reports what is present, what is missing, the exact next
                  # action — and changes nothing
```

## Identifiers

| | |
|---|---|
| Team ID | `NU2JM39S5P` |
| App bundle ID | `dev.afridi.sideport` |
| Extension bundle ID | `dev.afridi.sideport.FileProvider` |
| App Group | `NU2JM39S5P.dev.afridi.sideport` |

The team ID is the `OU` field of the certificate. The other identifier that
appears in a certificate's *name* is the personal one — this was misread once,
and the distinction matters because the App Group prefix and the export options
both depend on it.

## One-time setup

### 1. Developer ID Application certificate

Only the team's **Account Holder** can create one; Admins cannot. Check the role
at [developer.apple.com/account](https://developer.apple.com/account) ▸
Membership details.

Xcode ▸ Settings ▸ Accounts ▸ select the team ▸ **Manage Certificates…** ▸ **+** ▸
**Developer ID Application**. It lands in the login keychain. If Xcode refuses:
the portal path is Certificates ▸ **+** ▸ Developer ID Application ▸ profile type
**G2 Sub-CA** ▸ upload a CSR from Keychain Access.

**Back it up immediately.** Export the certificate *with its private key* as a
`.p12`. Apple allows a limited number of Developer ID certificates per team and
they cannot be re-downloaded with the key.

### 2. Notarization credential

An App Store Connect API key beats an app-specific password: it does not expire
when the Apple ID password changes, and it is scoped.

[appstoreconnect.apple.com](https://appstoreconnect.apple.com) ▸ Users and Access
▸ **Integrations** ▸ Team Keys ▸ **+**, access **Developer**. Download the `.p8`
— **you get exactly one download** — and note the Key ID and the Issuer ID.

```sh
xcrun notarytool store-credentials sideport-notary \
  --key ~/private_keys/AuthKey_<KEYID>.p8 \
  --key-id <KEYID> \
  --issuer <ISSUER-UUID>
```

`make preflight` should now be all green. The profile name is overridable with
`NOTARY_PROFILE`.

## Releasing

```sh
make release
```

[`scripts/release.sh`](../scripts/release.sh) regenerates the project, runs the
tests, archives Release, and exports with Developer ID. Then it **verifies rather
than assumes**, because each of these looks like success right up until a user on
another Mac double-clicks the thing:

- the nested extension is signed — it is signed separately, and when that fails
  the app still launches, only the device mount never appears
- neither binary carries `get-task-allow` — Xcode injects it for development
  signing, and notarization rejects it
- both are hardened
- codesign is judged by what it *says*, not by its exit status

Then it builds and signs the DMG, notarizes it, **staples** the ticket, and runs
a final `spctl` assessment the way a first-time user's Mac would. On rejection it
prints the notarization log rather than a bare status.

### The disk image

[`scripts/make-dmg.sh`](../scripts/make-dmg.sh) packages the app, and both
`make release` and `make dmg` go through it. There is no installer here, so the
drag *is* the install and the window has to say so without instructions: the app
and an `/Applications` symlink on two panels, an arrow between them, and a
background drawn from the icon's own palette by
[`scripts/make-dmg-background.swift`](../scripts/make-dmg-background.swift). The
volume takes the app's compiled `AppIcon.icns` as its icon.

Two things about that are worth knowing before changing it:

- **Finder writes the layout, so Finder has to be driven.** An icon view's
  arrangement lives in the volume's `.DS_Store`, which only Finder can write,
  which means AppleScript and a mounted read/write image that is compressed
  afterwards. A machine that has not granted the terminal control of Finder
  (System Settings → Privacy & Security → Automation) cannot do this; the script
  warns and ships an unstyled image rather than failing the release.
- **The panels are deliberately mid-toned.** Finder draws icon labels in black
  under a light appearance and white under a dark one, on top of whatever the
  background says, so anything tuned for one appearance is illegible in the
  other. At the value used both land near 4.5:1.

### The first archive

Automatic signing registers the two App IDs and the App Group in the portal and
creates Developer ID provisioning profiles. That is expected: both bundles carry
the App Group entitlement, which is what requires profiles for Developer ID
distribution. If the export fails complaining about profiles, open the project in
Xcode once, let it resolve them, and re-run.

## Releasing from CI

[`.github/workflows/release.yml`](../.github/workflows/release.yml) runs the same
`make release` on a GitHub runner and publishes the DMG to a GitHub release. It
is **manual** — Actions ▸ Release ▸ *Run workflow* — and takes the tag to create.
A tag-push trigger is written out and commented above it, ready to enable once
the workflow has been watched succeed.

Two guards run before anything is built, because both failures are expensive to
undo once a release is public: the tag must match `MARKETING_VERSION` in
[`project.yml`](../project.yml), and a release for that tag must not already
exist. The release is created as a **draft** unless the *draft* input is set to
false, so the notes can be written before anyone can download it.

### Versioning

`MARKETING_VERSION` in [`project.yml`](../project.yml) is the single source: it
becomes `CFBundleShortVersionString` for both bundles, and the tag must be that
string with a `v` in front. Betas carry a semver prerelease suffix —
`0.1.0-beta.1`, tagged `v0.1.0-beta.1` — and the workflow turns any tag
containing a hyphen into a GitHub pre-release.

That has one consequence worth knowing: GitHub keeps pre-releases out of
`/releases/latest`, so while only betas exist that URL resolves to nothing. The
README therefore links to the releases page instead. Point it back at
`/releases/latest` when the first non-beta ships.

A non-numeric `CFBundleShortVersionString` would fail App Store validation.
Nothing in Developer ID distribution parses it — not notarization, not
Gatekeeper — so the suffix is safe here and would not be for an App Store build.

### What a runner does not have

A maintainer's Mac carries the credentials in its keychain. A runner has no
keychain, no Xcode account, and cannot hold a `notarytool` profile, so one App
Store Connect API key stands in for both roles: it authenticates `xcodebuild`,
which otherwise has no account to fetch the Developer ID provisioning profiles
with and fails at the archive, and it authenticates `notarytool`. `release.sh`
switches to it whenever `ASC_KEY_PATH` is set and is otherwise unchanged, so the
local path still uses the keychain profile.

The certificate is imported into a throwaway keychain that is unlocked with a
password valid only for that run and deleted afterwards. `set-key-partition-list`
is what stops `codesign` from waiting on a GUI confirmation nobody is there to
give — without it the job hangs to its timeout instead of failing with a reason.

### Repository secrets

Settings ▸ Secrets and variables ▸ Actions:

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_CERT_P12` | The Developer ID Application certificate *with its private key*, exported as `.p12` and base64-encoded |
| `DEVELOPER_ID_CERT_PASSWORD` | The password set when exporting that `.p12` |
| `ASC_KEY_P8` | The App Store Connect `.p8` key, base64-encoded |
| `ASC_KEY_ID` | Its Key ID |
| `ASC_ISSUER_ID` | The Issuer ID, from the same page |

Both files are base64-encoded because a secret is a single-line string:

```sh
base64 -i DeveloperID.p12 | pbcopy
base64 -i ~/private_keys/AuthKey_<KEYID>.p8 | pbcopy
```

The `.p8` needs the **Developer** role, the same key described under
[Notarization credential](#2-notarization-credential). Nothing here is a second
set of credentials — it is the same certificate and the same key the local
release already uses.

### The DMG comes out unstyled

The window layout is written by Finder, and a runner cannot drive Finder.
`make-dmg.sh` warns and ships an unstyled image rather than failing, so what CI
publishes is correct, signed, notarized and installable — but without the two
panels, the arrow and the background. A styled image still has to come from
`make release` on a real Mac, and can be uploaded to the draft release in place
of the built one.

## Local builds

```sh
make dmg
```

[`scripts/build-local-dmg.sh`](../scripts/build-local-dmg.sh) builds a real
Release DMG signed with whatever identity this Mac has. It is **not
distributable** — without a Developer ID certificate it cannot be notarized, so
Gatekeeper will refuse it on any Mac that did not build it. It is still the
genuine Release configuration, which makes it the right way to test what the
release build does differently from Debug.
