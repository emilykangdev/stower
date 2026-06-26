// Hermetic tests for the deploy-readiness env check (config.ts). Fully offline:
// the env reader is injected, so no real env is touched.

import { missingRequiredEnv, REQUIRED_ENV } from "./config.ts";

function assertEquals(
  actual: unknown,
  expected: unknown,
  message?: string,
): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(message ?? `${a} !== ${e}`);
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
