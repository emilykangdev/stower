// Deploy-readiness config for the license function. The env vars the function
// cannot operate without — `/health` reports which are unset so a misconfigured
// deploy is caught with one curl, not by a failed mint later. Names only; the
// (secret) values are never read here or returned.

/** Env vars the license function cannot operate without. */
export const REQUIRED_ENV = [
  "SUPABASE_URL",
  "SUPABASE_SERVICE_ROLE_KEY",
  "KEYGEN_ACCOUNT",
  "KEYGEN_TOKEN",
  "KEYGEN_V0_ENTITLEMENT",
  "KEYGEN_TRIAL_POLICY",
  "KEYGEN_PAID_POLICY",
  "LS_WEBHOOK_SECRET",
  "LS_PAID_VARIANT_ID",
] as const;

/**
 * The required env vars that are unset or empty, given an env reader. Returns only
 * the NAMES (never values) — safe to put in a `/health` body. Pure + injected so
 * the Deno tests need no real env.
 */
export function missingRequiredEnv(
  get: (name: string) => string | undefined,
): string[] {
  return REQUIRED_ENV.filter((name) => !get(name));
}

/** The default trial length when `TRIAL_DURATION_SECONDS` is unset — 30 days. */
export const TRIAL_DURATION_DEFAULT_SECONDS = 30 * 24 * 60 * 60; // 2592000

/**
 * ECMAScript's maximum valid `Date` time value (±8.64e15 ms). A timestamp past
 * this makes `new Date(ms).toISOString()` throw, so a trial duration is clamped
 * to keep `Date.now() + duration` within range.
 */
const MAX_DATE_MS = 8.64e15;

/**
 * The trial length in milliseconds, from the optional `TRIAL_DURATION_SECONDS`
 * env (a DEBUG/staging lever to expire trials in seconds). Unset, empty,
 * non-numeric, `≤ 0`, or so large it would push the expiry past the max valid
 * `Date` falls back to the 30-day default — never a 0/`NaN`/`Infinity` expiry
 * that would mint an instantly-expired (or `Invalid Date`) trial, or make
 * `createTrialLicense`'s `toISOString()` throw and turn `/mint-trial` into a 500.
 * NOT in `REQUIRED_ENV`: prod boots with it unset and gets 30 days. Pure +
 * injected (`get`, `nowMs`) so the Deno tests need no real env or clock.
 */
export function trialDurationMs(
  get: (name: string) => string | undefined,
  nowMs: number = Date.now(),
): number {
  const raw = get("TRIAL_DURATION_SECONDS");
  const seconds = raw ? Number(raw) : NaN;
  const maxSeconds = Math.floor((MAX_DATE_MS - nowMs) / 1000);
  const effective = Number.isFinite(seconds) && seconds > 0 &&
      seconds <= maxSeconds
    ? seconds
    : TRIAL_DURATION_DEFAULT_SECONDS;
  return effective * 1000;
}

/**
 * The `/health` fields that surface a non-default trial duration — a loud
 * detection canary so a `TRIAL_DURATION_SECONDS` left set on the prod project is
 * caught by one curl, not by a customer's 60-second trial. Returns
 * `{ trialDurationSeconds, warning }` only when the resolved duration differs
 * from the 30-day default; an empty object otherwise (so the default stays
 * silent). Pure + injected so the Deno tests need no real env.
 */
export function trialDurationHealthFields(
  get: (name: string) => string | undefined,
): { trialDurationSeconds: number; warning: string } | Record<string, never> {
  const seconds = trialDurationMs(get) / 1000;
  if (seconds === TRIAL_DURATION_DEFAULT_SECONDS) return {};
  return {
    trialDurationSeconds: seconds,
    warning: "non-default trial duration",
  };
}
