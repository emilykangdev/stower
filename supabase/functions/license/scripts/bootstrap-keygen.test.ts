// Deno tests for bootstrap-keygen.ts. Fully hermetic — a fake in-memory Keygen
// account stands in for the network, env is a plain map, and stdout/stderr are
// captured into arrays. No network, disk, or real env, so `deno test` fetches
// nothing.

import { bootstrap, type BootstrapDeps } from "./bootstrap-keygen.ts";

const JSON_API_CONTENT_TYPE = "application/vnd.api+json";
const TOKEN = "super-secret-keygen-token";
const ENV: Record<string, string> = {
  KEYGEN_ACCOUNT: "acct-1",
  KEYGEN_TOKEN: TOKEN,
};

function assertEquals(actual: unknown, expected: unknown, message?: string): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(message ?? `assertEquals failed: ${a} !== ${e}`);
}

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

interface Stored {
  id: string;
  type: string;
  attributes: Record<string, unknown>;
}

interface RecordedRequest {
  method: string;
  collection: string; // path after /v1/accounts/{account}/
  body: { data?: unknown } | undefined;
}

/** A minimal in-memory Keygen account: create/list/attach over the four routes
 * the bootstrap script touches. Records every request for assertions. */
class FakeKeygen {
  products: Stored[] = [];
  policies: Stored[] = [];
  entitlements: Stored[] = [];
  policyEntitlements = new Map<string, string[]>();
  requests: RecordedRequest[] = [];
  private idCounter = 0;

  fetch = (
    input: string | URL | Request,
    init?: RequestInit,
  ): Promise<Response> => {
    const url = typeof input === "string" ? input : input.toString();
    const method = init?.method ?? "GET";
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    const collection = new URL(url).pathname.replace(
      /^\/v1\/accounts\/[^/]+\//,
      "",
    );
    this.requests.push({ method, collection, body });
    return Promise.resolve(this.route(method, collection, body));
  };

  private json(status: number, payload: unknown): Response {
    return new Response(JSON.stringify(payload), {
      status,
      headers: { "Content-Type": JSON_API_CONTENT_TYPE },
    });
  }

  private route(
    method: string,
    collection: string,
    body: { data?: unknown } | undefined,
  ): Response {
    const attach = collection.match(/^policies\/([^/]+)\/entitlements$/);
    if (attach) return this.routePolicyEntitlements(method, attach[1], body);

    const collections: Record<string, Stored[]> = {
      products: this.products,
      policies: this.policies,
      entitlements: this.entitlements,
    };
    const store = collections[collection];
    if (!store) return this.json(404, { errors: [{ detail: "not found" }] });

    if (method === "GET") return this.json(200, { data: store, links: { next: null } });
    if (method === "POST") {
      const data = (body?.data ?? {}) as {
        type: string;
        attributes?: Record<string, unknown>;
      };
      const created: Stored = {
        id: `${collection}-${++this.idCounter}`,
        type: data.type,
        attributes: data.attributes ?? {},
      };
      store.push(created);
      return this.json(201, { data: created });
    }
    return this.json(405, { errors: [{ detail: "method not allowed" }] });
  }

  private routePolicyEntitlements(
    method: string,
    policyID: string,
    body: { data?: unknown } | undefined,
  ): Response {
    const ids = this.policyEntitlements.get(policyID) ?? [];
    if (method === "GET") {
      const data = ids
        .map((id) => this.entitlements.find((e) => e.id === id))
        .filter((e): e is Stored => e !== undefined);
      return this.json(200, { data, links: { next: null } });
    }
    if (method === "POST") {
      const items = Array.isArray(body?.data) ? body!.data : [body?.data];
      for (const item of items as Array<{ id: string }>) ids.push(item.id);
      this.policyEntitlements.set(policyID, ids);
      return this.json(201, { data: items });
    }
    return this.json(405, { errors: [{ detail: "method not allowed" }] });
  }

  // Convenience accessors for assertions.
  createPostsTo(collection: string): RecordedRequest[] {
    return this.requests.filter((r) =>
      r.method === "POST" && r.collection === collection
    );
  }

  attachPosts(): RecordedRequest[] {
    return this.requests.filter((r) =>
      r.method === "POST" && /^policies\/[^/]+\/entitlements$/.test(r.collection)
    );
  }
}

interface Captured {
  out: string[];
  err: string[];
}

function makeDeps(
  server: FakeKeygen,
  captured: Captured,
  env: Record<string, string> = ENV,
): BootstrapDeps {
  return {
    fetch: server.fetch,
    getEnv: (name) => env[name],
    stdout: (line) => captured.out.push(line),
    stderr: (line) => captured.err.push(line),
  };
}

