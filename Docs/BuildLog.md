# Stower build log

The dated, engineer-facing build log for `StowerMac` — relocated verbatim from
`PLAN.md`'s "Status" section (JC5 of the 2026-07-12 Messages-access bookmark
migration plan). This is the log an agent or contributor reads to re-enter a
session without re-reading the diff (see
`AGENTS.md`'s "after each meaningful commit" rule, which now points here).
Entries are period-accurate history — never rewritten to describe a naming
scheme or architecture that didn't exist yet at the time.

## Status

- 2026-07-15: **Diagnostics consent gating — Sentry and TelemetryDeck stay off until explicit choice (branch `polly/stower-consent-gating`).**
  `DiagnosticsInstallRecord` now stores `hasExplicitChoice`; `StowerDiagnosticsConsent.isEnabled`
  returns false for fresh installs, corrupt storage, and migrated pre-`hasExplicitChoice` records
  even if they contain the old `enabled: true` default. `StowerDiagnostics.initialize()` still
  builds a no-op analytics backend so report calls are safe, but injected launch-trace tests verify
  no `SentrySDK.start`, `TelemetryDeck.initialize`, or `app_launched` emission before consent.
  The delayed `StowerAnalyticsConsentCard` remains after ~60 seconds of foreground board time, but
  now records consent only when the user taps On or Off; it no longer marks a disclosure as shown
  before choice. Explicit On starts Sentry first, then TelemetryDeck, preserving the crash-first
  ordering after consent. Docs updated in `Docs/Analytics.md`, `Docs/CrashReporting.md`, and
  `SECURITY.md`.
- 2026-07-13: **Full Disk Access replaced with App Sandbox + a security-scoped Messages bookmark (branch `fda-bookmark-spike`).**
  `StowerMac.entitlements` gains `app-sandbox`, `files.user-selected.read-only`, `network.client`,
  and Sparkle's `-spks`/`-spki` temp-exceptions; `project.pbxproj` flips `ENABLE_APP_SANDBOX` to
  `YES` (Debug + Release) — verified via `codesign -d --entitlements` on a real Debug build.
  `StowerChatDatabaseReader` drops `defaultSourceURL`; gains a bookmark-resolving production init
  (`loadMessagesAccessBookmark`/`resolveBookmark`/`onBookmarkRefreshed`) and a `#if DEBUG`
  `demoSourceURL` init. `StowerChatSnapshot`'s security scope now brackets
  `makeValidatedSnapshot`'s whole body, not just `copySource`. `StowerMessagesError`.
  `fullDiskAccessMissing` → `messagesAccessMissing`; `StowerStartupState.needsFullDiskAccess(path:)`
  → `.needsMessagesAccess` (no payload) / `.needsMessagesAccessStillMissing(detail:)`.
  New `StowerMessagesAccessPicker` (`StowerMacUI`'s 2nd public symbol, shared by the GUI app,
  `StowerCLI`, and a new `StowerChatDBInspector` executable — none persist except the GUI, which
  writes to `StowerUserDefaultsItem`). `StowerMessagesDropper` drops the synthetic ⌘V paste and
  Accessibility entirely (App Sandbox blocks `CGEventPost` outright) — "Reply in Messages" now
  only copies + opens the conversation. `Scripts/inspect-chatdb-shapes.sh` deleted, replaced by
  the compiled `stower-chatdb-inspector` (a bash script cannot host a sandbox). `precheck.sh`
  guard 6d deleted (the picker legitimately touches `FileManager`); guard 6e unchanged. Analytics
  events renamed `fda_permission_*` → `messages_access_*`. 552 tests passing (89 suites);
  `Scripts/precheck.sh` and a Debug `xcodebuild` both green. Docs swept repo-wide; `PLAN.md`'s
  dated Status log relocated verbatim to this file (JC5). Known accepted gaps logged in
  `tmp/OPEN_QUESTIONS.md`: `Docs/release-notes/0.2.0.md`'s historical FDA mention left
  unrewritten, and `SearchCommand.swift`/`StowerRetriever.swift`'s `rrfDampening` parameter is a
  pre-existing, unrelated substring match on the FDA sweep grep.
- 2026-07-09: **Debug/Release/demo Application Support isolation (PAR-61/PAR-62, PR #57) + Sparkle EdDSA key rotation (PR #58) — prepping release v0.2.2.**
  New `StowerEnvironment` (`StowerCore`) is the single compile-time source of truth for
  Debug vs. Release, replacing four stores' (`StowerDraftStore`, `StowerTriageStore`,
  `StowerInteractionEventStore`, `StowerDebtBoardProvider`) copy-pasted `"Stower"` literal
  with an `inFolder:`-parameterized entry point that validates the folder name (I11). The
  app's composition root resolves `StowerEnvironment.current.applicationSupportDirectoryName`
  once and passes it explicitly, so a Debug build's local data now lives under
  `Application Support/StowerDebug/` instead of silently sharing Release's
  `Application Support/Stower/` folder. `StowerMessagesStorageLocation` (`StowerMacUI`)
  layers on top of that (`.debug`/`.debugDemo`/`.release`) so a Debug-against-demo-data run
  no longer mixes its drafts/triage/interaction-events/reply-verdicts into the same folder as
  a Debug-against-real-data run. New precheck guard **6r** bans hardcoded
  `"Stower"`/`"StowerDebug"`/`"StowerDebugDemo"` folder-name literals outside the two files
  that own them, closing the gap where a future call site could reintroduce per-call-site
  drift. Also deleted the dead `STOWER_*` env-var override mechanism (`STOWER_CHECKOUT_URL`/
  `STOWER_STORE_ID`/`STOWER_PRODUCT_ID`/`STOWER_FEEDBACK_ENDPOINT`) from
  `StowerLicenseConfig`/`StowerFeedbackConfig` — confirmed zero real usage repo-wide — and
  unified both configs' `compiledDefault` on `StowerEnvironment`. Separately, PR #58 rotated
  the Sparkle EdDSA keypair; `StowerMac/Info.plist`'s `SUPublicEDKey` now ships
  `8URRsANNg7iLie8EzVVv5piaF0MtoBcGCmg+O6ZDzas=` — **note this is a one-way-door change per
  `Docs/Release.md`'s own P1 warning: an app already installed with the OLD public key can
  only verify updates signed with the OLD private key, so unless the CI signing secret was
  rotated in lockstep with a transition plan, existing installs may not auto-update past this
  release and will need a manual reinstall.** Docs synced in the same PRs: `Docs/Analytics.md`,
  `Docs/DataModel.md`, `Docs/Lifecycle.md`, `Docs/Release.md`, `Sources/StowerCore/README.md`,
  `CONTRIBUTING.md`. `Docs/EnvironmentVariables.md` and `Docs/licensing-contract.md` still
  described the deleted `STOWER_*` override mechanism (`effectiveConfig(allowOverrides:)`) as
  live — caught by Codex review on the docs PR (#60) and corrected in a follow-up commit here,
  not in PR #57. Release notes authored: `Docs/release-notes/0.2.2.md`, with a manual-download
  fallback line for the key-rotation risk above. `Scripts/precheck.sh` green locally (549
  tests); CI build checks green on PR #60 (the `codex` review check failed on an unrelated
  infra error — `gpt-5.6-sol` unavailable on the account, not a finding about this diff).
  Manual update-transition dogfood (`Docs/Release.md`) remains pending before tagging
  `messages-v0.2.2`.
- 2026-07-04: **Legacy diagnostics Keychain migration removed; Keychain-item APIs locked out (branch `remove-legacy-keychain-migration`, PR #54).**
  The diagnostics install record (`DiagnosticsInstallRecord`) now lives **only** in `UserDefaults`
  (`StowerDiagnosticsStorageLocation.defaultsKey`). The earlier launch-path read of a legacy Keychain item —
  meant to migrate a pre-`UserDefaults` install's record forward — raised the macOS "allow access to your
  keychain" password dialog before the first window drew and **blocked the app from opening** for
  cross-signature upgraders, so it was deleted along with all `import Security` / `SecItem*` usage from
  `Sources/StowerMacUI/Diagnostics/StowerDiagnosticsIdentity.swift` and `StowerDiagnosticsConsent.swift`.
  `StowerDiagnosticsIdentity.clientUser()` now goes straight from a missing/undecodable record to minting a
  fresh random `UUID` (the handful of pre-`UserDefaults` testers lose analytics continuity and re-toggle any
  opt-out in Settings — accepted). New precheck static guard **6q** bans Keychain-item APIs
  (`SecItem*`/`SecKeychain*`/item-query `kSec*`) in first-party Swift (`Sources/` + `StowerMac/StowerMac/`) so
  the launch-blocking read can't return; legit `Security.framework` use (`SecKey`/`SecTrust`/`SecCertificate`,
  `import Security`) stays allowed, and 6q is `awk`-based so a pure-comment mention of a banned token can't trip
  it. Docs synced from as-built code: `Docs/Analytics.md` (identity/migration section + `6q`), `Docs/Tests.md`,
  `AGENTS.md`. Tests updated across the diagnostics/analytics suites (identity, consent, gate, crash-reporting).
- 2026-07-03: **Drafts "mark as sent" resolution — soft-resolve via a persisted `resolved_at` (branch `manual-dismiss-draft`, PR #50).**
  Additive `stower-drafts-v2-resolved-at` migration adds a nullable `resolved_at` column to `drafts.sqlite`'s
  `draft` table (`NULL` = active, set = resolved; the row is **kept**, never deleted, so the resolve is
  reversible). Store API (`StowerDraftStore` + the app-owned `StowerDraftStoring`): `markSent(key:)` (additive
  `UPDATE`, never routes through `deleteRow`), `unmarkSent(key:)` (clears back to `NULL`), and `upsert` always
  writes `resolved_at = NULL` so any body edit reactivates a resolved draft. Two entry points: (1) the
  `StowerDraftComposer` two-step flow — "Reply in Messages" (drops the draft) → "Mark as sent" (resolves +
  closes the composer, D1); the button state is session-local, NOT derived from `resolvedAt`, and reverts to
  "Reply in Messages" on a further edit. (2) a one-tap `StowerDraftsList` trailing checkmark. Undo reuses the
  single `StowerDismissUndoBar` slot (new `.markedSent` kind → "Marked as sent" copy) and registers a
  `UndoManager` step so ⌘Z reverses the resolve (`handleUndoDraftResolve` → `unmarkSent`). Resolved drafts are
  filtered at all three read surfaces in the app layer (`StowerBoardViewModelDrafts`: `StowerDraftCard` list,
  composer, and `activeDraftPreview` inline preview) — `all()` returns every row; the view model excludes
  `resolvedAt != nil`. `mergeDrafts` I10 guard keeps a local resolve/undo from being reverted by a stale reload
  while that key's write is in flight (both directions). Writes serialize per-key through `enqueueDraftWrite`
  (I11); `flushAll` drains them on quit. Codex loop: 3 iterations, 6 P2 fixed. Docs synced: `Docs/DataModel.md`
  (schema + resolution semantics). New tests: `StowerBoardViewModelDraftResolveTests`,
  `StowerBoardViewModelDraftUndoTests`, plus `StowerDraftStore`/schema resolve coverage.
- 2026-07-01: **Licensing is client-only Lemon Squeezy activate-once + local 7-day trial (branch `v0-prep`, PR #41).**
  No Stower-operated server exists. As-built seam (`Sources/StowerMacUI/Startup/`): `StowerLicenseGating` →
  `StowerLemonSqueezyLicenseGate` composes `StowerLemonSqueezyClient` (the app's ONLY licensing network
  call — `POST api.lemonsqueezy.com/v1/licenses/activate`, response `meta.store_id`/`meta.product_id`
  checked against `StowerLicenseConfig` so another product's key can't unlock Stower), `StowerLicenseStore`
  (plaintext single-key `UserDefaults` record: key + `instance.id`), and `StowerTrialClock` (7-day window
  seeded from a `UserDefaults` first-launch date; `StowerTrialClock.trialDuration`). Activate once →
  licensed forever offline: no re-validation, no revocation (contract I6). Money moments:
  F1 "You're all set." alert on every successful activation path, F2 enter-key banner after checkout
  (`StowerRootView.openCheckout()` sets `boughtThisSession`), F3 buy-nudge via `StowerBoardBannerState`;
  key entry is `StowerLicenseEntryView` (paste-forgiving `normalize()`). Trial funnel analytics:
  `trial_started` / `paywall_reached` / `checkout_opened` / `activated`. Precheck `6o` pins licensing
  egress to `api.lemonsqueezy.com` and bans any residual server-backed licensing token from `Sources/`.
  Docs rewritten from the as-built code: `Docs/licensing-contract.md` v2.0, `Docs/Lifecycle.md` v2.0,
  `Docs/EnvironmentVariables.md`; `Docs/licensing.md` keeps its 30-day/per-major pricing philosophy with
  "As-built (v0)" callouts (parked business decision, `tmp/OPEN_QUESTIONS.md` G4). **Still open (release
  gate G1–G3):** `StowerLicenseConfig.production`/`.staging` ship placeholder `storeID`/`productID`/
  `checkoutURL` that fail every activation closed until the real Lemon Squeezy store exists.
- 2026-06-30: **Sentry crash reporting — crash-only, consent-gated, EU-region, PII-scrubbed (`Sources/StowerMacUI/CrashReporting/`, `Diagnostics/`).**
  New umbrella `StowerDiagnostics` facade (`public enum`) unifies crash + analytics behind one consent gate. `StowerCrashReporting` (the only `SentrySDK.start` site): all non-crash integrations disabled, EU DSN placeholder (OPS-GATED), `stop()` for mid-session opt-out. `StowerSentryScrubber`: drops non-crash events, rebuilds `exception.value` from content-free structured fields (A5), redacts `/Users/<name>/` in `frame.fileName`/`frame.package`/`debugMeta.codeFile`, backstop-drops hard-stop tokens. `StowerAnalyticsConsent` → **`StowerDiagnosticsConsent`** (keychain service strings unchanged). Precheck guards 6l (Sentry import allowlist 4 files), 6m (`options.debug` `#if DEBUG` only), 6n (no `\(` in assertion messages). 22 new Swift tests. Codex loop: 5 iterations, 4 P1/P2 fixed, 2 accepted (placeholder DSN OPS-GATED; re-enable-no-restart design constraint). **OPS-GATED before crash reports reach Sentry:** real EU DSN, dSYM upload, auth token, DPA, free-tier.
- 2026-06-29: **Anonymous funnel analytics — TelemetryDeck-backed, default-on with one-click off (`Sources/StowerMacUI/Analytics/`).**
  New app-side subsystem under `StowerMacUI`: `StowerAnalytics` (the `@MainActor` facade — public
  `initialize()` / `reportAppLaunched()` / `reportSessionEnded()`; internal `report` / `setEnabled` /
  `reconcileLicenseConsent`), `StowerAnalyticsConsent` (+ the in-memory `StowerAnalyticsKillLatch`),
  `StowerAnalyticsIdentity` (+ `StowerAnalyticsKeychainKeys` and the shared `AnalyticsInstallRecord`),
  `StowerAnalyticsEvent` (typed PII-safe taxonomy), `StowerAnalyticsReporting` (+ `StowerNoOpAnalyticsReporter`
  / `StowerInMemoryAnalyticsReporter`), `StowerTelemetryDeckReporter` (the ONLY TelemetryDeck importer —
  enforced by precheck **6k**), and `StowerAnalyticsBucket`. **Identity** = a random per-install Keychain
  `UUID` (anonymous, not hardware/IDFV/IDFA), double-hashed by TelemetryDeck (salt + SHA-256) before it
  leaves the device. **Kill switch** = never `initialize()` when consent is off (the Swift SDK has no
  `stop()`); `setEnabled(false)` also trips `StowerAnalyticsKillLatch` so every reporter fails closed in
  memory even if the Keychain write failed. **Default-on with disclosure**: the `StowerAnalyticsConsentCard`
  appears once after ~60s of foreground board time (JC7), and a Privacy pane (`StowerSettingsView` →
  `StowerPrivacySettingsView`) in a new `Settings { }` scene gives one-click off. Consent is license-scoped
  ("off wins", reconciled against `diagnostics_opt_out` on check-in, JC8). `StowerMacApp` calls
  `StowerAnalytics.initialize()` + `reportAppLaunched()` in `init`, and `reportSessionEnded()` in
  `applicationShouldTerminate` (synchronous, no `await`). `StowerStartupModel.commit` emits the startup
  funnel (`hardware_checked`, `license_gate_reached`, `fda_permission_requested`, `fda_permission_resolved`
  at `.connectedPreparingBoard` only, `board_reached`); board view models emit `board_item_clicked` /
  `feature_used`. Rationale captured in `Docs/Analytics.md`; `Docs/MacAppContract.md` updated for the new
  Settings scene + launch/quit analytics hooks.
- 2026-06-18: **Lemon Squeezy license-entry gate (activate-once, store, no recurring validate).**
  Stower is now paid from first launch. After the model-availability check and before the FDA gate,
  `StowerStartupModel` checks a new `StowerLicenseGating` seam: a stored license (`hasStoredLicense`,
  pure local `UserDefaults` read) proceeds with zero network; otherwise `.needsLicense(nil)` shows the
  new `StowerLicenseEntryView` (focused monospaced field, inline error, help row), and `submitLicense`
  runs `runActivation` under the existing generation token + shared do/catch — `.checkingLicense`
  spinner, `activate` (pure), then a generation-guarded `persistLicense` so a superseded activation
  never writes. The only network egress is `StowerLemonSqueezyClient` POSTing once to
  `/v1/licenses/activate` (percent-encoded form body; decodes `{activated, instance.id,
  meta.store_id, meta.product_id}` and requires the store/product IDs to match Stower's — a key for
  any other Lemon Squeezy product is `.invalid`; never decodes `customer_email`/`customer_name`;
  transport-throw/5xx/undecodable → `.couldNotReach`; 15s timeout). `{key, instance_id}` is
  stored plaintext in `StowerLicenseStore`; no `clear()`/`/validate` in v1 (next ticket). New states
  `.checkingLicense` / `.needsLicense(StowerLicenseGateError?)`; `StowerCheckingView` switch is now
  exhaustive (no `default:`). `StowerTrustBlock` copy owns the one call honestly. `precheck.sh` step
  6g bans logging in `StowerMacUI` (key/PII). `Scripts/precheck.sh` green. Open / config Emily must set before selling:
  `StowerLemonSqueezyLicenseGate.expectedStoreID`/`expectedProductID` are PLACEHOLDER `0`s (the
  product check fails closed — no key activates until set to the real dashboard IDs); the
  support/product URLs in `StowerLicenseEntryView` are placeholders; O2 `instance_name` is a fixed
  "Stower" label; O1 paid-vs-trial kept as paid.
- 2026-06-18: **StowerMac v1 debt-board surface (board slice).** Built the reply-debt board on the
  merged engine + onboarding slice. New app-owned `Board/` group in `StowerMacUI`: view-models
  (`StowerBoardRow`/`StowerThreadLine` — `Identifiable` by `chatID`/GUID, no confidence exposed),
  `StowerBoardModel` (+`StowerBoardDirection`), `StowerDayPreset` (7/14/28/60/90, default 7),
  `StowerLastMessageKind` mirror + the pure `StowerLastMessageSummary` non-text rule (placeholder
  italic + angle-bracketed), `StowerBoardRefreshOutcome`, the `StowerBoardDataSource` seam (untyped
  `throws`), `@MainActor @Observable` `StowerBoardViewModel` (load/refresh split, generation guard on
  load only, `isRefreshing`-guarded re-issue loop) + `StowerThreadViewModel`, and an injectable
  `StowerMessagesLinkOpener`. Three new engine-coupled files join the adapter: `StowerMessagesMapping`
  (shared maps incl. the moved `mapError`/`mapConfig`/`mapReason`/`mapAvailability`),
  `StowerLiveBoardDataSource`, and `StowerMessagesComposition` (ONE `StowerDebtBoardProvider` injected
  into both adapters). Views: `StowerBoardView` (toggle + day filter + manual refresh + preparing /
  rows / caught-up / error), `StowerNoReplyRowView`, `StowerThreadView` (bubbles + Open in Messages).
  `StowerRootView` renders the board at `.connectedPreparingBoard` via a `@State` board VM whose
  `onFailure` calls the new `StowerStartupModel.handleBoardFailure` — `StowerStartupState` gains NO
  board cases. One permitted engine change: doc-comment sweep pinning `recentMessages` "newest
  `limit`, oldest-first" across the three sibling comments + the `StowerConversationFactsReading`
  one-reader fix, plus `StowerDebtBoardThreadOrderTests` pinning the order. `precheck.sh` 6b widened
  to the four engine importers (sorted-set compare). `Scripts/precheck.sh` green (204 tests). The
  human Xcode shell wiring (Task 5 of the prior slice) is already merged.
- 2026-06-17: **StowerMac FDA-onboarding slice + judge-owned model id.** Task 0 moved the
  cache-invalidation epoch off the app surface: `StowerDebtBoardProvider` no longer takes or
  exposes `modelIdentity`, and `StowerFoundationModelReplyJudge` owns a `static modelIdentity`
  folded into `judgeVersion()` — the judge owns its prompt AND its model id; behavior unchanged
  (the verdict cache still auto-invalidates on a prompt/model change). New tested `StowerMacUI`
  library with an app-owned startup boundary the SwiftUI views never leave: `StowerStartupProviding`,
  `StowerStartupModelAvailability` / `StowerStartupModelUnavailableReason`, `StowerStartupDebtConfig`
  (`appDefault` `unansweredForDays: 3`), `StowerStartupFailure`, `StowerStartupState`, and a
  `@MainActor @Observable StowerStartupModel` with Task+generation re-entrancy (cancel-before-replace;
  `CancellationError` never routes to `.failed`). Only `StowerMessagesStartupAdapter` imports
  `StowerMessages`, mapping the seven-case `StowerMessagesError` + availability + config 1:1. FDA-first
  views (`StowerRootView` is the lone `public` symbol; FDA / model-unavailable / checking /
  connected-loading / failure) per the UI Contract, plus one isolated System Settings opener (FDA +
  Apple Intelligence panes, `guard let` + general fallback). Access-granted parks at an honest
  `.connectedPreparingBoard` loading state — the board + `refreshJudgments` lifecycle are the next
  slice. `precheck.sh` Step 6 now gates the StowerMacUI import boundary, the Messages-probe ban, and
  the app-entry imports. `Scripts/precheck.sh` green (163 tests). **Still blocked at Task 5 (human
  Xcode step): add the local package, link the `StowerMacUI` product, App Sandbox off, macOS-only,
  render `StowerRootView()`, delete `ContentView.swift`.**
- 2026-06-15: Relationship-debt engine went **FM-only and judged-only**
  (remove-heuristic-reply-judge). The heuristic judge
  (`StowerHeuristicReplyJudge`), the judge-mode concept (`StowerReplyJudgeMode` /
  `StowerDebtConfig.judgeMode`), the `.heuristic` verdict-source token, and the
  standalone reply-debt measurement CLI subcommand are deleted — there is **no
  heuristic fallback**;
  on an unsupported Mac the engine throws rather than degrading. The board is
  judged-only: a conversation reaches Neglected or Ghosted only once the on-device
  model has judged it and a trusted verdict is cached (no pending row). Both lists
  gate on the model's should-respond verdict, differing only by direction —
  `StowerNoReplyPolicy` (Neglected, counterpart-last) gates on the boolean;
  `StowerGhostedPolicy` (Ghosted, you-last) keeps an additional `ghostGateThreshold`
  confidence gate. The public row `StowerDebtItem` collapsed to display fields +
  `replyExpectationConfidence` (dropped `verdictSource`, `expectsReply`, `reason`).
  Availability is typed: `modelAvailability() async -> StowerModelAvailability`
  routes at startup, and `loadDebtBoard` throws
  `StowerMessagesError.languageModelUnavailable(reason)`
  (`StowerModelUnavailableReason`) BEFORE opening `chat.db` on an unavailable
  device. `refreshJudgments` is `async throws -> StowerRefreshSummary?` (`nil` =
  coalesced; throws `languageModelUnavailable` when unavailable); the summary
  carries `changedChatIDs`, `judgedCount`, `failedCount`, `totalCount`, and the app
  clears its cold-start loading screen at `judged + failed == total` and reloads
  when `changedChatIDs` is non-empty. Each record is judged under a per-record FM
  timeout; the judge's own `modelIdentity` epoch folds into the judge version and the
  input hash fingerprints the raw message text. `Scripts/precheck.sh` green.
- 2026-06-14: Relationship-debt engine groundwork in `StowerMessages` (feature 5).
  Two-layer, pure, reads only the local 180-day window on the existing read-only
  snapshot — index path untouched. Layer 1 is a neutral facts extractor
  (`StowerConversationState` / `StowerConversationStateExtractor`): true last act
  + `lastMessageKind` from a chronology read over all content types, recent
  reciprocity, and tapback-clearing via chat-provenance reactions with
  prefix-normalized (`p:N/`, `bp:`) target GUIDs. Layer 2 is the Neglected policy
  over those facts (`StowerNoReplyPolicy`): 1:1 → recency-gated mutuality →
  counterpart-last → not tapback-cleared → ≥ threshold, ranked
  most-recently-unanswered first. 21 new tests; `Scripts/precheck.sh` green.
  Deferred to v1.1: precise attachment kind via the `attachment`-table UTI,
  per-contact dedupe.

- 2026-06-13: Hybrid retrieval substrate + permanent `stower` CLI (feature 4).
  `StowerCore` gained: `StowerEmbeddingStore` on its own `embeddings.sqlite`
  (survives `replaceAll` and FTS schema-version erases; per-batch resumable
  upserts; safe `loadUnaligned` BLOB decode), `StowerEmbedder` (async/Sendable
  model-agnostic seam) + `StowerCoreMLEmbedder` (compile-to-`.mlmodelc` cache,
  manifest-driven pooling/prefix, post-tokenization skip), `StowerRetriever`
  (brute-force cosine over a flat vector cache + RRF, deterministic total order,
  single-sourced constants), and `StowerIndex.items(ids:)`/`count()`.
  `Scripts/convert-embedding-model.py` (PEP 723 / `uv`) converts any HF model to
  a batched Core ML package + `manifest.json` with an in-script parity check.
  New `stower` CLI: `index` (delta-embed, resumable, timed), `search` (hybrid /
  fts / semantic with per-arm provenance), `eval` (3-arm HIT/MISS over a
  gitignored pre-registered TSV, scored gate, preflight). All invariants covered
  by Swift Testing; no Core ML in unit tests (model exercised via the CLI).
  Remaining human step: convert the model, grant FDA+Contacts, run the 10-query
  gate against Messages.app on the real 180-day window.
- 2026-06-11 (later): Pre-landing review pass fixed all findings. Highlights:
  WAL recovery for the copied snapshot (a raw copy of the live WAL-mode
  `chat.db` could not be opened read-only — `PRAGMA journal_mode=DELETE` on
  the private copy now folds frames in; regression test uses a WAL fixture),
  a real balloon-message filter with a URL-preview exception (the old test
  passed only because the fixture row had no text), ingest-window filters
  pushed into SQL, `ingest` renamed to the explicit `replaceAll(with:)`,
  snapshot retry errors surfaced, and an `invalidArgument` error case.
- 2026-06-11: Implemented the Core index and Messages ingestion foundation.
  `StowerCore` now has a source-namespaced `StowerIndexedItem` contract,
  transactional GRDB 7 FTS5 external-content index, safe Porter/Unicode61
  search, weighted group-title ranking, snippets, schema-version rebuilds, and
  rank-preserving grouping. `StowerMessages` now pins Madrid 0.4.0, decodes
  attributed bodies without its lossy convenience property, resolves Contacts
  with deterministic raw-handle fallback, copies and validates a read-only
  ephemeral Source DB snapshot, filters non-message rows, and supports both the
  180-day ingest path and unbounded newest-N thread reads. Synthetic tests cover
  the architecture and edge cases. The manual FDA run, real-window timings, and
  10-query comparison against Messages.app remain a human evaluation step
  because they require the user's private data and query judgments.
- 2026-05-13: Scaffolding complete. Three library targets (StowerCore,
  StowerPhotos, StowerMessages) + guardrail governance + lint configs + CI.
  No business logic yet. Mac app shell (StowerMac) deferred to its own plan.
- 2026-06-09: Added signal-coding guardrails (PR #2). `AGENTS.md` is now the
  canonical cross-agent rule set; `CLAUDE.md` imports it via `@AGENTS.md`. Three
  project skills + a shared pattern catalog live in `.claude/skills/`, mirrored to
  `.agents/skills/` for Codex: `swift-signal-review` (notice), `swift-pattern-sweep`
  (eradicate sweep-able patterns), `harden-guardrail` (turn a recurrence into a
  gate), and `SWIFT_PATTERNS.md` (bad→good catalog). CI now runs
  `Scripts/precheck.sh` directly so the gate has one definition shared with the
  pre-commit hook. Still no business logic.
