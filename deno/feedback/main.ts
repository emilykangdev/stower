// Stower feedback relay — Deno Deploy edge function.
//
// The macOS app POSTs feedback here; this function holds the Resend API key
// (NEVER shipped in the app binary) and emails FROM → TO via Resend. It is the
// ONLY place the Resend key exists.
//
// Deploy: set three env vars in Deno Deploy — RESEND_API_KEY, FROM
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
// Hard size cap — abuse/cost guard. Must exceed the worst-case encoded payload
// for a MAX_MESSAGE_CHARS message: 5000 chars can be up to 4 bytes each in UTF-8,
// plus JSON escaping and the small metadata fields — so a legit max-length message
// never bounces with 413 (which the client would surface as a false "couldn't send").
const MAX_BODY_BYTES = 32_768;
const MAX_MESSAGE_CHARS = 5000; // mirrors the client-side cap
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

  let body: Record<string, unknown>;
  try {
    body = JSON.parse(raw);
  } catch {
    return json(400, { error: "invalid json" });
  }

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

  if (!res.ok) return json(502, { error: "send failed" });
  return json(200, { ok: true, build: "env-v2" });
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
