// Stower feedback relay — Deno Deploy edge function.
//
// The macOS app POSTs feedback here; this function holds the Resend API key
// (NEVER shipped in the app binary) and emails FROM → TO via Resend. It is the
// ONLY place the Resend key exists.
//
// Deploy: repo linked in Deno Deploy dashboard (Option A — webhook, no workflow
// file). Entrypoint set in deno.jsonc at deno/feedback/main.ts. Every push to
// main triggers a deploy automatically.
//
// Env vars (set in Deno Deploy dashboard — Production context): RESEND_API_KEY, FROM
// (e.g. "Stower Feedback <feedback@send.stower.app>"), and TO
// (e.g. "emily@stower.app") — verify the `send.stower.app` sending domain in
// Resend, deploy, then paste the deployed URL into StowerFeedbackConfig (prod +
// staging). Changing the sender/recipient is an env-var edit, no code change.
//
// Contract (must match StowerFeedbackSubmission on the Swift side — camelCase):
//   POST application/json
//   { message: string, email?: string|null, instanceID?: string|null,
//     appVersion: string, osVersion: string, licenseStatus: string }
//   → 200 {ok:true} on delivery; any non-2xx = failure (app shows Retry).

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const FROM = Deno.env.get("FROM"); // e.g. "Stower Feedback <feedback@send.stower.app>"
const TO = Deno.env.get("TO"); // e.g. "emily@stower.app"
// Hard body-size bound — a MEMORY/DoS guard, NOT the message-content limit.
// Content is capped by grapheme count (MAX_MESSAGE_CHARS) below, which mirrors the
// Swift client. This bound is set generously so a legit 5000-grapheme message
// never 413s even when its graphemes are byte-heavy (4-byte scalars, long ZWJ
// emoji sequences); 256 KB still bounds memory for the streaming read. A false 413
// would surface in the app as "couldn't send," so the two caps must not disagree
// on realistic input.
const MAX_BODY_BYTES = 262_144;
const MAX_MESSAGE_CHARS = 5000; // grapheme cap; mirrors the Swift client's String.count
const RATE_LIMIT = 5; // sends per IP per rolling minute (best-effort)
const RATE_WINDOW_MS = 60_000;
// A deliberately loose sanity check (not RFC-perfect): non-space, one @, a dotted
// domain. Just enough to keep a clearly-malformed reply address out of Resend's
// reply_to so a typo can't fail the whole send.
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Best-effort in-memory per-IP limiter: per-isolate, resets on cold start.
// Good enough for a low-traffic v0. To make it cross-isolate, provision a Deno KV
// database (dashboard → Databases → Deno KV → assign to this app) and swap this
// Map for `Deno.openKv()` get/set on ["feedback-rate", ip].
const hits = new Map<string, number[]>();

Deno.serve((req: Request): Promise<Response> => handle(req));

async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "POST only" });
  // Fail loud if any required env var is missing (RESEND_API_KEY / FROM / TO).
  if (!RESEND_API_KEY || !FROM || !TO) return json(500, { error: "server misconfigured" });

  const ip = req.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? "unknown";
  const now = Date.now();
  const recent = (hits.get(ip) ?? []).filter((t) => now - t < RATE_WINDOW_MS);
  if (recent.length >= RATE_LIMIT) return json(429, { error: "rate limited" });
  recent.push(now);
  hits.set(ip, recent);

  // Read the body as a byte-counting stream and abort the moment it exceeds
  // MAX_BODY_BYTES — so a request WITHOUT (or lying about) Content-Length can't
  // force us to buffer an unbounded payload into memory before we'd reject it.
  const raw = await readCapped(req, MAX_BODY_BYTES);
  if (raw === null) return json(413, { error: "too large" });

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return json(400, { error: "invalid json" });
  }
  // JSON.parse succeeds for non-object literals (`null`, `42`, `"x"`, `[]`) too;
  // reading `.message` off those (esp. `null`) would throw and surface as an
  // uncaught 500 instead of the documented 400. Require a plain object first.
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return json(400, { error: "invalid json" });
  }
  const body = parsed as Record<string, unknown>;

  const message = typeof body.message === "string" ? body.message.trim() : "";
  // Count graphemes, not UTF-16 code units: the Swift client caps on
  // `String.count` (extended grapheme clusters), so a 5000-emoji message the app
  // accepts must not be rejected here just because `.length` double-counts each
  // surrogate pair. The 32 KB body cap is the real abuse guard.
  if (!message || graphemeCount(message) > MAX_MESSAGE_CHARS) {
    return json(400, { error: "invalid message" });
  }

  const email = typeof body.email === "string" && body.email.length > 0 ? body.email : null;
  // Only set Resend reply_to when the address looks valid — a typo'd email must
  // NOT make otherwise-good feedback fail with a 502 (which the app shows as
  // "couldn't send"). The message body still records whatever was typed.
  const replyTo = email && EMAIL_PATTERN.test(email) ? email : null;
  const status = str(body.licenseStatus, "unknown");
  const version = str(body.appVersion, "unknown");

  const text = [
    `Message:\n${message}`,
    ``,
    `Reply email:    ${email ?? "(none given)"}`,
    `License status: ${status}`,
    `Instance ID:    ${str(body.instanceID, "(none — trial/unlicensed)")}`,
    `App version:    ${version}`,
    `OS version:     ${str(body.osVersion, "unknown")}`,
  ].join("\n");

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
      // Resend requires a User-Agent header (rejects with 403 if missing).
      "User-Agent": "StowerFeedback/1.0",
    },
    body: JSON.stringify({
      from: FROM,
      to: TO,
      // Timestamped subject so each submission is its own email thread (Gmail
      // threads by identical subject). UTC, second precision so near-simultaneous
      // submissions don't collide into one thread.
      subject: `Stower feedback ${new Date().toISOString().slice(0, 19).replace("T", " ")} — ${status}`,
      text,
      ...(replyTo ? { reply_to: replyTo } : {}),
    }),
  });

  if (!res.ok) {
    const bodyText = await res.text().catch(() => "");
    return json(502, { error: "send failed", resendStatus: res.status, resendBody: bodyText.slice(0, 200) });
  }
  return json(200, { ok: true, build: "env-v3" });
}

// Reads the request body, aborting (returns null) as soon as it exceeds `cap`
// bytes — bounding memory for a body with a missing or dishonest Content-Length.
async function readCapped(req: Request, cap: number): Promise<string | null> {
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > cap) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(merged);
}

// Counts extended grapheme clusters, matching Swift's `String.count`, so the
// relay's message-length check agrees with the client cap. Falls back to
// `.length` on a runtime without Intl.Segmenter (Deno Deploy has it).
function graphemeCount(text: string): number {
  if (typeof Intl !== "undefined" && "Segmenter" in Intl) {
    const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
    let count = 0;
    for (const _ of segmenter.segment(text)) count++;
    return count;
  }
  return text.length;
}

function str(value: unknown, fallback: string): string {
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

function json(status: number, obj: unknown): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