function seedAll(server: FakeKeygen): void {
  server.products.push({
    id: "prod-existing",
    type: "products",
    attributes: { name: "Stower", code: "stower" },
  });
  server.policies.push({
    id: "trial-existing",
    type: "policies",
    attributes: { name: "STOWER_TRIAL_POLICY" },
  });
  server.policies.push({
    id: "paid-existing",
    type: "policies",
    attributes: { name: "STOWER_PAID_POLICY" },
  });
  server.entitlements.push({
    id: "trial-ent-existing",
    type: "entitlements",
    attributes: { name: "STOWER_TRIAL", code: "STOWER_TRIAL" },
  });
  server.entitlements.push({
    id: "v0-ent-existing",
    type: "entitlements",
    attributes: { name: "STOWER_V0", code: "STOWER_V0" },
  });
}

// Missing KEYGEN_ACCOUNT fails loudly (not a silent skip).
Deno.test("missing KEYGEN_ACCOUNT throws", async () => {
  const server = new FakeKeygen();
  const captured: Captured = { out: [], err: [] };
  let threw = false;
  try {
    await bootstrap(makeDeps(server, captured, { KEYGEN_TOKEN: TOKEN }));
  } catch (error) {
    threw = true;
    assert(
      (error as Error).message.includes("KEYGEN_ACCOUNT"),
      "error should name KEYGEN_ACCOUNT",
    );
  }
  assert(threw, "bootstrap must throw when KEYGEN_ACCOUNT is missing");
  assertEquals(server.requests.length, 0);
});

// Missing KEYGEN_TOKEN fails loudly.
Deno.test("missing KEYGEN_TOKEN throws", async () => {
  const server = new FakeKeygen();
  const captured: Captured = { out: [], err: [] };
  let threw = false;
  try {
    await bootstrap(makeDeps(server, captured, { KEYGEN_ACCOUNT: "acct-1" }));
  } catch (error) {
    threw = true;
    assert(
      (error as Error).message.includes("KEYGEN_TOKEN"),
      "error should name KEYGEN_TOKEN",
    );
  }
  assert(threw, "bootstrap must throw when KEYGEN_TOKEN is missing");
  assertEquals(server.requests.length, 0);
});

// On a fresh account every structure is created with the exact attributes the
// contract requires, and the output carries the created ids.
Deno.test("missing objects are created with exact attributes", async () => {
  const server = new FakeKeygen();
  const captured: Captured = { out: [], err: [] };
  const output = await bootstrap(makeDeps(server, captured));

  // One create each — no duplicates.
  assertEquals(server.createPostsTo("products").length, 1);
  assertEquals(server.createPostsTo("policies").length, 2);
  assertEquals(server.createPostsTo("entitlements").length, 2);

  const productBody = server.createPostsTo("products")[0].body as {
    data: { attributes: Record<string, unknown> };
  };
  assertEquals(productBody.data.attributes.name, "Stower");
  assertEquals(productBody.data.attributes.code, "stower");

  // Output ids point at the freshly created resources.
  assertEquals(output.productId, "products-1");
  assert(output.trialPolicyId.startsWith("policies-"), "trial policy id created");
  assert(output.paidPolicyId.startsWith("policies-"), "paid policy id created");
  assert(
    output.trialEntitlementId.startsWith("entitlements-"),
    "trial entitlement id created",
  );
  assert(
    output.v0EntitlementId.startsWith("entitlements-"),
    "v0 entitlement id created",
  );
});

function policyBodyByName(server: FakeKeygen, name: string): {
  attributes: Record<string, unknown>;
  relationships?: { product?: { data?: { id?: string } } };
} {
  const post = server.createPostsTo("policies").find((r) => {
    const data = (r.body as { data: { attributes: Record<string, unknown> } })
      .data;
    return data.attributes.name === name;
  });
  assert(post !== undefined, `expected a create POST for policy ${name}`);
  return (post!.body as {
    data: {
      attributes: Record<string, unknown>;
      relationships?: { product?: { data?: { id?: string } } };
    };
  }).data;
}

// Both policies use the shared signing/auth/machine rules.
Deno.test("both policies use ED25519_SIGN, LICENSE, maxMachines 1, UNIQUE_PER_PRODUCT", async () => {
  const server = new FakeKeygen();
  const captured: Captured = { out: [], err: [] };
  const output = await bootstrap(makeDeps(server, captured));

  for (const name of ["STOWER_TRIAL_POLICY", "STOWER_PAID_POLICY"]) {
    const attrs = policyBodyByName(server, name).attributes;
    assertEquals(attrs.scheme, "ED25519_SIGN", `${name} scheme`);
    assertEquals(attrs.authenticationStrategy, "LICENSE", `${name} auth`);
    assertEquals(attrs.maxMachines, 1, `${name} maxMachines`);
    assertEquals(
      attrs.machineUniquenessStrategy,
      "UNIQUE_PER_PRODUCT",
      `${name} uniqueness`,
    );
  }

  // Policies are created under the product.
  assertEquals(
    policyBodyByName(server, "STOWER_TRIAL_POLICY").relationships?.product?.data
      ?.id,
    output.productId,
  );
});

