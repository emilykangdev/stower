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
const MAX_BODY_BYTES = 4096; // hard size cap — abuse/cost guard
const MAX_MESSAGE_CHARS = 5000; // mirrors the client-side cap
const RATE_LIMIT = 5; // sends per IP per rolling minute (best-effort)
const RATE_WINDOW_MS = 60_000;

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

  const raw = await req.text();
  if (raw.length > MAX_BODY_BYTES) return json(413, { error: "too large" });

  let body: Record<string, unknown>;
  try {
    body = JSON.parse(raw);
  } catch {
    return json(400, { error: "invalid json" });
  }

  const message = typeof body.message === "string" ? body.message.trim() : "";
  if (!message || message.length > MAX_MESSAGE_CHARS) {
    return json(400, { error: "invalid message" });
  }

  const email = typeof body.email === "string" && body.email.length > 0 ? body.email : null;
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
      ...(email ? { reply_to: email } : {}),
    }),
  });

  if (!res.ok) return json(502, { error: "send failed" });
  return json(200, { ok: true, build: "env-v2" });
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
