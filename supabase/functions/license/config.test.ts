// Hermetic tests for the deploy-readiness env check (config.ts). Fully offline:
// the env reader is injected, so no real env is touched.

import {
  missingRequiredEnv,
  REQUIRED_ENV,
  TRIAL_DURATION_DEFAULT_SECONDS,
  trialDurationHealthFields,
  trialDurationMs,
} from "./config.ts";

function assertEquals(
  actual: unknown,
  expected: unknown,
  message?: string,
): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(message ?? `${a} !== ${e}`);
}

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

/** An env reader backed by a plain record. */
function reader(
  env: Record<string, string>,
): (name: string) => string | undefined {
  return (name) => env[name];
}

function allSet(): Record<string, string> {
  return Object.fromEntries(REQUIRED_ENV.map((name) => [name, "set"]));
}

Deno.test("missingRequiredEnv returns [] when every required var is present", () => {
  assertEquals(missingRequiredEnv(reader(allSet())), []);
});

Deno.test("missingRequiredEnv names the unset vars (and only those)", () => {
  const env = allSet();
  delete env.KEYGEN_TOKEN;
  delete env.LS_WEBHOOK_SECRET;
  assertEquals(
    missingRequiredEnv(reader(env)).sort(),
    ["KEYGEN_TOKEN", "LS_WEBHOOK_SECRET"],
  );
});

Deno.test("an empty-string value counts as missing", () => {
  const env = allSet();
  env.KEYGEN_ACCOUNT = "";
  assertEquals(missingRequiredEnv(reader(env)), ["KEYGEN_ACCOUNT"]);
});

Deno.test("a totally empty env reports all required vars", () => {
  assertEquals(missingRequiredEnv(reader({})).length, REQUIRED_ENV.length);
});

// ---------------------------------------------------------------------------
// trialDurationMs (I-H1..I-H4) — the staging short-trial lever; default-safe.
// ---------------------------------------------------------------------------

const THIRTY_DAYS_MS = 2_592_000_000;

Deno.test("I-H1 unset TRIAL_DURATION_SECONDS ⇒ 30-day default", () => {
  assertEquals(trialDurationMs(reader({})), THIRTY_DAYS_MS);
});

Deno.test("I-H4 a valid TRIAL_DURATION_SECONDS=60 ⇒ 60000 ms", () => {
  assertEquals(
    trialDurationMs(reader({ TRIAL_DURATION_SECONDS: "60" })),
    60000,
  );
});

Deno.test("I-H2 empty / whitespace / non-numeric / ≤0 ⇒ 30-day default (never 0/∞/NaN)", () => {
  // Whitespace coerces to 0 via Number — the `> 0` clamp (not the `raw ?` guard)
  // is the real safety net here, so an instantly-expired trial can't be minted.
  for (const value of ["", "  ", "abc", "-5", "0"]) {
    assertEquals(
      trialDurationMs(reader({ TRIAL_DURATION_SECONDS: value })),
      THIRTY_DAYS_MS,
      `TRIAL_DURATION_SECONDS=${
        JSON.stringify(value)
      } must fall back to default`,
    );
  }
});

Deno.test("I-H3 TRIAL_DURATION_SECONDS is NOT required to boot", () => {
  assert(
    !(REQUIRED_ENV as readonly string[]).includes("TRIAL_DURATION_SECONDS"),
    "TRIAL_DURATION_SECONDS must not be in REQUIRED_ENV",
  );
  // allSet() never sets it, so a boot with it unset reports nothing missing.
  assertEquals(missingRequiredEnv(reader(allSet())), []);
});

Deno.test("I-H1 the default constant is exactly 30 days in seconds", () => {
  assertEquals(TRIAL_DURATION_DEFAULT_SECONDS, 2_592_000);
});

// ---------------------------------------------------------------------------
// trialDurationHealthFields (I-H10) — the /health non-default-duration canary.
// ---------------------------------------------------------------------------

Deno.test("I-H10 default duration omits the /health field (stays silent)", () => {
  assertEquals(trialDurationHealthFields(reader({})), {});
});

Deno.test("I-H10 a non-default duration surfaces trialDurationSeconds + a warning", () => {
  assertEquals(
    trialDurationHealthFields(reader({ TRIAL_DURATION_SECONDS: "60" })),
    { trialDurationSeconds: 60, warning: "non-default trial duration" },
  );
});
