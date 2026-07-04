# Permissions (TCC) and how to test them

Stower (the macOS app, `StowerMac`) needs two separate macOS privacy permissions,
both mediated by Apple's TCC (Transparency, Consent, and Control) subsystem. This
doc is the canonical model for how they behave and — equally important — the
**deterministic workflow for testing a permission change**, because the build/run
loop has bitten us repeatedly.

## The two permissions

| Permission | TCC service | Why Stower needs it | How it's granted |
|---|---|---|---|
| **Full Disk Access** | `kTCCServiceSystemPolicyAllFiles` | Read `~/Library/Messages/chat.db` (sandboxed off the normal API) | System Settings → Privacy & Security → **Full Disk Access** → toggle/`+` the app. The app drives the user there via `StowerFDAOnboardingView`. |
| **Contacts** | `kTCCServiceAddressBook` | Resolve raw handles (`+14155550100`) to names via `StowerContactsResolver.live()` | The app calls `CNContactStore.requestAccess(for:.contacts)`; macOS shows the system prompt; the app then appears in Privacy → **Contacts**. Driven by `StowerContactsAccessBanner` → `StowerBoardViewModel.resolveContactsAccess()`. |

App build facts that make this work (`StowerMac.xcodeproj`):
- **Not sandboxed** (`ENABLE_APP_SANDBOX = NO`) + **Hardened Runtime ON**.
- **The Contacts entitlement is REQUIRED.** Because Hardened Runtime is on, the app
  must declare `com.apple.security.personal-information.addressbook` in its
  entitlements (`StowerMac/StowerMac/StowerMac.entitlements`, wired via
  `CODE_SIGN_ENTITLEMENTS`). Without it the runtime denies `requestAccess` **before
  any prompt appears** — see "The bug that cost us hours" below. The usage string
  alone is NOT enough under Hardened Runtime.
- **`INFOPLIST_KEY_NSContactsUsageDescription`** is set on both Debug and Release,
  with `GENERATE_INFOPLIST_FILE = YES`. This supplies the prompt's text. Without the
  string `requestAccess` crashes; without the *entitlement* it throws
  `CNError Code=100 "Access Denied"` with no prompt. You need **both**.
- A bare CLI/script can never test Contacts (no Info.plist → no usage string →
  `Code=100`). Only the real signed `.app` can.

## The bug that cost us hours (read this)

**Symptom:** the board showed only phone numbers; clicking the in-app "Show names"
banner did nothing — no system prompt ever appeared — and Stower never showed up in
System Settings → Privacy → Contacts.

**Root cause:** the app had **Hardened Runtime enabled but no Contacts entitlement.**
macOS denied `CNContactStore.requestAccess(for:.contacts)` at the runtime layer,
*before* it ever reached `tccd` or showed a prompt. The call threw
`CNError Code=100 "Access Denied"`, which the production `request` closure swallows
with `try?` (correct for the degrade-to-handles contract, but it hid the cause). So:
no prompt, no `tccd` record, no list entry, no crash — a completely silent failure.

**How we found it:** temporary `os.Logger` diagnostics on the request path showed the
exact sequence — `resolveContactsAccess tapped → status notDetermined → request()
called → THREW Access Denied`. That proved the button/wiring/status were all correct
and the failure was the system call itself = a signing/entitlement rejection.

**The fix (commit):**
1. Added `StowerMac/StowerMac/StowerMac.entitlements` with
   `com.apple.security.personal-information.addressbook = true` (kept
   `com.apple.security.files.user-selected.read-only` from `ENABLE_USER_SELECTED_FILES`).
2. Set `CODE_SIGN_ENTITLEMENTS = StowerMac/StowerMac.entitlements` on both Debug and
   Release configs.
3. Reset the stale denied state once: `tccutil reset AddressBook emilykangdev.Stower`
   (a failed request had marked it `.denied`, and macOS never re-prompts a denied app).
   This intentionally targets **prod** (`emilykangdev.Stower`) — see the scoping rule below.
4. Rebuild → one click on "Show names" → prompt → Allow → **all names populate instantly.**

