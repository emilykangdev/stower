# Release — StowerMac Distribution Pipeline

Subsystem rationale for the tag-triggered Developer ID + Sparkle release pipeline.

## Overview

A `git push` of a `messages-vX.Y.Z` tag archives, Developer-ID signs, notarizes,
and staples `StowerMac.app`, attaches the resulting zip to a GitHub Release, and
amends the Sparkle appcast at `https://updates.stower.app/messages/appcast.xml`.
An already-installed copy discovers, EdDSA-verifies, and installs the update.

Two signing systems converge on one artifact:
- **Developer ID / notarization** (Gatekeeper): `xcodebuild exportArchive` → `notarytool` → `stapler`
- **Sparkle EdDSA** (update integrity): `sign_update` writes a signature into `appcast.xml`

The pipeline is `macos-26` only. `macos-15` max SDK is macOS 26.2 < the 26.4
deployment target; `macos-26` default Xcode ships SDK 26.5 ≥ 26.4.

## One-time prerequisites (human, run once before first release)

### P1 — Sparkle EdDSA keypair (ONE-WAY DOOR: the highest-stakes artifact)

The EdDSA private key is the only thing that can sign a future update your users
will trust. **Losing it permanently strands every existing install** — they can
never receive another update.

```bash
# Install Sparkle release tools
brew install --cask sparkle

# Generate the keypair. The private key is stored in your login Keychain
# under the account "Stower". The public key is printed to stdout.
generate_keys

# Back up the private key to an offline location (USB drive / printed / 1Password):
generate_keys -x ~/Desktop/sparkle_private_key_backup.txt
# Verify the backup is readable, then permanently delete the plaintext export:
rm ~/Desktop/sparkle_private_key_backup.txt

# Export for CI (paste stdout into GitHub secret SPARKLE_EDDSA_PRIVATE_KEY):
generate_keys -x /dev/stdout

# Restore drill (run at least once before the first release):
#   1. Delete the Keychain item "Stower" in Keychain Access.
#   2. Restore from your offline backup with: generate_keys --import <backup-file>
#   3. Confirm `sign_update --ed-key-file <backup-file> <any-file>` produces a non-empty signature.
#      (The CI workflow passes the key via --ed-key-file from the SPARKLE_EDDSA_PRIVATE_KEY secret.)
```

The public key `8Nq8KadFjHjsmYuH6XPxC/QXW8kUhAkICj3Gfsw97ZM=` is already set in
`project.pbxproj` as `INFOPLIST_KEY_SUPublicEDKey`. It ships in every build and
cannot be changed without breaking all installed copies.

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

### P3 — App Store Connect API key for notarytool

```bash
# App Store Connect → Users and Access → Integrations → App Store Connect API
# Create a key with Developer role. Download the .p8 file (one-time download).
base64 -i AuthKey_<KeyID>.p8 | pbcopy
```

Required GitHub secrets:
- `NOTARY_API_KEY_P8` — base64-encoded .p8 file
- `NOTARY_KEY_ID` — the Key ID (10-character string)
- `NOTARY_ISSUER_ID` — the Issuer ID (UUID from App Store Connect)

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

### P5 — Public EdDSA key in project.pbxproj

Already done: `INFOPLIST_KEY_SUPublicEDKey = 8Nq8KadFjHjsmYuH6XPxC/QXW8kUhAkICj3Gfsw97ZM=`
is set in both Debug and Release configs in `project.pbxproj`. No action needed.

### P6 — GitHub Environment hardening (JC7)

```
GitHub repository → Settings → Environments → New environment → name: release
  → Add required reviewers (yourself for solo)
  → Add secrets: all five secrets from P1–P3 above
  → Restrict to: tags matching messages-v*
```

All secrets live in the `release` environment, not repository-level secrets.
Every Action in `release.yml` is SHA-pinned (not a moving `@vN` tag) to prevent
supply-chain poisoning of the signing/notarization/EdDSA flow.

## Shipping a release

```bash
# 1. Ensure all changes are committed and CI is green.
git tag messages-v0.1.0
git push origin messages-v0.1.0
# The release.yml workflow runs automatically.

# 2. Dry-run before the first real tag (workflow_dispatch):
#    GitHub Actions → Release → Run workflow → enter version "0.1.0-dry"
#    Confirm the workflow reaches the staple/spctl gate without creating a Release.
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
| EdDSA signature present in appcast | `sign_update` output non-empty assertion |
| SUFeedURL correct in built Info.plist | `PlistBuddy` gate before notarization |
| SUEnableAutomaticChecks absent (consent-first) | `PlistBuddy` gate |
| CFBundleVersion strictly increases | build = (prev appcast build) + 1 |
| Appcast item count never decreases | item count assertion post-amend |
| Temp keychain deleted on job exit | `if: always()` cleanup step |
| Dry-run does NOT create a GitHub Release | gate on `github.ref_type == 'tag'` |
