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
