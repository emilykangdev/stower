// HTTP entrypoint for the `license` Edge Function. Routes `/mint-trial` and
// `/ls-webhook`, wiring the real Postgres / Keygen / Lemon Squeezy
// implementations into the pure handlers (handlers.ts). All secrets are read
// from Deno.env here and never logged; logs carry only non-secret ids.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import {
  handleWebhook,
  type KeygenAdmin,
  KeygenLicenseNotFoundError,
  type MintDeps,
  mintTrial,
  PurchaseForgedLicenseError,
  type PurchaseStore,
  type Reply,
  type TrialRow,
  type TrialStore,
  type WebhookDeps,
} from "./handlers.ts";

const KEYGEN_BASE_URL = "https://api.keygen.sh";
const TRIAL_DURATION_MS = 30 * 24 * 60 * 60 * 1000; // 30-day trial
const RECLAIM_WINDOW_MS = 60 * 1000; // abandoned 'pending' claim age
const JSON_API_CONTENT_TYPE = "application/vnd.api+json";

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing env ${name}`);
  return value;
}

function supabase(): SupabaseClient {
  return createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
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
        .select("status, keygen_license_id, keygen_license_key, created_at")
        .eq("fingerprint", fingerprint)
        .maybeSingle();
      if (error) throw new Error(`trial lookup failed: ${error.code}`); // never mask a DB error as no-row
      return (data as TrialRow | null) ?? null;
    },
    async activate(fingerprint, claimToken, licenseID, licenseKey) {
      const { data, error } = await db
        .from("device_trials")
        .update({
          status: "active",
          keygen_license_id: licenseID,
          keygen_license_key: licenseKey,
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
      if (error) throw new Error(`purchase lookup failed: ${error.code}`); // never mask a DB error as no-row
      return data !== null;
    },
    async record({ orderID, licenseID, email, variantID }) {
      const { error } = await db.from("purchases").insert({
        ls_order_id: orderID,
        keygen_license_id: licenseID,
        email,
        ls_variant_id: variantID,
      });
      if (!error || error.code === "23505") return; // success or duplicate (idempotent)
      if (error.code === "23503") {
        throw new PurchaseForgedLicenseError(`order ${orderID}`); // FK: forged id — ack 200
      }
      throw new Error(`record failed: ${error.code}`); // transient — caller returns 500 to retry
    },
  };
}

function keygenAdmin(): KeygenAdmin {
  const account = env("KEYGEN_ACCOUNT");
  const token = env("KEYGEN_TOKEN");
  const authHeaders = {
    "Authorization": `Bearer ${token}`,
    "Content-Type": JSON_API_CONTENT_TYPE,
    "Accept": JSON_API_CONTENT_TYPE,
  };
  return {
    async createTrialLicense() {
      const expiry = new Date(Date.now() + TRIAL_DURATION_MS).toISOString();
      const response = await fetch(
        `${KEYGEN_BASE_URL}/v1/accounts/${account}/licenses`,
        {
          method: "POST",
          headers: authHeaders,
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
        },
      );
      if (!response.ok) throw new Error(`keygen create ${response.status}`);
      const json = await response.json();
      return {
        id: String(json.data.id),
        key: String(json.data.attributes.key),
      };
    },
    async upgradeToPaid(licenseID) {
      const encodedID = encodeURIComponent(licenseID);
      const policyResponse = await fetch(
        `${KEYGEN_BASE_URL}/v1/accounts/${account}/licenses/${encodedID}/policy`,
        {
          method: "PUT",
          headers: authHeaders,
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
      // The policy swap alone leaves the now+30d trial expiry, so a paid (one-time
      // purchase) license would still expire. Clear it to perpetual. Idempotent, so
      // a webhook retry re-running this is harmless.
      const expiryResponse = await fetch(
        `${KEYGEN_BASE_URL}/v1/accounts/${account}/licenses/${encodedID}`,
        {
          method: "PATCH",
          headers: authHeaders,
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
  return timingSafeEqual(expected, signature);
}

/** Constant-time compare of two equal-length hex strings; false on a length mismatch. */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
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
      if (error) throw new Error(`license lookup failed: ${error.code}`); // surface DB errors; false means a real no-row
      return data !== null;
    },
  };
}

function jsonResponse(reply: Reply): Response {
  return new Response(JSON.stringify(reply.body ?? {}), {
    status: reply.status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (request: Request) => {
  const path = new URL(request.url).pathname;
  if (request.method === "POST" && path.endsWith("/mint-trial")) {
    const fingerprint = String(
      (await request.json().catch(() => ({})))?.fingerprint ?? "",
    );
    try {
      return jsonResponse(await mintTrial(mintDeps(), fingerprint));
    } catch (_error) {
      return jsonResponse({ status: 503, body: { error: "retry" } }); // unexpected — app retries
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
      return jsonResponse({ status: 500 }); // unexpected — Lemon Squeezy retries (idempotent upgrade)
    }
  }
  return new Response("not found", { status: 404 });
});
