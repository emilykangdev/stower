// INTEGRATION test: the full offline machine path against the live Keygen CE
// harness (Scripts/Keygen/). Mints a trial license under the bootstrapped Trial
// policy, then walks the exact surface StowerKeygenClient and Plan Beta depend on:
//
//   bootstrap → mint trial license → assert it carries STOWER_TRIAL → activate a
//   machine → validate-key (now valid for the activated fingerprint) → check out a
//   signed machine file → verify its Ed25519 signature against the account key.
//
// The signature verify is the point: a checkout test that skips it doesn't test the
// thing that actually protects offline "paid" state (a forged/garbled machine file
// must NOT verify). Call shapes are grounded in supabase/functions/license/index.ts
// (mint) and Sources/StowerMacUI/Startup/StowerKeygenClient.swift (activate /
// validate / check-out); the machine-file format is per keygen.sh/docs/api/cryptography.
//
// Requires the harness (Scripts/Keygen/up.sh). Fails loudly if it is down.

import { bootstrap, type BootstrapDeps } from "../bootstrap-keygen.ts";
import {
  accountPath,
  type HarnessEnv,
  keygenFetch,
  requireEnv,
  requirePublicKey,
} from "./harness.ts";

// A unique-per-run fake device fingerprint — the same value is the machine
// fingerprint and the validate-key scope, so the scoped validation matches the
// activated machine. Unique per run so the suite is rerunnable against a still-up
// harness: the policies are UNIQUE_PER_PRODUCT, so a fixed fingerprint would
// collide on the second activate (the prior run's machine still holds it).
const FINGERPRINT = `stower-integration-${crypto.randomUUID()}`;
// Keygen requires a check-out TTL of at least one hour (3600s).
const CHECKOUT_TTL_SECONDS = 3600;
// Force an unencrypted, Ed25519-signed machine file so the test can verify the
// signature directly (the policy scheme is ED25519_SIGN; we pin the algorithm to
// be explicit rather than rely on the scheme-derived default).
const MACHINE_FILE_ALGORITHM = "base64+ed25519";
const TRIAL_ENTITLEMENT_CODE = "STOWER_TRIAL";
// The relationship data the Edge Function checks out (A2): entitlements + policy +
// license, baked INTO the signed payload so the app's offline OR-check reads
// tamper-proof entitlements + expiry.
const MACHINE_FILE_INCLUDE = "license.entitlements,license.policy,license";
const MACHINE_FILE_PREFIX = "-----BEGIN MACHINE FILE-----";
const MACHINE_FILE_SUFFIX = "-----END MACHINE FILE-----";
// Keygen signs machine files over the string `machine/` + the `enc` payload.
const MACHINE_FILE_SIGNING_PREFIX = "machine/";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

/** Runs the real bootstrap to resolve (reuse) the ids this path needs. */
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

// Helpers return ArrayBuffer-backed arrays (Uint8Array<ArrayBuffer>) so they
// satisfy Web Crypto's BufferSource, which rejects the ArrayBufferLike-backed
// default that `new Uint8Array`/`TextEncoder` infer.
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

/** Strips the PEM envelope and decodes the base64 body to the signed object. */
function decodeMachineFile(certificate: string): MachineFile {
  const body = certificate
    .replace(MACHINE_FILE_PREFIX, "")
    .replace(MACHINE_FILE_SUFFIX, "")
    .replace(/\s/g, "");
  const json = JSON.parse(new TextDecoder().decode(bytesFromBase64(body)));
  return json as MachineFile;
}

/** Verifies an Ed25519 machine-file signature against the account public key. */
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
  return await crypto.subtle.verify({ name: "Ed25519" }, key, signature, signingData);
}

async function mintTrialLicense(
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
  assert(status === 201, `mint trial license expected 201, got ${status}`);
  const data = json.data;
  assert(!Array.isArray(data) && data !== undefined, "mint returned no license");
  const license = data as { id: string; attributes?: Record<string, unknown> };
  const key = license.attributes?.key;
  assert(typeof key === "string" && key.length > 0, "minted license has no key");
  return { id: license.id, key: key as string };
}