**`tccutil reset` scoping rule (read before running this on your own machine):** the
dev build (`StowerTest.app`, bundle id `emilykangdev.Stower.debug`) and the prod build
(`Stower.app`, bundle id `emilykangdev.Stower`) hold **separate** TCC grant rows keyed
by bundle id. Never run `tccutil reset <service>` unscoped (no bundle id) — always pass
the bundle id of the build you actually mean to reset: `emilykangdev.Stower.debug` when
clearing the dev build's grant, `emilykangdev.Stower` only when deliberately fixing prod
(as in step 3 above). An unscoped reset, or resetting the wrong id, wipes a grant you
didn't mean to touch. Relatedly: never sign the two bundle ids with different signing
identities — that would break the very isolation this split relies on (each grant's
`csreq` pins the signing identity as well as the bundle id).

**Verify the entitlement actually made it into the signed app** (the `.app`
filename follows `PRODUCT_NAME` — `StowerTest.app` for a Debug build, `Stower.app`
for Release; the internal project stays `StowerMac.xcodeproj`, see `AGENTS.md`):
```bash
codesign -d --entitlements - --xml "<path>/StowerTest.app" | plutil -p - | grep addressbook
# expect: "com.apple.security.personal-information.addressbook" => 1
```

**Two debugging traps we also hit (don't repeat):**
- `log`/`tccd` queries returned empty because **`log` resolved to a shell function**,
  not `/usr/bin/log`. Always call **`/usr/bin/log`** with an absolute path when
  querying the unified log from a tooling shell.
- We chased "stale build" for a while: the running binary lagged the source. Use
  `Scripts/run-app.sh`, which prints the binary's build time vs the last commit.

## A second bug: `requestAccess` can hang forever with no error at all

**Symptom:** "Show names" did nothing on a second machine, on a build that already
had the correct entitlement/usage-string from the fix above. No prompt, no crash, no
`Code=100` — the button just went dead permanently after one tap.

**Root cause:** `CNContactStore.requestAccess(for:.contacts)`'s completion handler
can wedge **client-side, before it ever reaches `tccd`**. Unified-log proof: the
app's `TCCAccessRequest() IPC` activity starts, but there is no XPC `SEND`, no
daemon-side `REQUEST`, no prompt, no callback — ever. This is an OS-layer failure,
not a Stower bug, but the app had no defense against it: `StowerBoardViewModel`
latched `isRequestingContacts = true` before the `await` and only cleared it in a
`defer` that runs when the `await` returns — which it never did. One wedged OS call
= a permanently dead button for the rest of the process's life, with zero user
feedback.

**Contributing factor on the dev machine that first hit this:** a stale permission
grant (from an earlier App-Translocated launch out of `~/Downloads`, an ephemeral
quarantined identity) explained why "I granted this once before" didn't carry over —
machine-state pollution, not something the app can detect or fix. `lsregister -dump`
showed 10+ stale LaunchServices registrations for the bundle ID; `tccutil reset
AddressBook <bundle-id>` plus deleting the stale copies is the recovery.

**The fix (`StowerContactsAccess.requestAccessIfNeeded`):** race `request()` against
a 10-second timeout (`requestTimeout`), implemented as a single continuation resumed
by whichever side settles first — deliberately **not** a `TaskGroup`/`async let`,
because both implicitly await every child task before returning, so "cancelling" a
wedged `request()` stuck in an uncancellable `withCheckedContinuation` would still
block forever. On timeout the call throws `StowerContactsAccessError.timedOut`,
which `resolveContactsAccess` uses to release `isRequestingContacts` and relabel the
banner "Try Again" — never Settings, since the request never reached `tccd` and
Stower was never listed there to grant. If the abandoned OS call eventually does
answer (the timeout can race genuine user deliberation on the prompt, not just the
hang), `onLateResult` reports that real decision instead of discarding it.

**Verify the timeout path without waiting 10 real seconds:** see
`StowerContactsAccessTests.timesOutWhenRequestNeverResumes` — it injects a `request`
that never resumes its continuation (modeling the exact hang) and a fast `sleep`, and
proves the call still terminates. That test would hang forever if the race ever
regresses back to a `TaskGroup`/`async let` shape.

## The non-obvious rules (each cost us a debugging loop)

1. **Contacts is request-gated, not add-able.** An app only appears in Privacy →
   Contacts *after* it has called `requestAccess`. You cannot pre-add it. If Stower
   isn't in that list, it has never successfully requested — full stop. (Confirm with
   the `tccd` log; see below.)
