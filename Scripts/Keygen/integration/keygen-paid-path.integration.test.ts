// INTEGRATION test: the PAID license path against the live Keygen CE harness
// (Scripts/Keygen/), with NO Lemon Squeezy. The webhook's only licensing effect is
// "attach STOWER_V0 to the license", so we seed that directly via the Keygen admin
// API and then walk the paid happy path the Edge Function's check-in relies on:
//
//   bootstrap → mint license → attach STOWER_V0 (admin; re-attach is idempotent) →
//   assert effective entitlements include STOWER_V0 → activate a machine →
//   validate-key (valid) → check out a signed machine file (ADMIN auth + include) →
//   verify its Ed25519 signature AND assert STOWER_V0 is INSIDE the signed payload.
//
// This proves "a paid (STOWER_V0) license actually works" against real Keygen —
// today that is only covered against a fake. It does NOT prove "a purchase causes
// the attach" (the LS→webhook delivery is a separate concern, tested with LS test
// mode). Keygen call shapes mirror supabase/functions/license/index.ts `keygenAdmin`.
// The checkout MUST use admin auth: a license-scoped token is 403'd from embedding
// `include=` relationships (the lesson PR #20's CI caught).
//
// Requires the harness (Scripts/Keygen/up.sh). Fails loudly if it is down. Cleans
// up the license it creates so it is safe to point at a real account later.

import { bootstrap, type BootstrapDeps } from "../bootstrap-keygen.ts";
import {
  accountPath,
  type HarnessEnv,
  keygenFetch,
  requireEnv,
  requirePublicKey,
} from "./harness.ts";

const FINGERPRINT = `stower-paid-${crypto.randomUUID()}`;
const CHECKOUT_TTL_SECONDS = 3600; // Keygen requires >= 1h.
const MACHINE_FILE_ALGORITHM = "base64+ed25519";
// The Edge Function's exact checkout includes; admin-auth required to embed them.
const MACHINE_FILE_INCLUDE = "license.entitlements,license.policy,license";
const TRIAL_ENTITLEMENT_CODE = "STOWER_TRIAL";
const V0_ENTITLEMENT_CODE = "STOWER_V0";
const MACHINE_FILE_PREFIX = "-----BEGIN MACHINE FILE-----";
const MACHINE_FILE_SUFFIX = "-----END MACHINE FILE-----";
const MACHINE_FILE_SIGNING_PREFIX = "machine/";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function harnessDeps(): BootstrapDeps {
  return {
    fetch: globalThis.fetch.bind(globalThis),
    getEnv: (name) => Deno.env.get(name),
    stdout: () => {},
    stderr: () => {},
  };
}

function licenseAuth(licenseKey: string): Record<string, string> {
  return { "Authorization": `License ${licenseKey}` };
}

