// Remote-testing Keygen provisioner. Creates the Trial + Paid policies, the
// STOWER_TRIAL / STOWER_V0 entitlements, and the STOWER_TRIAL→Trial-policy
// attachment UNDER AN EXISTING PRODUCT whose id you pass in (e.g. "StowerTest" on
// your real Keygen Cloud account). Deliberately separate from the CI Docker harness
// (bootstrap-keygen.ts / docker-compose) — this one targets a real account and a
// product you already made, and takes the product id instead of creating it.
//
// Idempotent: reruns reuse existing matches (find-or-create), so it is safe to run
// repeatedly. Fails loudly on a missing product id or a Keygen error — never a
// silent skip. The product token is read into the Authorization header and is never
// logged or printed.
//
// Auth is a Keygen PRODUCT token (Bearer). Policies are product-scoped, so a product
// token creates them fine. Entitlements are account-level (`entitlement.create`): a
// default-permission product token has it, but a scoped-down token will 403 on that
// step — if so, create the STOWER_TRIAL / STOWER_V0 entitlements once with an admin
// token (or in the dashboard) and rerun; find-or-create then just reuses them.
//
// The JSON:API request shapes mirror Scripts/Keygen/bootstrap-keygen.ts, which is
// tested against a real Keygen CE — so these payloads are known-good.
//
// Run (Deno's own env loading):
//   deno run --allow-env --allow-net=api.keygen.sh \
//     --env-file=Scripts/Keygen/remote-testing/.env \
//     Scripts/Keygen/remote-testing/create-policies.ts
//
// …or with dotenvx:
//   dotenvx run -f Scripts/Keygen/remote-testing/.env -- \
//     deno run --allow-env --allow-net=api.keygen.sh \
//     Scripts/Keygen/remote-testing/create-policies.ts
//
// Required env: KEYGEN_ACCOUNT, KEYGEN_PRODUCT_TOKEN, KEYGEN_PRODUCT_ID.
// Optional:     KEYGEN_BASE_URL (default https://api.keygen.sh).
//               KEYGEN_PRODUCT_ID may also be passed as the first CLI arg.

const DEFAULT_BASE_URL = "https://api.keygen.sh";
const JSON_API_CONTENT_TYPE = "application/vnd.api+json";
const LIST_PAGE_SIZE = 100; // Keygen caps list pages at 100 records.
const TRIAL_DURATION_SECONDS = 2_592_000; // 30 days — the Trial policy's license lifetime.

const TRIAL_POLICY_NAME = "STOWER_TRIAL_POLICY";
const PAID_POLICY_NAME = "STOWER_PAID_POLICY";
const TRIAL_ENTITLEMENT_CODE = "STOWER_TRIAL";
const V0_ENTITLEMENT_CODE = "STOWER_V0";

// Both policies share these; only the trial `duration` and the paid
// `transferStrategy` differ. `ED25519_SIGN` makes Keygen sign each license key so
// the app verifies offline; `LICENSE` lets the key authenticate; `maxMachines: 1`
// + `UNIQUE_PER_PRODUCT` is one device per license across the product.
const SHARED_POLICY_ATTRS = {
  scheme: "ED25519_SIGN",
  authenticationStrategy: "LICENSE",
  maxMachines: 1,
  machineUniquenessStrategy: "UNIQUE_PER_PRODUCT",
} as const;

/** A JSON:API resource, narrowed to the fields this script reads. */
interface KeygenResource {
  id: string;
  type: string;
  attributes?: Record<string, unknown>;
  relationships?: Record<string, { data?: { type?: string; id?: string } | null }>;
}

interface ListResponse {
  data?: KeygenResource[];
  links?: { next?: string | null };
}

/** Reads required env (or a CLI arg for the product id); exits loudly if absent. */
function readConfig(): {
  baseUrl: string;
  account: string;
  productId: string;
  authHeaders: Record<string, string>;
} {
  const account = Deno.env.get("KEYGEN_ACCOUNT");
  const token = Deno.env.get("KEYGEN_PRODUCT_TOKEN");
  const productId = Deno.env.get("KEYGEN_PRODUCT_ID") ?? Deno.args[0];
  if (!account) fail("missing env KEYGEN_ACCOUNT");
  if (!token) fail("missing env KEYGEN_PRODUCT_TOKEN");
  if (!productId) {
    fail("missing KEYGEN_PRODUCT_ID (env or first CLI arg) — pass StowerTest's product id");
  }
  return {
    baseUrl: Deno.env.get("KEYGEN_BASE_URL") || DEFAULT_BASE_URL,
    account: account as string,
    productId: productId as string,
    authHeaders: {
      "Authorization": `Bearer ${token}`,
      "Content-Type": JSON_API_CONTENT_TYPE,
      "Accept": JSON_API_CONTENT_TYPE,
    },
  };
}

/** Prints a message to stderr and exits non-zero — the single failure path. */
function fail(message: string): never {
  console.error(`ERROR: ${message}`);
  Deno.exit(1);
}

