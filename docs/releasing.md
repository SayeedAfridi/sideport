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
| App bundle ID | `dev.afridi.finderadb` |
| Extension bundle ID | `dev.afridi.finderadb.FileProvider` |
| App Group | `NU2JM39S5P.dev.afridi.finderadb` |

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
xcrun notarytool store-credentials finderadb-notary \
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

### The first archive

Automatic signing registers the two App IDs and the App Group in the portal and
creates Developer ID provisioning profiles. That is expected: both bundles carry
the App Group entitlement, which is what requires profiles for Developer ID
distribution. If the export fails complaining about profiles, open the project in
Xcode once, let it resolve them, and re-run.

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