// ArrayBuffer-backed arrays so Web Crypto's BufferSource is satisfied.
function bytesFromBase64(value: string): Uint8Array<ArrayBuffer> {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesFromHex(value: string): Uint8Array<ArrayBuffer> {
  assert(value.length % 2 === 0, "public key hex has an odd length");
  const bytes = new Uint8Array(value.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(value.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

/** The `{enc, sig, alg}` object decoded from a PEM-enveloped machine file. */
interface MachineFile {
  enc: string;
  sig: string;
  alg: string;
}

function decodeMachineFile(certificate: string): MachineFile {
  const body = certificate
    .replace(MACHINE_FILE_PREFIX, "")
    .replace(MACHINE_FILE_SUFFIX, "")
    .replace(/\s/g, "");
  return JSON.parse(
    new TextDecoder().decode(bytesFromBase64(body)),
  ) as MachineFile;
}

async function verifyMachineFile(
  file: MachineFile,
  publicKeyHex: string,
  signature: Uint8Array<ArrayBuffer>,
): Promise<boolean> {
  const key = await crypto.subtle.importKey(
    "raw",
    bytesFromHex(publicKeyHex),
    { name: "Ed25519" },
    false,
    ["verify"],
  );
  const signingData = Uint8Array.from(
    new TextEncoder().encode(`${MACHINE_FILE_SIGNING_PREFIX}${file.enc}`),
  );
  return await crypto.subtle.verify(
    { name: "Ed25519" },
    key,
    signature,
    signingData,
  );
}

async function mintLicense(
  send: ReturnType<typeof keygenFetch>,
  env: HarnessEnv,
  trialPolicyId: string,
): Promise<{ id: string; key: string }> {
  const { status, json } = await send("POST", `${accountPath(env)}/licenses`, {
    body: {
      data: {
        type: "licenses",
        relationships: {
          policy: { data: { type: "policies", id: trialPolicyId } },
        },
      },
    },
  });
  assert(status === 201, `mint license expected 201, got ${status}`);
  const data = json.data;
  assert(
    !Array.isArray(data) && data !== undefined,
    "mint returned no license",
  );
  const license = data as { id: string; attributes?: Record<string, unknown> };
  const key = license.attributes?.key;
  assert(
    typeof key === "string" && (key as string).length > 0,
    "minted license has no key",
  );
  return { id: license.id, key: key as string };
}

/** Effective entitlement codes for a license (policy-inherited + direct). */
async function entitlementCodes(
  send: ReturnType<typeof keygenFetch>,
  env: HarnessEnv,
  licenseId: string,
): Promise<string[]> {
  const { status, json } = await send(
    "GET",
    `${accountPath(env)}/licenses/${licenseId}/entitlements`,
  );
  assert(status === 200, `entitlements expected 200, got ${status}`);
  return (Array.isArray(json.data) ? json.data : []).map((e) =>
    e.attributes?.code as string
  );
}

Deno.test("paid (STOWER_V0) license validates + checks out a signed file carrying the entitlement", async () => {
  const env = requireEnv(); // fail loud if the harness is not up
  const send = keygenFetch(env);
  const ids = await bootstrap(harnessDeps());

  const license = await mintLicense(send, env, ids.trialPolicyId);

  try {
    // 1. Seed "paid" by attaching STOWER_V0 directly (the webhook's only licensing
    // effect) — skips Lemon Squeezy entirely. Admin auth.
    const attach = await send(
      "POST",
      `${accountPath(env)}/licenses/${license.id}/entitlements`,
      { body: { data: [{ type: "entitlements", id: ids.v0EntitlementId }] } },
    );
    assert(
      attach.status === 200 || attach.status === 201,
      `attach STOWER_V0 expected 200/201, got ${attach.status}: ${attach.text}`,
    );

    // 2. Re-attach is idempotent: Keygen reports a duplicate (200/201 no-op, or a
    // 400/409/422 "already attached") — never a 5xx — and STOWER_V0 stays single.
    const reattach = await send(
      "POST",
      `${accountPath(env)}/licenses/${license.id}/entitlements`,
      { body: { data: [{ type: "entitlements", id: ids.v0EntitlementId }] } },
    );
    assert(
      [200, 201, 400, 409, 422].includes(reattach.status),
      `re-attach should be a handled duplicate, got ${reattach.status}: ${reattach.text}`,
    );

    // 3. Confirm the paid unlock is real: effective entitlements include STOWER_V0
    // (exactly once — no duplicate from the re-attach) and still STOWER_TRIAL.
    const codes = await entitlementCodes(send, env, license.id);
    assert(
      codes.includes(V0_ENTITLEMENT_CODE),
      `paid license is missing ${V0_ENTITLEMENT_CODE} (got ${
        JSON.stringify(codes)
      })`,
    );
    assert(
      codes.filter((c) => c === V0_ENTITLEMENT_CODE).length === 1,
      `re-attach duplicated ${V0_ENTITLEMENT_CODE} (got ${
        JSON.stringify(codes)
      })`,
    );
    assert(
      codes.includes(TRIAL_ENTITLEMENT_CODE),
      `expected ${TRIAL_ENTITLEMENT_CODE} from the policy too (got ${
        JSON.stringify(codes)
      })`,
    );

    // 4. Activate a machine (license-key auth) for the device fingerprint.
    const activation = await send("POST", `${accountPath(env)}/machines`, {
      headers: licenseAuth(license.key),
      body: {
        data: {
          type: "machines",
          attributes: { fingerprint: FINGERPRINT },
          relationships: {
            license: { data: { type: "licenses", id: license.id } },
          },
        },
      },
    });
    assert(
      activation.status === 201,
      `activate machine expected 201, got ${activation.status}`,
    );
    const machine = activation.json.data;
    assert(
      !Array.isArray(machine) && machine !== undefined,
      "activate returned no machine",
    );
    const machineId = (machine as { id: string }).id;

    // 5. validate-key passes for that fingerprint.
    const validation = await send(
      "POST",
      `${accountPath(env)}/licenses/actions/validate-key`,
      {
        body: {
          meta: { key: license.key, scope: { fingerprint: FINGERPRINT } },
        },
      },
    );
    assert(
      validation.status === 200,
      `validate-key expected 200, got ${validation.status}`,
    );
    assert(
      validation.json.meta?.valid === true,
      `paid license did not validate: ${JSON.stringify(validation.json.meta)}`,
    );

    // 6. Check out a signed machine file — ADMIN auth (license-scoped 403s on include=).
    const checkoutQuery = new URLSearchParams({
      ttl: String(CHECKOUT_TTL_SECONDS),
      algorithm: MACHINE_FILE_ALGORITHM,
      include: MACHINE_FILE_INCLUDE,
    });
    const checkout = await send(
      "POST",
      `${
        accountPath(env)
      }/machines/${machineId}/actions/check-out?${checkoutQuery}`,
    );
    assert(
      checkout.status === 200,
      `check-out expected 200, got ${checkout.status}: ${checkout.text}`,
    );
    const checkoutData = checkout.json.data;
    assert(
      !Array.isArray(checkoutData) && checkoutData !== undefined,
      "check-out returned no file",
    );
    const certificate =
      (checkoutData as { attributes?: Record<string, unknown> })
        .attributes?.certificate;
    assert(
      typeof certificate === "string",
      "check-out response has no certificate",
    );

    // 7. The machine file's Ed25519 signature must verify against the account key.
    const publicKeyHex = requirePublicKey();
    const machineFile = decodeMachineFile(certificate as string);
    assert(
      machineFile.alg === MACHINE_FILE_ALGORITHM,
      `unexpected machine-file algorithm: ${machineFile.alg}`,
    );
    const signature = bytesFromBase64(machineFile.sig);
    assert(
      await verifyMachineFile(machineFile, publicKeyHex, signature),
      "machine-file Ed25519 signature did NOT verify against the account key",
    );

    // 8. The PAID guarantee: STOWER_V0 is INSIDE the signed payload (the offline
    // OR-check reads tamper-proof entitlements), not just present online.
    const payload = JSON.parse(
      new TextDecoder().decode(bytesFromBase64(machineFile.enc)),
    ) as {
      included?: Array<{ type?: string; attributes?: { code?: string } }>;
    };
    const signedCodes =
      (Array.isArray(payload.included) ? payload.included : [])
        .filter((r) => r.type === "entitlements")
        .map((r) => r.attributes?.code);
    assert(
      signedCodes.includes(V0_ENTITLEMENT_CODE),
      `${V0_ENTITLEMENT_CODE} is NOT inside the signed machine-file payload (got ${
        JSON.stringify(signedCodes)
      })`,
    );
  } finally {
    // Clean up the license we created (admin) so the test is safe to re-run against
    // a real account; on CE the DB is ephemeral so this is best-effort.
    await send("DELETE", `${accountPath(env)}/licenses/${license.id}`).catch(
      () => {},
    );
  }
});
