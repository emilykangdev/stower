// INTEGRATION test: runs the REAL bootstrap-keygen.ts against the live Keygen CE
// harness (Scripts/Keygen/). The hermetic unit tests (../bootstrap-keygen.test.ts)
// stub `fetch` — they prove our logic but not that real Keygen accepts our
// exact JSON:API payloads. This proves the round-trip and idempotency for real, the
// check that would have caught the `page[number]` 400 before it shipped.
//
// Requires the harness: run Scripts/Keygen/up.sh, then
// `deno task test:integration`. Fails loudly (never skips) if the harness is down.

import {
  bootstrap,
  type BootstrapDeps,
  type BootstrapOutput,
} from "../bootstrap-keygen.ts";
import { requireEnv } from "./harness.ts";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message?: string): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(message ?? `assertEquals failed: ${a} !== ${e}`);
}

/** Real deps bound to the harness: live `fetch`/env, captured stdout/stderr. */
function harnessDeps(): BootstrapDeps {
  return {
    fetch: globalThis.fetch.bind(globalThis),
    getEnv: (name) => Deno.env.get(name),
    stdout: () => {},
    stderr: () => {},
  };
}

/** The ids the script must emit; each must come back non-empty from real Keygen. */
const ID_FIELDS: ReadonlyArray<keyof BootstrapOutput> = [
  "productId",
  "trialPolicyId",
  "paidPolicyId",
  "trialEntitlementId",
  "v0EntitlementId",
];

Deno.test("bootstrap round-trips and is idempotent against a real Keygen CE", async () => {
  requireEnv(); // fail loud if the harness is not up

  const deps = harnessDeps();
  const first = await bootstrap(deps);
  for (const field of ID_FIELDS) {
    assert(
      typeof first[field] === "string" && first[field].length > 0,
      `bootstrap output is missing a real id for ${field}`,
    );
  }

  // Rerun: every find-or-create must REUSE, never duplicate — so the second run
  // returns byte-identical ids. This is the idempotency guarantee Plan Beta and
  // prod re-provisioning depend on.
  const second = await bootstrap(harnessDeps());
  assertEquals(
    second,
    first,
    "bootstrap is not idempotent: a rerun returned different ids (duplicates created)",
  );
});