Deno.test("trial license offline machine path verifies an Ed25519 machine file", async () => {
  const env = requireEnv(); // fail loud if the harness is not up
  const send = keygenFetch(env);
  const ids = await bootstrap(harnessDeps());

  // 1. Mint a trial license under the bootstrapped Trial policy (admin auth).
  const license = await mintTrialLicense(send, env, ids.trialPolicyId);

  // 2. It must carry STOWER_TRIAL (inherited from the Trial policy attachment).
  const entitlements = await send(
    "GET",
    `${accountPath(env)}/licenses/${license.id}/entitlements`,
  );
  assert(entitlements.status === 200, `entitlements expected 200, got ${entitlements.status}`);
  const codes = (Array.isArray(entitlements.json.data) ? entitlements.json.data : [])
    .map((e) => e.attributes?.code);
  assert(
    codes.includes(TRIAL_ENTITLEMENT_CODE),
    `trial license is missing ${TRIAL_ENTITLEMENT_CODE} (got ${JSON.stringify(codes)})`,
  );

  // 3. Activate a machine for the device fingerprint (license-key auth).
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
  assert(activation.status === 201, `activate machine expected 201, got ${activation.status}`);
  const machine = activation.json.data;
  assert(!Array.isArray(machine) && machine !== undefined, "activate returned no machine");
  const machineId = (machine as { id: string }).id;

  // 4. validate-key now passes for that fingerprint (the activated machine matches).
  const validation = await send(
    "POST",
    `${accountPath(env)}/licenses/actions/validate-key`,
    { body: { meta: { key: license.key, scope: { fingerprint: FINGERPRINT } } } },
  );
  assert(validation.status === 200, `validate-key expected 200, got ${validation.status}`);
  assert(
    validation.json.meta?.valid === true,
    `trial license did not validate: ${JSON.stringify(validation.json.meta)}`,
  );

  // 5. Check out a signed machine file (license-key auth, pinned Ed25519 algorithm),
  // with the SAME `include=` the Edge Function uses, so this proves the offline path.
  const checkoutQuery = new URLSearchParams({
    ttl: String(CHECKOUT_TTL_SECONDS),
    algorithm: MACHINE_FILE_ALGORITHM,
    include: MACHINE_FILE_INCLUDE,
  });
  const checkout = await send(
    "POST",
    `${accountPath(env)}/machines/${machineId}/actions/check-out?${checkoutQuery}`,
    { headers: licenseAuth(license.key) },
  );
  assert(checkout.status === 200, `check-out expected 200, got ${checkout.status}`);
  const checkoutData = checkout.json.data;
  assert(!Array.isArray(checkoutData) && checkoutData !== undefined, "check-out returned no file");
  const certificate = (checkoutData as { attributes?: Record<string, unknown> })
    .attributes?.certificate;
  assert(typeof certificate === "string", "check-out response has no certificate");

  // 6. Resolve the account's Ed25519 public key (hex). CE does not serve the
  // account over GET /v1/accounts/{id} (404 in singleplayer), so up.sh captures it
  // from the DB into KEYGEN_PUBLIC_KEY — the same key the Mac app embeds as a constant.
  const publicKeyHex = requirePublicKey();

  // 7. The machine file's signature MUST verify against the account key.
  const machineFile = decodeMachineFile(certificate as string);
  assert(
    machineFile.alg === MACHINE_FILE_ALGORITHM,
    `unexpected machine-file algorithm: ${machineFile.alg}`,
  );
  const signature = bytesFromBase64(machineFile.sig);
  const verified = await verifyMachineFile(machineFile, publicKeyHex, signature);
  assert(verified, "machine-file Ed25519 signature did NOT verify against the account key");

  // 8. Negative control: a corrupted signature MUST be rejected — proving the verify
  // is real and not vacuously true (the forged-offline-file guarantee).
  const tampered = signature.slice();
  tampered[0] ^= 0xff;
  const tamperedVerified = await verifyMachineFile(machineFile, publicKeyHex, tampered);
  assert(!tamperedVerified, "a corrupted signature verified — the check is not real");

  // 9. A2 LOCK-IN: the `include=` relationship data must live INSIDE the signed
  // `enc` payload (not an unsigned envelope) — otherwise an offline OR-check would
  // read tamper-able entitlements. Decode the signed enc and assert STOWER_TRIAL +
  // the license expiry are present in the snapshot the signature covers.
  const payload = JSON.parse(
    new TextDecoder().decode(bytesFromBase64(machineFile.enc)),
  ) as {
    included?: Array<{ type?: string; attributes?: Record<string, unknown> }>;
  };
  const included = Array.isArray(payload.included) ? payload.included : [];
  const signedEntitlements = included
    .filter((r) => r.type === "entitlements")
    .map((r) => r.attributes?.code);
  assert(
    signedEntitlements.includes(TRIAL_ENTITLEMENT_CODE),
    `A2: ${TRIAL_ENTITLEMENT_CODE} is NOT inside the signed machine-file payload (got ${JSON.stringify(signedEntitlements)})`,
  );
  const signedLicense = included.find((r) => r.type === "licenses");
  assert(
    signedLicense !== undefined && "expiry" in (signedLicense.attributes ?? {}),
    "A2: the license expiry is NOT inside the signed machine-file payload",
  );
});
