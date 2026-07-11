# Release — Stower Distribution Pipeline

Subsystem rationale for the tag-triggered Developer ID + Sparkle release pipeline.
(The product artifact is `Stower.app` — the internal Xcode scheme/target stays
`StowerMac`; see the product-vs-internal naming split in `AGENTS.md`.)

## Overview

A `git push` of a `messages-vX.Y.Z` tag archives, Developer-ID signs, notarizes,
and staples `Stower.app`, then produces **two** distribution artifacts from it,
attaches both to a GitHub Release, and amends the Sparkle appcast at
`https://updates.stower.app/messages/appcast.xml`. An already-installed copy
discovers, EdDSA-verifies, and installs the update.

- **`Stower-<version>.zip`** — the Sparkle appcast enclosure (in-place update, no
  drag needed). This is the artifact `sign_update` signs into `appcast.xml`.
- **`Stower-<version>.dmg`** — the human-facing drag-to-Applications download the
  website "Download" button points at, so a brand-new user lands in
  `/Applications` instead of running a translocated copy from `~/Downloads`. Built
  with **`dmgbuild`** (not `create-dmg`): `dmgbuild` writes the `.DS_Store`
  directly with no Finder/AppleScript, so window styling runs headless on the GitHub
  runner. Its settings live in `Scripts/release/dmg_settings.py`; the window
  background is `Scripts/release/dmg-background.png` (the @2x, expanded to a
  multi-representation TIFF by the workflow via `sips` + `tiffutil`). The DMG is
  itself codesigned, notarized, and stapled before publish.

