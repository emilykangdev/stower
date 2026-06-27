// HTTP entrypoint for the `license` Edge Function — the licensing brain. Routes
// `/mint-trial`, `/check-in`, `/ls-webhook`, and `/health`, wiring the real
// Postgres / Keygen / GitHub / Lemon Squeezy implementations into the pure
// handlers (handlers.ts). All secrets are read from Deno.env here and NEVER
// logged; logs carry only non-secret ids and diagnostics. Check-in never returns
// the license key.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import {
  checkIn,
  type CheckInDeps,
  type CheckInRequest,
  type ExtensionGrant,
  handleWebhook,
  type KeygenAdmin,
  KeygenLicenseNotFoundError,
  KeygenMachineLimitError,
  type KeygenValidation,
  type MintDeps,
  type MintRequest,
  mintTrial,
  PurchaseForgedLicenseError,
  type PurchaseStore,
  type Reply,
  type TrialRow,
  type TrialStore,
  type WebhookDeps,
} from "./handlers.ts";
import { missingRequiredEnv } from "./config.ts";
import {
  emptyGithubCache,
  githubReleases,
  type StableRelease,
} from "./github.ts";
import {
  extractSignatureHeaders,
  timingSafeEqualHex,
  verifyRequestSignature,
} from "./requestSignature.ts";

const KEYGEN_BASE_URL = "https://api.keygen.sh";
const TRIAL_DURATION_MS = 30 * 24 * 60 * 60 * 1000; // 30-day trial
const RECLAIM_WINDOW_MS = 60 * 1000; // abandoned 'pending' claim age
const JSON_API_CONTENT_TYPE = "application/vnd.api+json";
// Keygen paginates the license-entitlements list (default 10, newest-first); 100
// is the API max. Stower accrues at most a handful of effective codes per license
// (STOWER_TRIAL + one per purchased major), so a single max-size page reads them
// all — no cursor loop needed. Without it, an older code (e.g. STOWER_V0) could
// fall off page 1 once paid majors add up and the entitlement OR would falsely
// read `wrong_version`, blocking a paying customer.
const KEYGEN_ENTITLEMENTS_PAGE_SIZE = 100;

// Machine-file checkout: 7-day TTL, signed (Ed25519, unencrypted) so the app can
// verify it offline, with the license + entitlements + policy baked INTO the
// signed payload (A2 — the offline OR-check reads tamper-proof entitlements).
const MACHINE_FILE_TTL_SECONDS = 604800;
const MACHINE_FILE_ALGORITHM = "base64+ed25519";
const MACHINE_FILE_INCLUDE = "license.entitlements,license.policy,license";

// The canonical, deployment-independent path the check-in signature commits to —
// a constant, NOT the raw request pathname (which carries Supabase's function
// prefix). Plan B's Swift signer must sign this exact string (JC5 fixture).
const CHECK_IN_SIGNING_PATH = "/check-in";

// GitHub releases (the +7d "current latest stable major" source). 5-minute cache.
const GITHUB_DEFAULT_API_BASE = "https://api.github.com";
const GITHUB_CACHE_TTL_MS = 5 * 60 * 1000;
const GITHUB_RELEASES_PAGE_SIZE = 100;

// Outbound-fetch deadline (item B). A hung Keygen/GitHub upstream must return a
// controlled, retryable failure well before the platform's 150s idle → 504, never
// hang the whole check-in. GitHub timeouts fall back to cached-or-null (extension
// skipped); Keygen timeouts surface as a retryable error.
const OUTBOUND_FETCH_TIMEOUT_MS = 10_000;

/** `fetch` with an abort deadline, for the Keygen admin calls. */
function timedFetch(input: string, init: RequestInit = {}): Promise<Response> {
  return fetch(input, {
    ...init,
    signal: AbortSignal.timeout(OUTBOUND_FETCH_TIMEOUT_MS),
  });
}

