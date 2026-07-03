# Stower feedback relay (Deno Deploy)

`main.ts` receives feedback from the Stower macOS app and emails it via Resend.
It is the only place the Resend API key lives (never in the app binary).

## Deploy

1. **Resend:** verify `send.stower.app` as a sending domain (so `feedback@send.stower.app`
   can send). `emily@stower.app` (the recipient) is a Google Workspace alias → your inbox.
2. **Deno Deploy:** create a project from this dir (`deno/feedback`), entry `main.ts`.
3. **Env vars:** set three in the Deno Deploy project settings (Production context) —
   - `RESEND_API_KEY` — your Resend key.
   - `FROM` — sender, e.g. `Stower Feedback <feedback@send.stower.app>` (domain must be Resend-verified).
   - `TO` — recipient, e.g. `emily@stower.app`.
   The function fails loud (500) if any is missing. Changing sender/recipient later is just an env edit + redeploy — no code change.
4. **Deploy**, then paste the deployed URL into `StowerFeedbackConfig.production`
   (and a separate staging deploy's URL into `.staging`) on the Swift side.

## Contract

`POST` `application/json` — camelCase, matches `StowerFeedbackSubmission`:

```json
{ "message": "…", "email": "a@b.com | null", "instanceID": "… | null",
  "appVersion": "1.0 (1)", "osVersion": "macOS 15.4", "licenseStatus": "trial|paid|unlicensed" }
```

Responses: `200 {ok:true}` = delivered. `400` bad/empty/oversized message or JSON.
`405` non-POST. `413` body > 4 KB. `429` rate-limited (5/min/IP, best-effort in-memory). `500`
missing `RESEND_API_KEY`. `502` Resend rejected the send. The app treats any non-2xx
as failure and shows Retry.

## Local run

```bash
RESEND_API_KEY=… FROM="Stower Feedback <feedback@send.stower.app>" TO="emily@stower.app" \
  deno run --allow-net --allow-env main.ts
# then: curl -X POST localhost:8000 -d '{"message":"hi","appVersion":"1.0","osVersion":"macOS 15.4","licenseStatus":"trial"}'
```

## Notes / follow-ups

- **Rate limit** is best-effort in-memory (per-isolate, resets on cold start). Fine for
  v0. To make it cross-isolate: dashboard → Databases → provision Deno KV → assign to this
  app, then swap the in-memory `Map` for `Deno.openKv()` (see comment in `main.ts`). Or front
  it with Arcjet/Turnstile if abuse appears.
- **No shared-secret header** in v0 (OQ3): a client-shipped secret is extractable, so it
  buys little; the size cap + rate limit are the guard. Hook is easy to add later.