Two signing systems converge on the artifacts:
- **Developer ID / notarization** (Gatekeeper): `xcodebuild exportArchive` → `notarytool` → `stapler` (applied to both the `.app`, the `.zip`'s app, and the `.dmg`)
- **Sparkle EdDSA** (update integrity): `sign_update` writes a signature into `appcast.xml`

The pipeline is `macos-26` only. `macos-15` max SDK is macOS 26.2 < the 26.4
deployment target; `macos-26` default Xcode ships SDK 26.5 ≥ 26.4.

## One-time prerequisites (human, run once before first release)

### P1 — Sparkle EdDSA keypair (ONE-WAY DOOR: the highest-stakes artifact)

The EdDSA private key is the only thing that can sign a future update your users
will trust. **Losing it permanently strands every existing install** — they can
never receive another update. **Deliberately rotating it has the same
user-facing consequence as losing it**: an app already installed with the OLD
public key can only verify updates signed with the OLD private key, so a
rotation strands existing installs on their current version unless they
manually redownload (see `Docs/release-notes/0.2.2.md` for the real instance
of this and its manual-download fallback).

```bash
# Install Sparkle release tools. The Homebrew cask installs only "Sparkle Test
# App.app" — NOT generate_keys/sign_update — so fetch the distribution tarball
# (its bin/ holds the tools). Match the version to StowerMac.xcodeproj's
# Package.resolved (currently 2.9.3).
SPARKLE_VERSION=2.9.3
mkdir -p /tmp/sparkle-tools
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
  | tar -xJ -C /tmp/sparkle-tools
export PATH="/tmp/sparkle-tools/bin:$PATH"   # generate_keys, sign_update now on PATH

# Generate the keypair. generate_keys stores the private key in your login
# Keychain as an item labeled "Private key for signing Sparkle updates"
# (default account "ed25519"). The public key is printed to stdout.
generate_keys

# Back up the private key to an offline location (USB drive / printed / 1Password):
generate_keys -x ~/Desktop/sparkle_private_key_backup.txt
# Verify the backup is readable, then permanently delete the plaintext export:
rm ~/Desktop/sparkle_private_key_backup.txt

# Export for CI (paste stdout into GitHub secret SPARKLE_EDDSA_PRIVATE_KEY):
generate_keys -x /dev/stdout

# Restore drill (run at least once before the first release):
#   1. In Keychain Access, delete the item named "Private key for signing Sparkle updates".
#   2. Restore from your offline backup with: generate_keys -f <backup-file>
#   3. Confirm `sign_update --ed-key-file <backup-file> <any-file>` produces a non-empty signature.
#      (The CI workflow passes the key via --ed-key-file from the SPARKLE_EDDSA_PRIVATE_KEY secret.)
```

The public key `8URRsANNg7iLie8EzVVv5piaF0MtoBcGCmg+O6ZDzas=` is already set in
`StowerMac/Info.plist` as `SUPublicEDKey`. It ships in every build and cannot be
changed without breaking all installed copies.

Required GitHub secret: `SPARKLE_EDDSA_PRIVATE_KEY`

### P2 — Developer ID Application certificate

```bash
# In Xcode → Settings → Accounts, download "Developer ID Application" for team 2446N3925D.
# Export the certificate + private key from Keychain Access as a .p12 file.
# Base64-encode it for the GitHub secret:
base64 -i DeveloperID.p12 | pbcopy
```

Required GitHub secrets:
- `DEVELOPER_ID_CERT_P12` — base64-encoded .p12 file
- `DEVELOPER_ID_CERT_PASSWORD` — .p12 export password

### P3 — Apple ID app-specific password for notarytool

`notarytool` authenticates against the notary service with an Apple ID + an
app-specific password (not an App Store Connect API key — chosen to avoid the
App Store Connect API access-request gate and keep the credential trivially
revocable). No `.p8`, no Key ID, no Issuer ID.

```bash
# appleid.apple.com → Sign-In and Security → App-Specific Passwords → generate.
# Team ID is the Developer ID team (2446N3925D); Apple ID is the developer account email.
```

Required GitHub secrets:
- `NOTARY_APPLE_ID` — the Apple Developer account email
- `NOTARY_APP_PASSWORD` — the app-specific password (plain string, NOT base64)
- `NOTARY_TEAM_ID` — the Developer ID team ID (`2446N3925D`)

### P4 — DNS and GitHub Pages for appcast hosting

The appcast must be reachable at `https://updates.stower.app/messages/appcast.xml`.

```bash
# Add CNAME via Vercel CLI (stower.app is the Vercel apex domain):
vercel dns add stower.app updates CNAME emilykangdev.github.io

# GitHub repository settings:
#   Settings → Pages → Source: Deploy from branch → Branch: gh-pages / root
#   Custom domain: updates.stower.app
#   Enforce HTTPS: enabled (HTTPS cert can take up to 24h after DNS propagates)

# Verify (after DNS propagates):
curl -s https://updates.stower.app/messages/appcast.xml | head -5
```

### P5 — Public EdDSA key in Info.plist

Already done: `SUPublicEDKey` is set to `8URRsANNg7iLie8EzVVv5piaF0MtoBcGCmg+O6ZDzas=`
in `StowerMac/Info.plist` (`StowerUpdaterController` reads `SUFeedURL`/`SUPublicEDKey`
from the built `Info.plist`). No action needed.

### P6 — GitHub Environment hardening (JC7)

```text
GitHub repository → Settings → Environments → New environment → name: release
  → Add required reviewers (yourself for solo)
  → Add secrets: all six secrets from P1–P3 above
  → Deployment branches and tags: Selected branches and tags
      Add rule: tags matching messages-v*
      Add rule: branch main  ← required so workflow_dispatch dry-runs can access secrets
```

The `workflow_dispatch` dry-run trigger runs from a branch, not a tag. If the Environment
only allows tags, `workflow_dispatch` cannot access secrets and the dry-run silently skips
signing/notarization steps. Allow `main` (or the default branch) in addition to tags.

All secrets live in the `release` environment, not repository-level secrets.
Every Action in `release.yml` is SHA-pinned (not a moving `@vN` tag) to prevent
supply-chain poisoning of the signing/notarization/EdDSA flow.

## Release notes (authored, not auto-generated)

Each release ships human-authored notes from `Docs/release-notes/<VERSION>.md`
(one file per version — see `Docs/release-notes/README.md`). The pipeline reads
that one file and publishes it to both surfaces so they show identical content:

- **GitHub Release body** — GitHub renders the Markdown natively
  (`gh release create --notes-file`).
- **Sparkle in-app "what's new"** — `Scripts/release/render_notes_html.py`
  renders the same Markdown to `messages/notes/<VERSION>.html` on `gh-pages`;
  Sparkle loads it via `<sparkle:releaseNotesLink>`.

The "Verify authored release notes present" step runs before the archive, so a
tag push with a missing or empty notes file fails in seconds — a release can
never publish empty notes. Dry-runs (`workflow_dispatch`) skip this check
because their throwaway versions have no authored file.

## Shipping a release

```bash
# 1. Author Docs/release-notes/<VERSION>.md for the version you're tagging.
# 2. Ensure all changes are committed and CI is green.
git tag messages-v0.1.0
git push origin messages-v0.1.0
# The release.yml workflow runs automatically.

# 3. Dry-run before the first real tag (workflow_dispatch):
#    GitHub Actions → Release → Run workflow → enter version "0.1.0-dry"
#    A dry-run runs the FULL signing path — archive, export, signing gates,
#    notarize, staple, and the Gatekeeper/spctl gate — and stops before the
#    publish steps (no GitHub Release, no appcast). Apple has no "dry-run"
#    notarization: notarytool notarizes the build for real, which is the point —
#    it catches a "ships fine but can't notarize" failure before a real tag. The
#    notarized+stapled zip is simply discarded. If notarization 403s with "a
#    required agreement is missing or has expired", accept the pending Apple
#    Developer Program License Agreement at developer.apple.com (or App Store
#    Connect → Agreements) — a real release would fail identically, so a red
#    dry-run is correct signal, not a workflow bug.
```

## Manual update-transition dogfood (mandatory before promoting to users)

Before promoting any release to a wide audience, run the end-to-end update test:

1. Install the PRIOR version (download from its GitHub Release).
2. Launch it and grant any permissions.
3. Publish the NEXT version (tag push or manual workflow).
4. In the installed prior version: open Settings → check for updates, or wait for
   the automatic check interval.
5. Confirm: discovered → EdDSA-verified → downloaded → installed on next quit.
6. Relaunch and verify the new version number in About.

This is the only test that catches "ships fine but can't update" failures.

## Rollback / incident procedure

Sparkle cannot downgrade. The rollback path is always forward:

1. **Identify the bad build** — check `spctl`, crash reports, user reports.
2. **Gate the rollout** — the `sparkle:phasedRolloutInterval` limits exposure to a
   fraction of installs; a bad build does not immediately reach everyone.
3. **Ship a higher patch** — fix the issue, tag `messages-vX.Y.Z+1`, push.
   The new item's `sparkle:version` (CFBundleVersion) must be strictly greater.
4. **Amend the appcast** — the pipeline appends the new item; the pipeline asserts
   item count ≥ previous so the feed never shrinks.
5. **Revert the appcast item (not the zip)** if the bad version must be hidden:
   check out the `gh-pages` branch, remove the bad `<item>` block from
   `messages/appcast.xml`, commit and push. Users on the bad version will then
   receive the next valid item. Do NOT delete the GitHub Release asset — existing
   downloads must remain accessible.
6. **Never delete a GitHub Release asset** that was served as a Sparkle enclosure —
   an in-progress update may be downloading it.

## Invariants enforced by release.yml

| Invariant | Enforced by |
|-----------|-------------|
| App signed with Developer ID + hardened runtime | `codesign -dvvv` gate |
| Sparkle.framework signed (no --deep) | `codesign --verify --strict` on framework |
| App notarized and stapled | `notarytool --wait` + `stapler staple` |
| Gatekeeper accepts the artifact | `spctl -a -vvv` + `stapler validate` gate |
| DMG codesigned with secure timestamp | `codesign --force --timestamp` + `--verify --strict` |
| DMG notarized and stapled | `notarytool submit --wait` (status == Accepted) + `stapler staple`/`validate` |
| EdDSA signature present in appcast | `sign_update` output non-empty assertion |
| SUFeedURL correct in built Info.plist | `PlistBuddy` gate before notarization |
| SUEnableAutomaticChecks absent (consent-first) | `PlistBuddy` gate |
| CFBundleVersion strictly increases | build = (prev appcast build) + 1 |
| Appcast item count never decreases | item count assertion post-amend |
| Temp keychain deleted on job exit | `if: always()` cleanup step |
| Release ships authored notes (never empty) | `Docs/release-notes/<VERSION>.md` non-empty check before archive |
| GitHub Release + Sparkle "what's new" show the same notes | both read `Docs/release-notes/<VERSION>.md` |
| Dry-run does NOT create a GitHub Release | publish steps gate on `github.event_name == 'push'` |
| Dry-run DOES notarize + staple both artifacts (validation, no publish) | app + DMG notarize/staple/Gatekeeper run on both events; only publish gates on `push` (dry-run also uploads the DMG as a workflow artifact for layout inspection) |