/** A thin Keygen JSON:API client over `fetch`. */
function keygenClient(config: ReturnType<typeof readConfig>) {
  const base = `/v1/accounts/${config.account}`;
  const toURL = (path: string) =>
    path.startsWith("http") ? path : `${config.baseUrl}${path}`;

  async function send(method: string, path: string, body?: unknown): Promise<Response> {
    return await fetch(toURL(path), {
      method,
      headers: config.authHeaders,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  }

  // Collects every resource, following `links.next` so a >1-page result is never
  // silently truncated. Keygen 400s on `page[size]` unless `page[number]` is sent.
  async function listAll(collection: string): Promise<KeygenResource[]> {
    const out: KeygenResource[] = [];
    let path: string | null =
      `${base}/${collection}?page[number]=1&page[size]=${LIST_PAGE_SIZE}`;
    while (path) {
      const response = await send("GET", path);
      if (!response.ok) fail(`keygen list ${collection} ${response.status}`);
      const json = (await response.json()) as ListResponse;
      for (const resource of json.data ?? []) out.push(resource);
      const next = json.links?.next;
      path = typeof next === "string" && next.length > 0 ? next : null;
    }
    return out;
  }

  async function create(collection: string, body: unknown): Promise<KeygenResource> {
    const response = await send("POST", `${base}/${collection}`, body);
    if (!response.ok) {
      const detail = await response.text().catch(() => "");
      fail(`keygen create ${collection} ${response.status} ${detail}`);
    }
    const json = (await response.json()) as { data: KeygenResource };
    return json.data;
  }

  return { base, send, listAll, create };
}

type KeygenClient = ReturnType<typeof keygenClient>;

/** Verifies the given product id exists; a typo'd id must fail, not orphan policies. */
async function assertProductExists(client: KeygenClient, productId: string): Promise<void> {
  const response = await client.send("GET", `${client.base}/products/${productId}`);
  if (response.status === 404) {
    await response.body?.cancel();
    fail(`product ${productId} not found in this account — check the id`);
  }
  if (!response.ok) fail(`keygen get product ${response.status}`);
  await response.body?.cancel();
}

/** Finds a policy by name *under this product*, else creates it with exact rules. */
async function findOrCreatePolicy(
  client: KeygenClient,
  productId: string,
  name: string,
  variableAttrs: Record<string, unknown>,
): Promise<KeygenResource> {
  const existing = (await client.listAll("policies")).find(
    (p) =>
      p.attributes?.name === name &&
      p.relationships?.product?.data?.id === productId,
  );
  if (existing) return existing;
  return await client.create("policies", {
    data: {
      type: "policies",
      attributes: { name, ...SHARED_POLICY_ATTRS, ...variableAttrs },
      relationships: { product: { data: { type: "products", id: productId } } },
    },
  });
}

/** Finds an entitlement by code (account-level), else creates it (name == code). */
async function findOrCreateEntitlement(
  client: KeygenClient,
  code: string,
): Promise<KeygenResource> {
  const existing = (await client.listAll("entitlements")).find(
    (e) => e.attributes?.code === code,
  );
  if (existing) return existing;
  return await client.create("entitlements", {
    data: { type: "entitlements", attributes: { name: code, code } },
  });
}

/** Attaches the Trial entitlement to the Trial policy if not already attached. */
async function ensureTrialAttached(
  client: KeygenClient,
  trialPolicyId: string,
  trialEntitlementId: string,
): Promise<void> {
  const collection = `policies/${trialPolicyId}/entitlements`;
  const attached = (await client.listAll(collection)).some(
    (e) => e.id === trialEntitlementId,
  );
  if (attached) return;
  const response = await client.send("POST", `${client.base}/${collection}`, {
    data: [{ type: "entitlements", id: trialEntitlementId }],
  });
  await response.body?.cancel();
  if (!response.ok) fail(`keygen attach trial entitlement ${response.status}`);
}

const config = readConfig();
const client = keygenClient(config);

await assertProductExists(client, config.productId);
const trialPolicy = await findOrCreatePolicy(client, config.productId, TRIAL_POLICY_NAME, {
  duration: TRIAL_DURATION_SECONDS,
});
const paidPolicy = await findOrCreatePolicy(client, config.productId, PAID_POLICY_NAME, {
  transferStrategy: "RESET_EXPIRY",
});
const trialEntitlement = await findOrCreateEntitlement(client, TRIAL_ENTITLEMENT_CODE);
const v0Entitlement = await findOrCreateEntitlement(client, V0_ENTITLEMENT_CODE);
await ensureTrialAttached(client, trialPolicy.id, trialEntitlement.id);

// The ids you set as the Edge Function's KEYGEN_* secrets. STOWER_V0 is created but
// NEVER attached to a policy — the webhook attaches it per paid license on purchase.
const output = {
  account: config.account,
  productId: config.productId,
  trialPolicyId: trialPolicy.id,
  paidPolicyId: paidPolicy.id,
  trialEntitlementId: trialEntitlement.id,
  v0EntitlementId: v0Entitlement.id,
};
console.log(JSON.stringify(output, null, 2));
console.error("Set the Edge Function secrets from the ids above:");
console.error(`  KEYGEN_TRIAL_POLICY=${output.trialPolicyId}`);
console.error(`  KEYGEN_PAID_POLICY=${output.paidPolicyId}`);
console.error(`  KEYGEN_V0_ENTITLEMENT=${output.v0EntitlementId}`);
console.error("  (KEYGEN_TRIAL is policy-attached, no env var needed.)");
