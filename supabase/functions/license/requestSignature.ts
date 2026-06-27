// Per-license request-signature verifier (JC5). Check-in carries its auth in
// HTTP headers (NOT the body — a body-embedded signature is circular: you can't
// re-serialize the body canonically to re-hash it), signed with the license's own
// secret key. The signed message commits to a hash of the raw body, so the body
// can't be swapped under a captured signature. Implemented with Web Crypto
// (`crypto.subtle`), matching `verifyLemonSqueezySignature` — never `node:crypto`.
//
// Signed message (LF-separated):
//   {METHOD}\n{path}\n{timestamp}\n{nonce}\n{sha256hex(rawBody)}
// where METHOD is upper-case, `path` has a leading slash and NO query string, the
// timestamp is unix seconds, and an empty body hashes as sha256hex(""). The
// signature is lower-case hex of HMAC-SHA256(key = keygen_license_key, message).
//
// Pure + clock-injected so the Deno tests need no network or wall clock. Secrets
// (the key, the body, the full signature) never appear in the returned diagnostic.

/** The `X-Stower-*` auth headers carried on a signed request. */
export const STOWER_TIMESTAMP_HEADER = "X-Stower-Timestamp";
export const STOWER_NONCE_HEADER = "X-Stower-Nonce";
export const STOWER_SIGNATURE_HEADER = "X-Stower-Signature";

/** Replay window: reject a request whose timestamp is more than this from now. */
const MAX_CLOCK_SKEW_SECONDS = 120;
/** How many leading nonce chars the (non-secret) diagnostic may echo. */
const NONCE_DIAGNOSTIC_PREFIX = 8;

/** The fields a signature verification needs, already extracted from the request. */
export interface RequestSignatureInput {
  method: string;
  /** Request path with a leading slash and no query string. */
  path: string;
  timestamp: string | null; // X-Stower-Timestamp header value (unix seconds)
  nonce: string | null; // X-Stower-Nonce header value
  signature: string | null; // X-Stower-Signature header value (lower-case hex)
  rawBody: string;
  key: string; // the keygen_license_key — the per-license HMAC secret
  nowMs: number; // injected clock (ms since epoch)
}

/** A verification verdict; `diagnostic` is non-secret and safe to log. */
export interface RequestSignatureResult {
  ok: boolean;
  diagnostic?: string;
}

/** Extracts the `X-Stower-*` auth headers from a `Headers` object. */
export function extractSignatureHeaders(
  headers: Headers,
): {
  timestamp: string | null;
  nonce: string | null;
  signature: string | null;
} {
  return {
    timestamp: headers.get(STOWER_TIMESTAMP_HEADER),
    nonce: headers.get(STOWER_NONCE_HEADER),
    signature: headers.get(STOWER_SIGNATURE_HEADER),
  };
}

/**
 * Verifies a per-license request signature: required headers present, timestamp
 * within ±120s of `nowMs`, and the HMAC over the canonical message matching the
 * supplied signature (constant-time). Resolves `{ ok: false, diagnostic }` —
 * never throws — so the caller maps it to a single `401 bad_signature`.
 */
export async function verifyRequestSignature(
  input: RequestSignatureInput,
): Promise<RequestSignatureResult> {
  const { timestamp, nonce, signature } = input;
  if (!timestamp || !nonce || !signature) {
    return { ok: false, diagnostic: "missing_signature_headers" };
  }

  const ts = Number(timestamp);
  if (!Number.isFinite(ts)) {
    return { ok: false, diagnostic: "non_numeric_timestamp" };
  }
  const skewSeconds = Math.abs(Math.floor(input.nowMs / 1000) - ts);
  if (skewSeconds > MAX_CLOCK_SKEW_SECONDS) {
    return { ok: false, diagnostic: `stale_timestamp skew=${skewSeconds}s` };
  }

  const bodyHash = await sha256Hex(input.rawBody);
  const message = [
    input.method.toUpperCase(),
    input.path,
    timestamp,
    nonce,
    bodyHash,
  ].join("\n");
  const expected = await hmacSha256Hex(input.key, message);
  if (!timingSafeEqualHex(expected, signature)) {
    const noncePrefix = nonce.slice(0, NONCE_DIAGNOSTIC_PREFIX);
    return { ok: false, diagnostic: `bad_signature nonce=${noncePrefix}…` };
  }
  return { ok: true };
}

/** Lower-case hex SHA-256 of a UTF-8 string. */
export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return toHex(new Uint8Array(digest));
}

/** Lower-case hex HMAC-SHA256 of `message` under the UTF-8 bytes of `key`. */
export async function hmacSha256Hex(
  key: string,
  message: string,
): Promise<string> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    cryptoKey,
    new TextEncoder().encode(message),
  );
  return toHex(new Uint8Array(mac));
}

/**
 * Constant-time compare of two equal-length hex strings; false on a length
 * mismatch. The single source for this in the function — `index.ts` imports it for
 * the Lemon Squeezy signature check too, so there is one constant-time compare.
 */
export function timingSafeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function toHex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}
