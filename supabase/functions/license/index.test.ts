// Deno tests for the pure license-function logic (handlers.ts): mint idempotency
// + crash recovery (I3), the LS upgrade webhook (I8 function-side), signature
// rejection (I9), and replay / wrong-variant / transient-failure handling (I15).
// Fully hermetic — fakes only, no network, disk, or env, and inline asserts so
// `deno test` fetches nothing.

import {
  handleWebhook,
  type KeygenAdmin,
  KeygenLicenseNotFoundError,
  type MintDeps,
  mintTrial,
  type PurchaseStore,
  type TrialRow,
  type TrialStore,
  type WebhookDeps,
} from "./handlers.ts";

function assertEquals(
  actual: unknown,
  expected: unknown,
  message?: string,
): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(message ?? `assertEquals failed: ${a} !== ${e}`);
}

const RECLAIM_WINDOW_MS = 60_000;
const T0 = 1_700_000_000_000;
const isoAt = (ms: number) => new Date(ms).toISOString();

class FakeTrials implements TrialStore {
  rows = new Map<string, TrialRow>();
  claimNowMs = T0;

  claim(fingerprint: string): Promise<boolean> {
    if (this.rows.has(fingerprint)) return Promise.resolve(false);
    this.rows.set(fingerprint, {
      status: "pending",
      keygen_license_id: null,
      keygen_license_key: null,
      created_at: isoAt(this.claimNowMs),
    });
    return Promise.resolve(true);
  }
  get(fingerprint: string): Promise<TrialRow | null> {
    return Promise.resolve(this.rows.get(fingerprint) ?? null);
  }
  activate(
    fingerprint: string,
    licenseID: string,
    licenseKey: string,
  ): Promise<void> {
    this.rows.set(fingerprint, {
      status: "active",
      keygen_license_id: licenseID,
      keygen_license_key: licenseKey,
      created_at: isoAt(this.claimNowMs),
    });
    return Promise.resolve();
  }
  releaseClaim(fingerprint: string): Promise<void> {
    const row = this.rows.get(fingerprint);
    if (row && row.status === "pending") this.rows.delete(fingerprint);
    return Promise.resolve();
  }
}

class FakeKeygen implements KeygenAdmin {
  created = 0;
  upgrades: string[] = [];
  nextLicense = { id: "lic-new", key: "key-new" };
  createError: Error | null = null;
  upgradeError: Error | null = null;

  createTrialLicense(): Promise<{ id: string; key: string }> {
    if (this.createError) return Promise.reject(this.createError);
    this.created++;
    return Promise.resolve(this.nextLicense);
  }
  upgradeToPaid(licenseID: string): Promise<void> {
    if (this.upgradeError) return Promise.reject(this.upgradeError);
    this.upgrades.push(licenseID);
    return Promise.resolve();
  }
}

class FakePurchases implements PurchaseStore {
  records: Array<
    { orderID: string; licenseID: string; email: string; variantID: string }
  > = [];
  recordError: Error | null = null;

  exists(orderID: string): Promise<boolean> {
    return Promise.resolve(this.records.some((r) => r.orderID === orderID));
  }
  record(
    purchase: {
      orderID: string;
      licenseID: string;
      email: string;
      variantID: string;
    },
  ): Promise<void> {
    if (this.recordError) return Promise.reject(this.recordError);
    this.records.push(purchase);
    return Promise.resolve();
  }
}

function mintDeps(
  trials: TrialStore,
  keygen: KeygenAdmin,
  nowMs: number,
): MintDeps {
  return {
    trials,
    keygen,
    now: () => nowMs,
    reclaimWindowMs: RECLAIM_WINDOW_MS,
  };
}

function webhookDeps(
  keygen: KeygenAdmin,
  purchases: PurchaseStore,
): WebhookDeps {
  return {
    purchases,
    keygen,
    verifySignature: (_raw, sig) => Promise.resolve(sig === "good"),
    paidVariantID: "paid-variant",
  };
}

