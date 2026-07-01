# Feedback

## Why

An in-app **Send Feedback…** sheet so any user — trial or paid — can tell Emily
what's working or broken without leaving the app or finding an email address. The
draft is POSTed to a Supabase Edge Function route that forwards it to Emily
server-side (via Resend); the app only needs the accept acknowledgement. The whole
subsystem lives in `Sources/StowerMacUI/Feedback/` plus its one view
(`Sources/StowerMacUI/Views/StowerFeedbackView.swift`), sits above the
engine-adapter wall (`MacAppContract.md` §9), and imports no engine module.

## Egress surface

This is the app's **second** online edge, alongside licensing. Both point at the
same Supabase Edge Function deployment (see [Lifecycle.md](Lifecycle.md) §3):

- **License** route — `…/functions/v1/license` (mint / check-in).
- **Feedback** route — `…/functions/v1/feedback` (this subsystem).

`StowerFeedbackClient` (`Sources/StowerMacUI/Feedback/StowerFeedbackClient.swift`)
takes a `functionBaseURL` (the `…/functions/v1` base, no trailing slash) and appends
`/feedback`. It is modeled on the licensing mint client: an injectable `Transport`
typealias (`URLSession.shared` in production, a spy in tests), a header-less JSON
POST — **no `Authorization` header**, because the function is deployed
`--no-verify-jwt` — a 15s timeout, and a 2xx-wide accept range. The client holds no
process globals; `functionBaseURL` is injected so the type is unit-testable with no
config or bundle access.

The base URL is `StowerLicenseConfig.feedbackBaseURL` (public value #4 in
[EnvironmentVariables.md](EnvironmentVariables.md) §3, override
`STOWER_FEEDBACK_BASE_URL` in DEBUG only). Staging points at the test Supabase ref;
production shares the license function's ref.

## Payload contract (PII-minimal by construction)

The POST body is a `StowerFeedbackDraft` whose hand-written `encode(to:)` emits only
non-nil, non-secret fields:

| Field | Source | Notes |
|-------|--------|-------|
| `text` | the sheet's text editor | never blank (guarded by `canSend`); soft-capped at `StowerFeedbackFormModel.maxTextLength` = 5000 chars |
| `appVersion` | `Bundle.main` (`CFBundleShortVersionString` + `CFBundleVersion`) | e.g. `"1.0 (42)"`; falls back to `"unknown"`/`"?"` rather than force-unwrapping |
| `licenseID` | `StowerLicenseGating.currentLicenseID()` | the Keygen license **resource id**, `nil` for anonymous sends — omitted from JSON entirely when nil (never `null`/`""`) |
| `email` | the sheet's optional email field | `nil` when blank/whitespace-only (`email.nilIfBlank`) — omitted from JSON when nil |

The **secret** `licenseKey` is structurally absent from `StowerFeedbackDraft` — it
cannot appear in the encoded output. `licenseID` is the resource id, not the key.
`currentLicenseID()` is a pure local read on `StowerLicenseGating` /
`StowerLicenseGate` / `StowerStartupModel` that returns non-nil for **both trial and
paid** leases; `trialBadge()?.licenseID` must NOT be used as a substitute because
paid leases have a nil badge but a non-nil id.

The coarse failure type `StowerFeedbackFailure` (`badURL` / `encodeFailure` /
`transport` / `httpStatus(Int)`) carries no URL, body text, or user data — only a
structural cause. It is deliberately separate from the licensing
`StowerLicenseUnreachableReason` so feedback semantics never leak into licensing
error copy or analytics.

## UI surface

- **Entry point.** The board toolbar gear menu (`StowerBoardView.licenseMenu`,
  `StowerBoardViewTriage.swift`) always contains **"Send Feedback…"** in its own
  divider-separated section, so both trial and paid users can reach it. The gear is
  now **always enabled** — previously it disabled for paid/no-trial users; it always
  holds at least the feedback item now.
- **Model.** `StowerFeedbackFormModel` (`@MainActor @Observable`,
  `Identifiable`) owns all mutable state (`text`, `email`, `isSending`,
  `errorMessage`, `didSend`) and the `send()` action; the `onSubmit` closure is
  injected so the send path is unit-testable without SwiftUI or network. It is held
  as `@State` on the board and driven via `.sheet(item:)`, so the sheet never renders
  with a nil model and board re-renders don't erase typed text.
- **View.** `StowerFeedbackView` is a thin renderer over the model — text editor with
  char counter, optional email field, a disclosure line ("Sent with your license ID
  so Emily can reply.") shown only when `licenseID != nil`, retryable error copy, and
  a Send button gated on `canSend`. `canSend` also blocks a second POST once
  `didSend` is set, closing the window between `.sent` and sheet dismissal.
- **Confirmation.** On success the board shows a brief bottom-edge capsule ("Thanks
  for the feedback! Emily reads every one."). Its dwell clock lives in the overlay's
  `.task(id:)`, keyed on a monotonic `feedbackConfirmationToken`, and the capsule is
  suppressed while `model.undoBar` is active so it never stacks over the recoverable
  Undo button.

## Wiring

`StowerRootView` builds the `StowerFeedbackClient` once at init from
`StowerLicenseConfig.resolved.feedbackBaseURL`, reads `appVersion` nil-safely from
`Bundle.main`, and passes `onSendFeedback`, `feedbackLicenseID`
(`model.currentLicenseID()`), and `feedbackAppVersion` down to `StowerBoardView` —
modeling the existing `onBuy` closure seam.

## What's out of scope

- **No reply-sending.** This is app→server feedback only; it does not touch Messages
  or any send path (`AGENTS.md`).
- **No consent gate.** Unlike analytics/crash-reporting, feedback is user-initiated
  per submission — there is no background emission to gate.
