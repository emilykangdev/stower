// Hermetic tests for the JC5 per-license request-signature verifier. Fully
// offline: the clock is injected and the parity vector is a static JSON import (no
// disk permission needed). Asserts the committed Swift↔Deno vector verifies, plus
// the rejection paths (missing headers, stale timestamp, tampered body, wrong key).

import {
  type RequestSignatureInput,
  timingSafeEqualHex,
  verifyRequestSignature,
} from "./requestSignature.ts";
import jc5Vector from "./fixtures/jc5-signature-vector.json" with {
  type: "json",
};

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

const VECTOR_MS = Number(jc5Vector.timestamp) * 1000;

function vectorInput(
  overrides: Partial<RequestSignatureInput> = {},
): RequestSignatureInput {
  return {
    method: jc5Vector.method,
    path: jc5Vector.path,
    timestamp: jc5Vector.timestamp,
    nonce: jc5Vector.nonce,
    signature: jc5Vector.signature,
    rawBody: jc5Vector.body,
    key: jc5Vector.key,
    nowMs: VECTOR_MS,
    ...overrides,
  };
}

// JC5 PARITY: the committed vector must verify with the shipped algorithm. This is
// the Swift↔Deno contract — if it ever fails, the seam drifted.
Deno.test("JC5 committed parity vector verifies", async () => {
  const result = await verifyRequestSignature(vectorInput());
  assert(result.ok, `vector should verify, got ${JSON.stringify(result)}`);
});

// A timestamp within ±120s still verifies (the signature does not depend on now).
Deno.test("a within-window timestamp skew is accepted", async () => {
  const result = await verifyRequestSignature(
    vectorInput({ nowMs: VECTOR_MS + 119_000 }),
  );
  assert(result.ok, `119s skew should verify, got ${JSON.stringify(result)}`);
});

// A timestamp more than 120s from now is rejected (replay defense).
Deno.test("a stale timestamp is rejected", async () => {
  const result = await verifyRequestSignature(
    vectorInput({ nowMs: VECTOR_MS + 121_000 }),
  );
  assert(!result.ok, "121s skew should be rejected");
  assert(
    result.diagnostic?.startsWith("stale_timestamp") ?? false,
    `expected stale diagnostic, got ${result.diagnostic}`,
  );
});

// Missing any auth header is rejected (and never crashes).
Deno.test("missing signature headers are rejected", async () => {
  const result = await verifyRequestSignature(vectorInput({ signature: null }));
  assert(!result.ok, "null signature should be rejected");
  assert(
    result.diagnostic === "missing_signature_headers",
    result.diagnostic ?? "",
  );
});

// INTEGRITY: a swapped body under the SAME signature must fail — proving the
// signature commits to the body hash (the attack the body-hash closes).
Deno.test("a tampered body breaks the signature", async () => {
  const tampered = jc5Vector.body.replace("lic-test-0001", "lic-ATTACKER");
  const result = await verifyRequestSignature(
    vectorInput({ rawBody: tampered }),
  );
  assert(!result.ok, "tampered body should fail");
  assert(
    result.diagnostic?.startsWith("bad_signature") ?? false,
    `expected bad_signature, got ${result.diagnostic}`,
  );
});

// AUTHENTICITY: the wrong key cannot forge a valid signature.
Deno.test("the wrong key fails verification", async () => {
  const result = await verifyRequestSignature(
    vectorInput({ key: "wrong-key" }),
  );
  assert(!result.ok, "wrong key should fail");
});

// The non-secret diagnostic never echoes the key, body, or full signature.
Deno.test("the diagnostic leaks no secret", async () => {
  const result = await verifyRequestSignature(vectorInput({ rawBody: "x" }));
  const diag = result.diagnostic ?? "";
  assert(!diag.includes(jc5Vector.key), "diagnostic must not contain the key");
  assert(
    !diag.includes(jc5Vector.signature),
    "diagnostic must not contain the signature",
  );
});

// A non-numeric timestamp is rejected, not NaN-compared into acceptance.
Deno.test("a non-numeric timestamp is rejected", async () => {
  const result = await verifyRequestSignature(
    vectorInput({ timestamp: "not-a-number" }),
  );
  assert(!result.ok, "non-numeric timestamp should be rejected");
  assert(
    result.diagnostic === "non_numeric_timestamp",
    result.diagnostic ?? "",
  );
});

Deno.test("timingSafeEqualHex is false on a length mismatch", () => {
  assert(!timingSafeEqualHex("abcd", "abcde"), "length mismatch must be false");
  assert(timingSafeEqualHex("abcd", "abcd"), "equal strings must be true");
});
