// One-shot, idempotent bootstrap for the Keygen structures Stower's licensing
// contract (Docs/licensing-contract.md v1.12) requires: the `Stower` product, the
// Trial and Paid policies, the `STOWER_TRIAL` and `STOWER_V0` entitlements, and
// the policy-level `STOWER_TRIAL` attachment. It NEVER attaches `STOWER_V0` to a
// policy or license — Plan Beta's Railway webhook attaches `STOWER_V0` directly to
// each paid license on purchase. Safe to rerun against sandbox/test or production
// accounts: existing matches are reused, never duplicated.
//
// Every side effect (HTTP, env, stdout, stderr) is injected so the Deno tests run
// with no network, disk, or env. `import.meta.main` wires the real Deno
// implementations. The Keygen token is read into the Authorization header and is
// never logged or printed.

const DEFAULT_BASE_URL = "https://api.keygen.sh";
const JSON_API_CONTENT_TYPE = "application/vnd.api+json";
const LIST_PAGE_SIZE = 100; // Keygen caps list pages at 100 records.
const TRIAL_DURATION_SECONDS = 2_592_000; // 30 days — the Trial policy's license lifetime.

/** The product the licensing contract names. */
const PRODUCT = { name: "Stower", code: "stower" } as const;
const TRIAL_POLICY_NAME = "STOWER_TRIAL_POLICY";
const PAID_POLICY_NAME = "STOWER_PAID_POLICY";
const TRIAL_ENTITLEMENT_CODE = "STOWER_TRIAL";
const V0_ENTITLEMENT_CODE = "STOWER_V0";

// Both policies share these rules; only duration (trial) and transferStrategy
// (paid) differ. `scheme: ED25519_SIGN` makes Keygen sign each license key so the
// Mac app can verify offline; `authenticationStrategy: LICENSE` lets the license
// key itself authenticate; `maxMachines: 1` + `UNIQUE_PER_PRODUCT` is one device
// per license across the product.
const SHARED_POLICY_ATTRS = {
  scheme: "ED25519_SIGN",
  authenticationStrategy: "LICENSE",
  maxMachines: 1,
  machineUniquenessStrategy: "UNIQUE_PER_PRODUCT",
} as const;

/** The seams the script needs from the host; faked wholesale in the tests. */
export interface BootstrapDeps {
  fetch: typeof globalThis.fetch;
  getEnv: (name: string) => string | undefined;
  stdout: (line: string) => void;
  stderr: (line: string) => void;
}

/** The ids Plan Beta / prod ops consume; printed to stdout as JSON. */
export interface BootstrapOutput {
  baseUrl: string;
  account: string;
  productId: string;
  trialPolicyId: string;
  paidPolicyId: string;
  trialEntitlementId: string;
  v0EntitlementId: string;
}

/** A JSON:API resource, narrowed to the fields this script reads. */
interface KeygenResource {
  id: string;
  type: string;
  attributes?: Record<string, unknown>;
  relationships?: Record<
    string,
    { data?: { type?: string; id?: string } | null }
  >;
}

interface ListResponse {
  data?: KeygenResource[];
  links?: { next?: string | null };
}

interface SingleResponse {
  data: KeygenResource;
}

/** Resolved auth/account context. The token lives only in `authHeaders`. */
interface Config {
  baseUrl: string;
  account: string;
  authHeaders: Record<string, string>;
}

/** Reads + validates env. Missing account or token fails loudly (never a skip). */
function readConfig(deps: BootstrapDeps): Config {
  const account = deps.getEnv("KEYGEN_ACCOUNT");
  const token = deps.getEnv("KEYGEN_TOKEN");
  if (!account) throw new Error("missing env KEYGEN_ACCOUNT");
  if (!token) throw new Error("missing env KEYGEN_TOKEN");
  return {
    baseUrl: deps.getEnv("KEYGEN_BASE_URL") || DEFAULT_BASE_URL,
    account,
    authHeaders: {
      "Authorization": `Bearer ${token}`,
      "Content-Type": JSON_API_CONTENT_TYPE,
      "Accept": JSON_API_CONTENT_TYPE,
    },
  };
}