function orderBody(overrides: Partial<{
  orderID: string;
  licenseID: string;
  variantID: string;
  email: string;
  event: string;
}> = {}): string {
  const o = {
    orderID: "ord-1",
    licenseID: "lic-1",
    variantID: "paid-variant",
    email: "a@b.com",
    event: "order_created",
    ...overrides,
  };
  return JSON.stringify({
    meta: { event_name: o.event, custom_data: { license_id: o.licenseID } },
    data: {
      id: o.orderID,
      attributes: {
        user_email: o.email,
        first_order_item: { variant_id: o.variantID },
      },
    },
  });
}

// I3(a): a repeat mint returns the existing active license and creates none.
Deno.test("I3a mint is idempotent — second call returns the same license, none created", async () => {
  const trials = new FakeTrials();
  const keygen = new FakeKeygen();
  keygen.nextLicense = { id: "lic-1", key: "key-1" };

  const first = await mintTrial(mintDeps(trials, keygen, T0), "fp");
  assertEquals(first, {
    status: 200,
    body: { key: "key-1", licenseID: "lic-1" },
  });

  const second = await mintTrial(mintDeps(trials, keygen, T0), "fp");
  assertEquals(second, {
    status: 200,
    body: { key: "key-1", licenseID: "lic-1" },
  });
  assertEquals(keygen.created, 1);
});

// I3(b): a winner that died before activate leaves a fresh pending row; a second
// mint inside the reclaim window retries, it does not double-mint.
Deno.test("I3b a fresh pending claim does not double-mint", async () => {
  const trials = new FakeTrials();
  const keygen = new FakeKeygen();
  trials.rows.set("fp", {
    status: "pending",
    keygen_license_id: null,
    keygen_license_key: null,
    created_at: isoAt(T0),
  });

  const result = await mintTrial(mintDeps(trials, keygen, T0 + 30_000), "fp");
  assertEquals(result.status, 503);
  assertEquals(keygen.created, 0);
});

// I3(c): a parallel loser gets a typed retry, never {null, null}.
Deno.test("I3c a parallel loser gets a retryable error, not null ids", async () => {
  const trials = new FakeTrials();
  const keygen = new FakeKeygen();
  trials.rows.set("fp", {
    status: "pending",
    keygen_license_id: null,
    keygen_license_key: null,
    created_at: isoAt(T0),
  });

  const result = await mintTrial(mintDeps(trials, keygen, T0 + 1_000), "fp");
  assertEquals(result, { status: 503, body: { error: "retry" } });
});

// I3(d): a Keygen-create failure deletes the claim (no poisoned pending row).
Deno.test("I3d a Keygen-create failure releases the claim", async () => {
  const trials = new FakeTrials();
  const keygen = new FakeKeygen();
  keygen.createError = new Error("keygen down");

  const result = await mintTrial(mintDeps(trials, keygen, T0), "fp");
  assertEquals(result.status, 503);
  assertEquals(trials.rows.has("fp"), false);
});

// Crash recovery: an abandoned (stale) pending claim is reclaimed and minted.
Deno.test("I3 a stale pending claim is reclaimed and minted", async () => {
  const trials = new FakeTrials();
  const keygen = new FakeKeygen();
  keygen.nextLicense = { id: "lic-2", key: "key-2" };
  trials.rows.set("fp", {
    status: "pending",
    keygen_license_id: null,
    keygen_license_key: null,
    created_at: isoAt(T0),
  });
  trials.claimNowMs = T0 + 120_000;

  const result = await mintTrial(mintDeps(trials, keygen, T0 + 120_000), "fp");
  assertEquals(result, {
    status: 200,
    body: { key: "key-2", licenseID: "lic-2" },
  });
  assertEquals(keygen.created, 1);
});