/** Whether a Keygen error body indicates a duplicate / already-attached relationship. */
function isDuplicateRelationship(body: string): boolean {
  return /already been taken|already exists|has already|duplicat/i.test(body);
}

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing env ${name}`);
  return value;
}

function supabase(): SupabaseClient {
  return createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
}

/** The columns every TrialRow read selects (mint + check-in share this shape). */
const TRIAL_ROW_COLUMNS =
  "status, fingerprint, keygen_license_id, keygen_license_key, keygen_machine_id, started_major, created_at";

function nowIso(): string {
  return new Date(Date.now()).toISOString();
}

function trialStore(db: SupabaseClient): TrialStore {
  return {
    async claim(fingerprint) {
      const claimId = crypto.randomUUID();
      const { error } = await db
        .from("device_trials")
        .insert({ fingerprint, status: "pending", claim_id: claimId });
      if (!error) return claimId;
      if (error.code === "23505") return null; // unique_violation — lost the claim
      throw new Error(`claim failed: ${error.code}`);
    },
    async get(fingerprint) {
      const { data, error } = await db
        .from("device_trials")
        .select(TRIAL_ROW_COLUMNS)
        .eq("fingerprint", fingerprint)
        .maybeSingle();
      if (error) throw new Error(`trial lookup failed: ${error.code}`); // never mask a DB error as no-row
      return (data as TrialRow | null) ?? null;
    },
    async getByLicense(licenseID) {
      const { data, error } = await db
        .from("device_trials")
        .select(TRIAL_ROW_COLUMNS)
        .eq("keygen_license_id", licenseID)
        .maybeSingle();
      if (error) throw new Error(`license lookup failed: ${error.code}`); // surface → 503, never a false 404
      return (data as TrialRow | null) ?? null;
    },
    async activate(fingerprint, claimToken, licenseID, licenseKey) {
      const { data, error } = await db
        .from("device_trials")
        .update({
          status: "active",
          keygen_license_id: licenseID,
          keygen_license_key: licenseKey,
          updated_at: nowIso(),
        })
        .eq("fingerprint", fingerprint)
        .eq("status", "pending")
        .eq("claim_id", claimToken)
        .select("fingerprint");
      if (error) throw new Error(`activate failed: ${error.code}`);
      return (data?.length ?? 0) > 0; // false => the claim was reclaimed by another winner
    },
    async releaseClaim(fingerprint, claimToken) {
      await db
        .from("device_trials")
        .delete()
        .eq("fingerprint", fingerprint)
        .eq("status", "pending")
        .eq("claim_id", claimToken);
    },
    async reclaimStale(fingerprint, olderThanMs) {
      await db
        .from("device_trials")
        .delete()
        .eq("fingerprint", fingerprint)
        .eq("status", "pending")
        .lt("created_at", new Date(olderThanMs).toISOString());
    },
    async setMachine(licenseID, machineID) {
      const { error } = await db
        .from("device_trials")
        .update({ keygen_machine_id: machineID, updated_at: nowIso() })
        .eq("keygen_license_id", licenseID);
      if (error) throw new Error(`set machine failed: ${error.code}`);
    },
    async extendedMajors(licenseID) {
      const { data, error } = await db
        .from("trial_extension_grants")
        .select("major")
        .eq("keygen_license_id", licenseID)
        .not("patched_at", "is", null);
      if (error) {
        throw new Error(`extended majors lookup failed: ${error.code}`);
      }
      return (data ?? []).map((row) =>
        String((row as { major: string }).major)
      );
    },
    async claimExtensionGrant(
      licenseID,
      major,
      previousExpiresAt,
      targetExpiresAt,
    ) {
      const { error } = await db.from("trial_extension_grants").insert({
        keygen_license_id: licenseID,
        major,
        previous_expires_at: previousExpiresAt,
        target_expires_at: targetExpiresAt,
      });
      if (error && error.code !== "23505") {
        throw new Error(`claim extension grant failed: ${error.code}`);
      }
      // Insert won OR the row already existed (conflict): read back the authoritative
      // row so a retry re-patches to the FROZEN target, not a recomputed one (I11).
      const { data, error: readError } = await db
        .from("trial_extension_grants")
        .select("target_expires_at, patched_at")
        .eq("keygen_license_id", licenseID)
        .eq("major", major)
        .maybeSingle();
      if (readError || !data) {
        throw new Error(
          `extension grant read-back failed: ${readError?.code ?? "no row"}`,
        );
      }
      const row = data as {
        target_expires_at: string;
        patched_at: string | null;
      };
      return {
        targetExpiresAt: row.target_expires_at,
        patchedAt: row.patched_at,
      } as ExtensionGrant;
    },
    async markExtensionPatched(licenseID, major) {
      const { error } = await db
        .from("trial_extension_grants")
        .update({ patched_at: nowIso() })
        .eq("keygen_license_id", licenseID)
        .eq("major", major)
        .is("patched_at", null);
      if (error) {
        throw new Error(`mark extension patched failed: ${error.code}`);
      }
    },
    async touchCheckIn(licenseID) {
      const { error } = await db
        .from("device_trials")
        .update({ last_check_in_at: nowIso(), updated_at: nowIso() })
        .eq("keygen_license_id", licenseID);
      if (error) throw new Error(`touch check-in failed: ${error.code}`);
    },
  };
}

function purchaseStore(db: SupabaseClient): PurchaseStore {
  return {
    async exists(orderID) {
      const { data, error } = await db
        .from("purchases")
        .select("ls_order_id")
        .eq("ls_order_id", orderID)
        .maybeSingle();
      if (error) throw new Error(`purchase lookup failed: ${error.code}`);
      return data !== null;
    },
    async record(
      { orderID, licenseID, email, variantID, purchasedMajor, entitlementCode },
    ) {
      const { error } = await db.from("purchases").insert({
        ls_order_id: orderID,
        keygen_license_id: licenseID,
        email,
        ls_variant_id: variantID,
        purchased_major: purchasedMajor,
        entitlement_code: entitlementCode,
      });
      if (!error || error.code === "23505") return; // success or duplicate (idempotent)
      if (error.code === "23503") {
        throw new PurchaseForgedLicenseError(`order ${orderID}`); // FK: forged id — ack 200
      }
      throw new Error(`record failed: ${error.code}`); // transient — caller returns 500 to retry
    },
  };
}

/** A JSON:API resource narrowed to the fields the adapter reads. */
interface KeygenResource {
  id?: string;
  attributes?: Record<string, unknown>;
}

function keygenAdmin(): KeygenAdmin {
  const account = env("KEYGEN_ACCOUNT");
  const token = env("KEYGEN_TOKEN");
  // I7: a missing V0 entitlement id must fail at boot, never ship a paid license
  // with no major stamp.
  const v0EntitlementID = env("KEYGEN_V0_ENTITLEMENT");
  const adminHeaders = {
    "Authorization": `Bearer ${token}`,
    "Content-Type": JSON_API_CONTENT_TYPE,
    "Accept": JSON_API_CONTENT_TYPE,
  };
  const licenseHeaders = (key: string) => ({
    "Authorization": `License ${key}`,
    "Content-Type": JSON_API_CONTENT_TYPE,
    "Accept": JSON_API_CONTENT_TYPE,
  });
  const accountPath = `${KEYGEN_BASE_URL}/v1/accounts/${account}`;

  async function machineForFingerprint(
    licenseID: string,
    fingerprint: string,
  ): Promise<string | null> {
    const response = await timedFetch(
      `${accountPath}/licenses/${encodeURIComponent(licenseID)}/machines`,
      { headers: adminHeaders },
    );
    // A transient list failure must NOT read as "no machine found" — that would let
    // activateMachine raise a false KeygenMachineLimitError and lock out the real
    // device. Throw so the caller surfaces a retryable error instead.
    if (!response.ok) {
      throw new Error(`keygen list machines ${response.status}`);
    }
    const json = await response.json();
    const machines =
      (Array.isArray(json.data) ? json.data : []) as KeygenResource[];
    const match = machines.find((m) =>
      m.attributes?.fingerprint === fingerprint
    );
    return match?.id ?? null;
  }

  return {
    async createTrialLicense() {
      const expiry = new Date(Date.now() + TRIAL_DURATION_MS).toISOString();
      const response = await timedFetch(`${accountPath}/licenses`, {
        method: "POST",
        headers: adminHeaders,
        body: JSON.stringify({
          data: {
            type: "licenses",
            attributes: { expiry },
            relationships: {
              policy: {
                data: { type: "policies", id: env("KEYGEN_TRIAL_POLICY") },
              },
            },
          },
        }),
      });
      if (!response.ok) throw new Error(`keygen create ${response.status}`);
      const json = await response.json();
      return {
        id: String(json.data.id),
        key: String(json.data.attributes.key),
      };
    },
    async upgradeToPaid(licenseID) {
      const encodedID = encodeURIComponent(licenseID);
      const policyResponse = await timedFetch(
        `${accountPath}/licenses/${encodedID}/policy`,
        {
          method: "PUT",
          headers: adminHeaders,
          body: JSON.stringify({
            data: { type: "policies", id: env("KEYGEN_PAID_POLICY") },
          }),
        },
      );
      if (policyResponse.status === 404) {
        throw new KeygenLicenseNotFoundError(`license ${licenseID}`);
      }
      if (!policyResponse.ok) {
        throw new Error(`keygen policy ${policyResponse.status}`);
      }
      // The policy swap leaves the trial expiry; clear it to perpetual (idempotent).
      const expiryResponse = await timedFetch(
        `${accountPath}/licenses/${encodedID}`,
        {
          method: "PATCH",
          headers: adminHeaders,
          body: JSON.stringify({
            data: { type: "licenses", attributes: { expiry: null } },
          }),
        },
      );
      if (expiryResponse.status === 404) {
        throw new KeygenLicenseNotFoundError(`license ${licenseID}`);
      }
      if (!expiryResponse.ok) {
        throw new Error(`keygen expiry ${expiryResponse.status}`);
      }
    },
    async attachV0(licenseID) {
      const response = await timedFetch(
        `${accountPath}/licenses/${encodeURIComponent(licenseID)}/entitlements`,
        {
          method: "POST",
          headers: adminHeaders,
          body: JSON.stringify({
            data: [{ type: "entitlements", id: v0EntitlementID }],
          }),
        },
      );
      if (response.ok) {
        await response.body?.cancel();
        return;
      }
      const status = response.status;
      const bodyText = await response.text().catch(() => "");
      if (status === 404) {
        throw new KeygenLicenseNotFoundError(`license ${licenseID}`);
      }
      // "Already attached" is idempotent success (a webhook retry re-runs this).
      // Keygen signals a duplicate relationship with 400/409/422 + an "...has already
      // been taken / exists" error — treat ONLY that as success, so a genuine
      // malformed request still surfaces (throws → 500 → LS retries) rather than
      // silently shipping a paid license with no STOWER_V0 (I7).
      if (
        (status === 400 || status === 409 || status === 422) &&
        isDuplicateRelationship(bodyText)
      ) {
        return;
      }
      throw new Error(`keygen attach ${status}`);
    },
    async activateMachine(licenseID, licenseKey, fingerprint) {
      const response = await timedFetch(`${accountPath}/machines`, {
        method: "POST",
        headers: licenseHeaders(licenseKey),
        body: JSON.stringify({
          data: {
            type: "machines",
            attributes: { fingerprint },
            relationships: {
              license: { data: { type: "licenses", id: licenseID } },
            },
          },
        }),
      });
      if (response.status === 201) {
        const json = await response.json();
        return String(json.data.id);
      }
      // A conflict is either THIS fingerprint already activated (reuse it) or a true
      // maxMachines:1 conflict by a DIFFERENT device (a real seat limit).
      if (response.status === 422 || response.status === 409) {
        await response.body?.cancel();
        const existing = await machineForFingerprint(licenseID, fingerprint);
        if (existing) return existing;
        throw new KeygenMachineLimitError(`license ${licenseID} seat taken`);
      }
      await response.body?.cancel();
      throw new Error(`keygen activate ${response.status}`);
    },
    async checkoutMachineFile(machineID) {
      const query = new URLSearchParams({
        ttl: String(MACHINE_FILE_TTL_SECONDS),
        algorithm: MACHINE_FILE_ALGORITHM,
        include: MACHINE_FILE_INCLUDE,
      });
      // Admin auth, NOT license-key auth: a license-scoped token is forbidden (403)
      // from embedding `include=license.entitlements,license.policy,license` in the
      // machine file. The Edge Function holds the admin token and the file is
      // Ed25519-signed regardless of which token requests it.
      const response = await timedFetch(
        `${accountPath}/machines/${
          encodeURIComponent(machineID)
        }/actions/check-out?${query}`,
        { method: "POST", headers: adminHeaders },
      );
      if (!response.ok) throw new Error(`keygen checkout ${response.status}`);
      const json = await response.json();
      const certificate = (json.data as KeygenResource)?.attributes
        ?.certificate;
      if (typeof certificate !== "string") {
        throw new Error("keygen checkout: no certificate");
      }
      return certificate;
    },
    async validate(licenseKey, fingerprint): Promise<KeygenValidation> {
      const response = await timedFetch(
        `${accountPath}/licenses/actions/validate-key`,
        {
          method: "POST",
          headers: adminHeaders,
          body: JSON.stringify({
            meta: { key: licenseKey, scope: { fingerprint } },
          }),
        },
      );
      if (!response.ok) throw new Error(`keygen validate ${response.status}`);
      const json = await response.json();
      const meta = json.meta ?? {};
      return {
        valid: meta.valid === true,
        code: meta.code ? String(meta.code) : null,
      };
    },
    async effectiveEntitlements(licenseID) {
      const query = new URLSearchParams({
        limit: String(KEYGEN_ENTITLEMENTS_PAGE_SIZE),
      });
      const response = await timedFetch(
        `${accountPath}/licenses/${
          encodeURIComponent(licenseID)
        }/entitlements?${query}`,
        { headers: adminHeaders },
      );
      if (!response.ok) {
        throw new Error(`keygen entitlements ${response.status}`);
      }
      const json = await response.json();
      const data =
        (Array.isArray(json.data) ? json.data : []) as KeygenResource[];
      return data
        .map((e) => e.attributes?.code)
        .filter((code): code is string => typeof code === "string");
    },
    async currentExpiry(licenseID) {
      const response = await timedFetch(
        `${accountPath}/licenses/${encodeURIComponent(licenseID)}`,
        { headers: adminHeaders },
      );
      if (!response.ok) throw new Error(`keygen license ${response.status}`);
      const json = await response.json();
      const expiry = (json.data as KeygenResource)?.attributes?.expiry;
      return typeof expiry === "string" ? expiry : null;
    },
    async patchExpiry(licenseID, iso) {
      const response = await timedFetch(
        `${accountPath}/licenses/${encodeURIComponent(licenseID)}`,
        {
          method: "PATCH",
          headers: adminHeaders,
          body: JSON.stringify({
            data: { type: "licenses", attributes: { expiry: iso } },
          }),
        },
      );
      if (!response.ok) {
        throw new Error(`keygen patch expiry ${response.status}`);
      }
      await response.body?.cancel();
    },
  };
}

async function verifyLemonSqueezySignature(
  rawBody: string,
  signature: string,
): Promise<boolean> {
  const secret = env("LS_WEBHOOK_SECRET");
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(rawBody),
  );
  const expected = [...new Uint8Array(mac)].map((b) =>
    b.toString(16).padStart(2, "0")
  ).join("");
  return timingSafeEqualHex(expected, signature);
}

function mintDeps(): MintDeps {
  return {
    trials: trialStore(supabase()),
    keygen: keygenAdmin(),
    now: () => Date.now(),
    reclaimWindowMs: RECLAIM_WINDOW_MS,
  };
}

function webhookDeps(): WebhookDeps {
  const db = supabase();
  return {
    purchases: purchaseStore(db),
    keygen: keygenAdmin(),
    verifySignature: verifyLemonSqueezySignature,
    paidVariantID: env("LS_PAID_VARIANT_ID"),
    async licenseIsMinted(licenseID) {
      const { data, error } = await db
        .from("device_trials")
        .select("keygen_license_id")
        .eq("keygen_license_id", licenseID)
        .maybeSingle();
      if (error) throw new Error(`license lookup failed: ${error.code}`);
      return data !== null;
    },
  };
}

// The GitHub releases cache is module-level so it stays warm across invocations on
// the same instance (the 5-minute TTL then actually amortizes).
const githubCache = emptyGithubCache();

/** Builds the GitHub releases adapter, or a null adapter when GITHUB_REPO is unset. */
function githubAdapter(): CheckInDeps["github"] {
  const repo = Deno.env.get("GITHUB_REPO");
  if (!repo) {
    // No repo configured → no "latest major" signal → extension simply skipped.
    return {
      currentLatestMajor: () => Promise.resolve(null),
      stableReleases: () => Promise.resolve([] as StableRelease[]),
    };
  }
  const apiBase = Deno.env.get("GITHUB_API_BASE") || GITHUB_DEFAULT_API_BASE;
  const headers: Record<string, string> = {
    "User-Agent": "stower-license-edge",
    "Accept": "application/vnd.github+json",
  };
  const githubToken = Deno.env.get("GITHUB_TOKEN");
  if (githubToken) headers["Authorization"] = `Bearer ${githubToken}`;
  return githubReleases({
    fetch: globalThis.fetch.bind(globalThis),
    now: () => Date.now(),
    releasesUrl:
      `${apiBase}/repos/${repo}/releases?per_page=${GITHUB_RELEASES_PAGE_SIZE}`,
    headers,
    cache: githubCache,
    cacheTtlMs: GITHUB_CACHE_TTL_MS,
    fetchTimeoutMs: OUTBOUND_FETCH_TIMEOUT_MS,
    log: (message) => console.log(message), // non-secret: only a major-version string
  });
}

function checkInDeps(request: Request, rawBody: string): CheckInDeps {
  const headers = extractSignatureHeaders(request.headers);
  return {
    trials: trialStore(supabase()),
    keygen: keygenAdmin(),
    github: githubAdapter(),
    verifySignature: async (key: string) => {
      const result = await verifyRequestSignature({
        method: request.method,
        path: CHECK_IN_SIGNING_PATH,
        timestamp: headers.timestamp,
        nonce: headers.nonce,
        signature: headers.signature,
        rawBody,
        key,
        nowMs: Date.now(),
      });
      if (!result.ok) {
        // The diagnostic is non-secret by construction (no key/body/full signature).
        console.warn(`check-in signature rejected: ${result.diagnostic}`);
      }
      return result;
    },
  };
}

function jsonResponse(reply: Reply): Response {
  return new Response(JSON.stringify(reply.body ?? {}), {
    status: reply.status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Parses the JSON body to a record, or an empty object on any parse failure. */
async function readJson(request: Request): Promise<Record<string, unknown>> {
  try {
    const parsed = await request.json();
    return (parsed ?? {}) as Record<string, unknown>;
  } catch {
    return {};
  }
}

Deno.serve(async (request: Request) => {
  const path = new URL(request.url).pathname;

  if (request.method === "GET" && path.endsWith("/health")) {
    // Deploy-readiness canary: report any unset REQUIRED env by NAME (never values,
    // no DB/secret dependency). One curl after deploy tells you what you forgot.
    const missingEnv = missingRequiredEnv((name) => Deno.env.get(name));
    if (missingEnv.length > 0) {
      return jsonResponse({
        status: 503,
        body: { status: "degraded", missingEnv },
      });
    }
    return jsonResponse({ status: 200, body: { status: "ok" } });
  }

  if (request.method === "POST" && path.endsWith("/mint-trial")) {
    const body = await readJson(request);
    const req: MintRequest = { fingerprint: String(body.fingerprint ?? "") };
    try {
      return jsonResponse(await mintTrial(mintDeps(), req));
    } catch (_error) {
      return jsonResponse({ status: 503, body: { error: "retry" } }); // unexpected — app retries
    }
  }

  if (request.method === "POST" && path.endsWith("/check-in")) {
    const rawBody = await request.text();
    let parsed: Record<string, unknown>;
    try {
      parsed = (JSON.parse(rawBody || "{}") ?? {}) as Record<string, unknown>;
    } catch {
      parsed = {};
    }
    const req: CheckInRequest = {
      licenseID: String(parsed.licenseID ?? ""),
      fingerprint: String(parsed.fingerprint ?? ""),
    };
    try {
      return jsonResponse(await checkIn(checkInDeps(request, rawBody), req));
    } catch (_error) {
      // A DB/Keygen surface error becomes a retryable 503 (couldNotReach), never a
      // false verdict. No secret is logged.
      return jsonResponse({ status: 503, body: { status: "retry_shortly" } });
    }
  }

  if (request.method === "POST" && path.endsWith("/ls-webhook")) {
    const rawBody = await request.text();
    const signature = request.headers.get("X-Signature") ?? "";
    try {
      return jsonResponse(
        await handleWebhook(webhookDeps(), rawBody, signature),
      );
    } catch (_error) {
      return jsonResponse({ status: 500 }); // unexpected — Lemon Squeezy retries (idempotent)
    }
  }

  return new Response("not found", { status: 404 });
});