/** A thin Keygen JSON:API client over the injected `fetch`. */
function keygenClient(deps: BootstrapDeps, config: Config) {
  const base = `/v1/accounts/${config.account}`;
  const toURL = (path: string) =>
    path.startsWith("http") ? path : `${config.baseUrl}${path}`;

  async function send(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<Response> {
    return await deps.fetch(toURL(path), {
      method,
      headers: config.authHeaders,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  }

  // Collects every resource in a collection, following `links.next` so a result
  // set larger than one page is never silently truncated.
  async function listAll(collection: string): Promise<KeygenResource[]> {
    const out: KeygenResource[] = [];
    // Keygen 400s on `page[size]` unless `page[number]` is sent too (it defaults
    // the number to 0, which it rejects). Later pages come from `links.next`,
    // which already carries the correct params.
    let path: string | null =
      `${base}/${collection}?page[number]=1&page[size]=${LIST_PAGE_SIZE}`;
    while (path) {
      const response = await send("GET", path);
      if (!response.ok) {
        throw new Error(`keygen list ${collection} ${response.status}`);
      }
      const json = await response.json() as ListResponse;
      for (const resource of json.data ?? []) out.push(resource);
      const next = json.links?.next;
      path = typeof next === "string" && next.length > 0 ? next : null;
    }
    return out;
  }

  async function create(
    collection: string,
    body: unknown,
  ): Promise<KeygenResource> {
    const response = await send("POST", `${base}/${collection}`, body);
    if (!response.ok) {
      throw new Error(`keygen create ${collection} ${response.status}`);
    }
    const json = await response.json() as SingleResponse;
    return json.data;
  }

  return { base, send, listAll, create };
}

type KeygenClient = ReturnType<typeof keygenClient>;

/**
 * Fails loudly when an existing (reused) resource drifts from the attributes the
 * contract requires. The script must never emit a reused-but-wrong structure as
 * if it were correctly bootstrapped (Railway would consume the drifted id). We
 * compare only the attributes we positively set on create; an operator who edited
 * the resource in the Keygen dashboard must fix or delete it and rerun. We do not
 * auto-repair — mutating an existing live policy/license is out of this script's
 * scope.
 */
function assertConforms(
  kind: string,
  existing: KeygenResource,
  expected: Record<string, unknown>,
): void {
  const drifted = Object.entries(expected)
    .filter(([key, value]) =>
      JSON.stringify(existing.attributes?.[key]) !== JSON.stringify(value)
    )
    .map(([key]) => key);
  if (drifted.length > 0) {
    throw new Error(
      `existing ${kind} ${existing.id} drifts from the contract on: ` +
        `${drifted.join(", ")} — fix or delete it in Keygen, then rerun`,
    );
  }
}

/** Finds the `stower` product by code, else creates it. */
async function findOrCreateProduct(
  client: KeygenClient,
): Promise<KeygenResource> {
  const attributes = { name: PRODUCT.name, code: PRODUCT.code };
  const existing = (await client.listAll("products"))
    .find((p) => p.attributes?.code === PRODUCT.code);
  if (existing) {
    assertConforms("product", existing, attributes);
    return existing;
  }
  return await client.create("products", {
    data: { type: "products", attributes },
  });
}

/**
 * Finds a policy by name *under this product*, else creates it with exact rules.
 * The product scope matters: policies belong to a product, so on a shared account
 * a same-named policy under a different product must NOT be reused — that would
 * emit another product's policy id as Stower's. (Products and entitlements are
 * account-level with unique codes, so those match account-wide safely.)
 */
async function findOrCreatePolicy(
  client: KeygenClient,
  productID: string,
  name: string,
  variableAttrs: Record<string, unknown>,
): Promise<KeygenResource> {
  const attributes = { name, ...SHARED_POLICY_ATTRS, ...variableAttrs };
  const existing = (await client.listAll("policies"))
    .find((p) =>
      p.attributes?.name === name &&
      p.relationships?.product?.data?.id === productID
    );
  if (existing) {
    assertConforms("policy", existing, attributes);
    return existing;
  }
  return await client.create("policies", {
    data: {
      type: "policies",
      attributes,
      relationships: {
        product: { data: { type: "products", id: productID } },
      },
    },
  });
}

/** Finds an entitlement by code, else creates it (name == code). */
async function findOrCreateEntitlement(
  client: KeygenClient,
  code: string,
): Promise<KeygenResource> {
  const attributes = { name: code, code };
  const existing = (await client.listAll("entitlements"))
    .find((e) => e.attributes?.code === code);
  if (existing) {
    assertConforms("entitlement", existing, attributes);
    return existing;
  }
  return await client.create("entitlements", {
    data: { type: "entitlements", attributes },
  });
}

/**
 * Attaches the Trial entitlement to the Trial policy if it is not already
 * attached. The GET-first check makes a rerun a no-op (Keygen rejects a duplicate
 * attach), so the script stays idempotent. Returns true when it attached.
 */
async function ensureTrialAttached(
  client: KeygenClient,
  trialPolicyID: string,
  trialEntitlementID: string,
): Promise<boolean> {
  const collection = `policies/${trialPolicyID}/entitlements`;
  const alreadyAttached = (await client.listAll(collection))
    .some((e) => e.id === trialEntitlementID);
  if (alreadyAttached) return false;
  const response = await client.send("POST", `${client.base}/${collection}`, {
    data: [{ type: "entitlements", id: trialEntitlementID }],
  });
  // Consume the body even though we only read the status — an unread response
  // stream leaks (a connection in the Edge Function; a sanitizer failure under
  // Deno test). create()/listAll() consume via .json(); this attach path is the
  // one POST whose body we ignore, so cancel it explicitly.
  await response.body?.cancel();
  if (!response.ok) {
    throw new Error(`keygen attach trial entitlement ${response.status}`);
  }
  return true;
}

/**
 * Enforces the contract's hard invariant that `STOWER_V0` is a license-only
 * entitlement: it must never be attached to a policy (which would grant the paid
 * unlock to every license under that policy). The script never attaches it, but a
 * dashboard mistake or buggy prior run could have — so we actively check both
 * bootstrapped policies and fail loudly rather than report success over a forbidden
 * attachment.
 */
async function assertV0NotPolicyAttached(
  client: KeygenClient,
  policyIDs: string[],
  v0EntitlementID: string,
): Promise<void> {
  for (const policyID of policyIDs) {
    const attached = (await client.listAll(`policies/${policyID}/entitlements`))
      .some((e) => e.id === v0EntitlementID);
    if (attached) {
      throw new Error(
        `STOWER_V0 (${v0EntitlementID}) is attached to policy ${policyID} — ` +
          `it must be license-only; detach it in Keygen, then rerun`,
      );
    }
  }
}

/** Prints the recorded ids and the manual prod-ops reminders to stderr. */
function printSummary(deps: BootstrapDeps, output: BootstrapOutput): void {
  deps.stderr("Keygen bootstrap complete (ids also on stdout as JSON):");
  deps.stderr(`  product            ${output.productId}`);
  deps.stderr(`  trial policy       ${output.trialPolicyId}`);
  deps.stderr(`  paid policy        ${output.paidPolicyId}`);
  deps.stderr(`  trial entitlement  ${output.trialEntitlementId}`);
  deps.stderr(`  v0 entitlement     ${output.v0EntitlementId}`);
  deps.stderr("Next steps:");
  deps.stderr("  - Set the Railway licensing env vars from the JSON ids above.");
  deps.stderr(
    "  - During prod ops, set the real Keygen Ed25519 public key in the Swift app.",
  );
  deps.stderr(
    "  - Do NOT attach STOWER_V0 manually; Railway attaches it per paid license on purchase.",
  );
}

/**
 * Seeds the account with every Keygen structure the contract requires and returns
 * their ids. Idempotent: existing matches are reused. Attaches `STOWER_TRIAL` to
 * the Trial policy only; `STOWER_V0` is created but never attached here.
 */
export async function bootstrap(deps: BootstrapDeps): Promise<BootstrapOutput> {
  const config = readConfig(deps);
  const client = keygenClient(deps, config);

  const product = await findOrCreateProduct(client);
  const trialPolicy = await findOrCreatePolicy(
    client,
    product.id,
    TRIAL_POLICY_NAME,
    { duration: TRIAL_DURATION_SECONDS },
  );
  const paidPolicy = await findOrCreatePolicy(
    client,
    product.id,
    PAID_POLICY_NAME,
    { transferStrategy: "RESET_EXPIRY" },
  );
  const trialEntitlement = await findOrCreateEntitlement(
    client,
    TRIAL_ENTITLEMENT_CODE,
  );
  const v0Entitlement = await findOrCreateEntitlement(
    client,
    V0_ENTITLEMENT_CODE,
  );
  await assertV0NotPolicyAttached(
    client,
    [trialPolicy.id, paidPolicy.id],
    v0Entitlement.id,
  );
  await ensureTrialAttached(client, trialPolicy.id, trialEntitlement.id);

  const output: BootstrapOutput = {
    baseUrl: config.baseUrl,
    account: config.account,
    productId: product.id,
    trialPolicyId: trialPolicy.id,
    paidPolicyId: paidPolicy.id,
    trialEntitlementId: trialEntitlement.id,
    v0EntitlementId: v0Entitlement.id,
  };
  deps.stdout(JSON.stringify(output, null, 2));
  printSummary(deps, output);
  return output;
}

if (import.meta.main) {
  await bootstrap({
    fetch: globalThis.fetch.bind(globalThis),
    getEnv: (name) => Deno.env.get(name),
    stdout: (line) => console.log(line),
    stderr: (line) => console.error(line),
  });
}