// I9: a bad LS signature is 401 with no Keygen call and no row write.
Deno.test("I9 a bad signature is 401 with no side effects", async () => {
  const keygen = new FakeKeygen();
  const purchases = new FakePurchases();

  const result = await handleWebhook(
    webhookDeps(keygen, purchases),
    orderBody(),
    "bad",
  );
  assertEquals(result.status, 401);
  assertEquals(keygen.upgrades.length, 0);
  assertEquals(purchases.records.length, 0);
});

// I8 (function side): order_created + valid variant upgrades the right license.
Deno.test("I8 a valid order upgrades the right license and records it", async () => {
  const keygen = new FakeKeygen();
  const purchases = new FakePurchases();

  const result = await handleWebhook(
    webhookDeps(keygen, purchases),
    orderBody(),
    "good",
  );
  assertEquals(result.status, 200);
  assertEquals(keygen.upgrades, ["lic-1"]);
  assertEquals(purchases.records.length, 1);
  assertEquals(purchases.records[0].licenseID, "lic-1");
});

// I15(a): a replayed order is a no-op — one upgrade only.
Deno.test("I15a a replayed order upgrades once", async () => {
  const keygen = new FakeKeygen();
  const purchases = new FakePurchases();
  const deps = webhookDeps(keygen, purchases);

  await handleWebhook(deps, orderBody(), "good");
  const replay = await handleWebhook(deps, orderBody(), "good");
  assertEquals(replay.status, 200);
  assertEquals(keygen.upgrades.length, 1);
  assertEquals(purchases.records.length, 1);
});

// I15(b): a wrong variant never upgrades and never records.
Deno.test("I15b a wrong variant is ignored", async () => {
  const keygen = new FakeKeygen();
  const purchases = new FakePurchases();

  const result = await handleWebhook(
    webhookDeps(keygen, purchases),
    orderBody({ variantID: "some-other-product" }),
    "good",
  );
  assertEquals(result.status, 200);
  assertEquals(keygen.upgrades.length, 0);
  assertEquals(purchases.records.length, 0);
});

// I15(c): a transient Keygen failure is 500 with no row, so LS retries.
Deno.test("I15c a transient Keygen failure stays retryable", async () => {
  const keygen = new FakeKeygen();
  keygen.upgradeError = new Error("keygen 503");
  const purchases = new FakePurchases();

  const result = await handleWebhook(
    webhookDeps(keygen, purchases),
    orderBody(),
    "good",
  );
  assertEquals(result.status, 500);
  assertEquals(purchases.records.length, 0);
});

// A forged/unknown license id is 200 (do not retry-storm), with no row.
Deno.test("a forged license id returns 200 with no row", async () => {
  const keygen = new FakeKeygen();
  keygen.upgradeError = new KeygenLicenseNotFoundError("unknown");
  const purchases = new FakePurchases();

  const result = await handleWebhook(
    webhookDeps(keygen, purchases),
    orderBody(),
    "good",
  );
  assertEquals(result.status, 200);
  assertEquals(purchases.records.length, 0);
});

// An FK violation at record time (a forged id that passed the PUT) returns 200.
Deno.test("an FK violation at record time returns 200 after the upgrade", async () => {
  const keygen = new FakeKeygen();
  const purchases = new FakePurchases();
  purchases.recordError = new Error("23503 foreign_key_violation");

  const result = await handleWebhook(
    webhookDeps(keygen, purchases),
    orderBody(),
    "good",
  );
  assertEquals(result.status, 200);
  assertEquals(keygen.upgrades.length, 1);
});

// A non-order event is ignored with a 200.
Deno.test("a non order_created event is ignored", async () => {
  const keygen = new FakeKeygen();
  const purchases = new FakePurchases();

  const result = await handleWebhook(
    webhookDeps(keygen, purchases),
    orderBody({ event: "subscription_created" }),
    "good",
  );
  assertEquals(result.status, 200);
  assertEquals(keygen.upgrades.length, 0);
});