2. **FDA is identity+path bound; Contacts is signature bound.** Copying the `.app` to
   a new location (e.g. `/Applications`) **loses the FDA grant** and re-shows the FDA
   screen. Don't move the bundle between test runs — run it where it was built.
3. **A permission can only be exercised by a real `.app` bundle.** A command-line tool
   has no `Info.plist`/usage string → `requestAccess` returns `Code=100`, no prompt.
   So "validate the resolver from a script" is impossible for the TCC half; validate
   the *matching logic* with unit tests (synthetic mappings) and the *grant + live
   enumeration* only through the running app.
4. **`StowerContactsResolver.live()` enumerates only when `authorizationStatus ==
   .authorized`.** Any other status (incl. `.notDetermined`/`.denied`) returns an
   empty resolver and `displayName(for:)` falls back to the raw handle. So "all rows
   are numbers" almost always means *not authorized*, not *bad matching*.
5. **`.limited` does not exist on macOS.** `CNAuthorizationStatus.limited` is iOS-18+
   only (`'limited' is unavailable in macOS`, compiler-confirmed). macOS grants are
   full or denied; `default → .denied` in `StowerContactsAccess.authorization` is
   correct.
6. **Build staleness is the silent killer.** The binary in DerivedData can lag the
   source by a long time. "I'm not seeing your changes" was, every time, a binary
   compiled before the change. **Always verify the binary's mtime against your last
   edit/commit before concluding anything about behavior.**

## Deterministic build-and-run workflow

Use `Scripts/run-app.sh` (below) — never eyeball it. It rebuilds, prints the binary
timestamp, and launches *that exact* binary standalone:

```bash
./Scripts/run-app.sh
```

It does:
1. `xcodebuild -project StowerMac/StowerMac.xcodeproj -scheme StowerMac -configuration Debug build`
2. Prints the built binary's mtime (so you can confirm it's newer than your last edit).
3. `open`s the DerivedData `Debug/StowerTest.app` (launchd, not under Xcode's
   debugger — avoids TCC attribution quirks).

Then, in the app:
1. If the **Full Disk Access** screen shows, grant it and "Check Again" → the board.
2. On the board, click **Show names** in the banner.
3. **Allow** the Contacts prompt → rows flip to names; Stower now appears in
   Privacy → Contacts.

## Verifying a permission actually fired (no guessing)

```bash
# Did tccd see a Contacts request from the app? (empty = it never asked)
/usr/bin/log show --last 10m --predicate 'process == "tccd"' --info | grep -iE "StowerTest|AddressBook"

# Which binary is actually running, and when was it built?
for pid in $(pgrep -x StowerTest); do ps -o comm= -p "$pid"; done
```

If `tccd` shows the request and the prompt appeared, the wiring works. If it shows
nothing after you clicked "Show names", the app didn't reach the request — re-check
that you're on the board (phase `.rows`) and running a banner build (mtime ≥ the
banner commit).

## Pointers

- `Sources/StowerMacUI/Board/StowerContactsAccess.swift` — the injectable TCC wrapper.
- `Sources/StowerMacUI/Board/StowerContactsResolver` is in `StowerMessages`
  (`Sources/StowerMessages/StowerContactsResolver.swift`); `.live()` is the gated
  enumerator.
- `Sources/StowerMacUI/Views/StowerContactsAccessBanner.swift` — the durable banner.
- `Sources/StowerMacUI/Board/StowerBoardViewModel.swift` — `resolveContactsAccess()`,
  `onAppBecameActive()` (reconciles a Settings change on app re-activation).
