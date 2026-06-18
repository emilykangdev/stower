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
      const { error } = await db
        .from("device_trials")
        .insert({ fingerprint, status: "pending" });
      if (!error) return true;
      if (error.code === "23505") return false; // unique_violation — lost the claim
      throw new Error(`claim failed: ${error.code}`);
    },
    async get(fingerprint) {
      const { data } = await db
        .from("device_trials")
        .select("status, keygen_license_id, keygen_license_key, created_at")
        .eq("fingerprint", fingerprint)
        .maybeSingle();
      return (data as TrialRow | null) ?? null;
    },
    async activate(fingerprint, licenseID, licenseKey) {
      const { error } = await db
        .from("device_trials")
        .update({
          status: "active",
          keygen_license_id: licenseID,
          keygen_license_key: licenseKey,
        })
        .eq("fingerprint", fingerprint);
      if (error) throw new Error(`activate failed: ${error.code}`);
    },
    async releaseClaim(fingerprint) {
      await db
        .from("device_trials")
        .delete()
        .eq("fingerprint", fingerprint)
        .eq("status", "pending");
    },
  };
}

function purchaseStore(db: SupabaseClient): PurchaseStore {
  return {
    async exists(orderID) {
      const { data } = await db
        .from("purchases")
        .select("ls_order_id")
        .eq("ls_order_id", orderID)
        .maybeSingle();
      return data !== null;
    },
    async record({ orderID, licenseID, email, variantID }) {
      const { error } = await db.from("purchases").insert({
        ls_order_id: orderID,
        keygen_license_id: licenseID,
        email,
        ls_variant_id: variantID,
      });
      if (error && error.code !== "23505") {
        throw new Error(`record failed: ${error.code}`); // FK (23503) bubbles to the caller's 200
      }
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
      const response = await fetch(
        `${KEYGEN_BASE_URL}/v1/accounts/${account}/licenses/${licenseID}/policy`,
        {
          method: "PUT",
          headers: authHeaders,
          body: JSON.stringify({
            data: { type: "policies", id: env("KEYGEN_PAID_POLICY") },
          }),
        },
      );
      if (response.status === 404) {
        throw new KeygenLicenseNotFoundError(`license ${licenseID}`);
      }
      if (!response.ok) throw new Error(`keygen policy ${response.status}`);
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
  return {
    purchases: purchaseStore(supabase()),
    keygen: keygenAdmin(),
    verifySignature: verifyLemonSqueezySignature,
    paidVariantID: env("LS_PAID_VARIANT_ID"),
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
    return jsonResponse(await mintTrial(mintDeps(), fingerprint));
  }
  if (request.method === "POST" && path.endsWith("/ls-webhook")) {
    const rawBody = await request.text();
    const signature = request.headers.get("X-Signature") ?? "";
    return jsonResponse(await handleWebhook(webhookDeps(), rawBody, signature));
  }
  return new Response("not found", { status: 404 });
});