// Trial policy carries the 30-day duration; Paid policy omits duration and
// carries RESET_EXPIRY (a one-time purchase is perpetual).
Deno.test("trial has duration; paid omits duration and resets expiry on transfer", async () => {
  const server = new FakeKeygen();
  const captured: Captured = { out: [], err: [] };
  await bootstrap(makeDeps(server, captured));

  const trial = policyBodyByName(server, "STOWER_TRIAL_POLICY").attributes;
  assertEquals(trial.duration, 2_592_000);
  assert(!("transferStrategy" in trial), "trial policy must not set transferStrategy");

  const paid = policyBodyByName(server, "STOWER_PAID_POLICY").attributes;
  assert(!("duration" in paid), "paid policy must omit duration (perpetual)");
  assertEquals(paid.transferStrategy, "RESET_EXPIRY");
});

// STOWER_TRIAL is attached to the Trial policy; STOWER_V0 is attached nowhere.
Deno.test("STOWER_TRIAL attaches to the trial policy and STOWER_V0 attaches nowhere", async () => {
  const server = new FakeKeygen();
  const captured: Captured = { out: [], err: [] };
  const output = await bootstrap(makeDeps(server, captured));

  const attachedToTrial = server.policyEntitlements.get(output.trialPolicyId) ??
    [];
  assertEquals(attachedToTrial, [output.trialEntitlementId]);

  // The v0 entitlement id must appear in NO policy's attachment list.
  for (const ids of server.policyEntitlements.values()) {
    assert(
      !ids.includes(output.v0EntitlementId),
      "STOWER_V0 must never be attached to a policy",
    );
  }
  // And no attach POST referenced the v0 entitlement.
  for (const post of server.attachPosts()) {
    const items = (post.body as { data: Array<{ id: string }> }).data;
    assert(
      !items.some((i) => i.id === output.v0EntitlementId),
      "no attach POST may reference STOWER_V0",
    );
  }
});

// A rerun against a fully-seeded account reuses every existing resource and
// creates nothing — full idempotency.
Deno.test("existing product/policies/entitlements are reused, none created", async () => {
  const server = new FakeKeygen();
  seedAll(server);
  const captured: Captured = { out: [], err: [] };
  const output = await bootstrap(makeDeps(server, captured));

  assertEquals(server.createPostsTo("products").length, 0);
  assertEquals(server.createPostsTo("policies").length, 0);
  assertEquals(server.createPostsTo("entitlements").length, 0);

  assertEquals(output, {
    baseUrl: "https://api.keygen.sh",
    account: "acct-1",
    productId: "prod-existing",
    trialPolicyId: "trial-existing",
    paidPolicyId: "paid-existing",
    trialEntitlementId: "trial-ent-existing",
    v0EntitlementId: "v0-ent-existing",
  });
});

// An already-attached Trial entitlement is treated as success: no second attach
// POST is sent (Keygen rejects duplicate attaches).
Deno.test("an already-attached trial entitlement is a no-op", async () => {
  const server = new FakeKeygen();
  seedAll(server);
  server.policyEntitlements.set("trial-existing", ["trial-ent-existing"]);
  const captured: Captured = { out: [], err: [] };
  const output = await bootstrap(makeDeps(server, captured));

  assertEquals(output.trialPolicyId, "trial-existing");
  assertEquals(server.attachPosts().length, 0);
});

// stdout is exactly the output JSON and never leaks the token.
Deno.test("stdout is valid JSON matching the output and excludes the token", async () => {
  const server = new FakeKeygen();
  const captured: Captured = { out: [], err: [] };
  const output = await bootstrap(makeDeps(server, captured));

  assertEquals(captured.out.length, 1);
  assertEquals(JSON.parse(captured.out[0]), output);
  for (const line of captured.out) {
    assert(!line.includes(TOKEN), "stdout must not contain the token");
  }
});

// stderr carries the summary/reminders and never leaks the token.
Deno.test("stderr summary excludes the token", async () => {
  const server = new FakeKeygen();
  const captured: Captured = { out: [], err: [] };
  await bootstrap(makeDeps(server, captured));

  assert(captured.err.length > 0, "stderr should carry a human summary");
  for (const line of captured.err) {
    assert(!line.includes(TOKEN), "stderr must not contain the token");
  }
  // The summary reminds the operator not to attach STOWER_V0 manually.
  assert(
    captured.err.some((l) => l.includes("STOWER_V0")),
    "stderr should remind about STOWER_V0",
  );
});
