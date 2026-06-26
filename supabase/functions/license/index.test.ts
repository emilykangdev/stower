// Deno tests for the pure license-function logic (handlers.ts): mint idempotency
// + crash recovery + server-side machine activation/checkout (I3, I9), the LS
// upgrade webhook incl. STOWER_V0 attach (I8/I10), and the reachable-launch
// check-in — signature gate, once-per-major +7d (I11/I12), validate + machine
// repair, entitlement OR (I4), checkout (I13), and "never returns the key".
// Fully hermetic — fakes only, no network, disk, or env.

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
  STOWER_TRIAL_ENTITLEMENT_CODE,
  STOWER_V0_ENTITLEMENT_CODE,
  type TrialRow,
  type TrialStore,
  type WebhookDeps,
} from "./handlers.ts";
import type { StableRelease } from "./github.ts";

function assertEquals(
  actual: unknown,
  expected: unknown,
  message?: string,
): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(message ?? `assertEquals failed: ${a} !== ${e}`);
}
function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

const RECLAIM_WINDOW_MS = 60_000;
const T0 = 1_700_000_000_000;
const isoAt = (ms: number) => new Date(ms).toISOString();

type StoredRow = TrialRow & { claim_id?: string };

function pendingRow(
  fingerprint: string,
  createdMs: number,
  claimId?: string,
): StoredRow {
  return {
    status: "pending",
    fingerprint,
    keygen_license_id: null,
    keygen_license_key: null,
    keygen_machine_id: null,
    started_major: "v0",
    created_at: isoAt(createdMs),
    claim_id: claimId,
  };
}

class FakeTrials implements TrialStore {
  rows = new Map<string, StoredRow>(); // by fingerprint
  grants = new Map<string, ExtensionGrant>(); // `${licenseID}:${major}`
  claimNowMs = T0;
  activateError: Error | null = null;
  observed: Array<{ licenseID: string; appMajor: string; appBuild: string }> =
    [];
  machineSets: Array<{ licenseID: string; machineID: string }> = [];
  checkIns: string[] = [];
  private claimCounter = 0;

  claim(fingerprint: string): Promise<string | null> {
    if (this.rows.has(fingerprint)) return Promise.resolve(null);
    const claimId = `claim-${++this.claimCounter}`;
    this.rows.set(
      fingerprint,
      pendingRow(fingerprint, this.claimNowMs, claimId),
    );
    return Promise.resolve(claimId);
  }
  get(fingerprint: string): Promise<TrialRow | null> {
    return Promise.resolve(this.rows.get(fingerprint) ?? null);
  }
  getByLicense(licenseID: string): Promise<TrialRow | null> {
    for (const row of this.rows.values()) {
      if (row.keygen_license_id === licenseID) return Promise.resolve(row);
    }
    return Promise.resolve(null);
  }
  activate(
    fingerprint: string,
    claimToken: string,
    licenseID: string,
    licenseKey: string,
  ): Promise<boolean> {
    if (this.activateError) return Promise.reject(this.activateError);
    const row = this.rows.get(fingerprint);
    if (!row || row.status !== "pending" || row.claim_id !== claimToken) {
      return Promise.resolve(false);
    }
    this.rows.set(fingerprint, {
      ...row,
      status: "active",
      keygen_license_id: licenseID,
      keygen_license_key: licenseKey,
    });
    return Promise.resolve(true);
  }
  releaseClaim(fingerprint: string, claimToken: string): Promise<void> {
    const row = this.rows.get(fingerprint);
    if (row && row.status === "pending" && row.claim_id === claimToken) {
      this.rows.delete(fingerprint);
    }
    return Promise.resolve();
  }
  reclaimStale(fingerprint: string, olderThanMs: number): Promise<void> {
    const row = this.rows.get(fingerprint);
    if (
      row && row.status === "pending" &&
      Date.parse(row.created_at) < olderThanMs
    ) {
      this.rows.delete(fingerprint);
    }
    return Promise.resolve();
  }
  setMachine(licenseID: string, machineID: string): Promise<void> {
    this.machineSets.push({ licenseID, machineID });
    for (const [fp, row] of this.rows) {
      if (row.keygen_license_id === licenseID) {
        this.rows.set(fp, { ...row, keygen_machine_id: machineID });
      }
    }
    return Promise.resolve();
  }
  recordObservedVersion(
    licenseID: string,
    appMajor: string,
    appBuild: string,
  ): Promise<void> {
    this.observed.push({ licenseID, appMajor, appBuild });
    return Promise.resolve();
  }
  extendedMajors(licenseID: string): Promise<string[]> {
    const majors = [...this.grants.entries()]
      .filter(([k, g]) => k.startsWith(`${licenseID}:`) && g.patchedAt !== null)
      .map(([k]) => k.slice(licenseID.length + 1));
    return Promise.resolve(majors);
  }
  claimExtensionGrant(
    licenseID: string,
    major: string,
    _previousExpiresAt: string,
    targetExpiresAt: string,
  ): Promise<ExtensionGrant> {
    const key = `${licenseID}:${major}`;
    const existing = this.grants.get(key);
    if (existing) return Promise.resolve({ ...existing });
    const grant: ExtensionGrant = { targetExpiresAt, patchedAt: null };
    this.grants.set(key, grant);
    return Promise.resolve({ ...grant });
  }
  markExtensionPatched(licenseID: string, major: string): Promise<void> {
    const grant = this.grants.get(`${licenseID}:${major}`);
    if (grant && grant.patchedAt === null) grant.patchedAt = isoAt(T0);
    return Promise.resolve();
  }
  touchCheckIn(licenseID: string): Promise<void> {
    this.checkIns.push(licenseID);
    return Promise.resolve();
  }
}

class FakeKeygen implements KeygenAdmin {
  created = 0;
  upgrades: string[] = [];
  attaches: string[] = [];
  activateCalls: Array<{ licenseID: string; fingerprint: string }> = [];
  checkouts: string[] = [];
  patchedExpiries: Array<{ licenseID: string; iso: string }> = [];
  nextLicense = { id: "lic-new", key: "key-new" };
  createError: Error | null = null;
  upgradeError: Error | null = null;
  attachError: Error | null = null;
  activateError: Error | null = null;
  validations: KeygenValidation[] = [{ valid: true, code: null }]; // consumed FIFO; last repeats
  entitlements: string[] = [STOWER_TRIAL_ENTITLEMENT_CODE];
  expiry: string | null = isoAt(T0 + 30 * 24 * 60 * 60 * 1000);
  expiryQueue: (string | null)[] | null = null; // when set, currentExpiry consumes FIFO (last repeats)

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
  attachV0(licenseID: string): Promise<void> {
    if (this.attachError) return Promise.reject(this.attachError);
    this.attaches.push(licenseID);
    return Promise.resolve();
  }
  activateMachine(
    licenseID: string,
    _key: string,
    fingerprint: string,
  ): Promise<string> {
    if (this.activateError) return Promise.reject(this.activateError);
    this.activateCalls.push({ licenseID, fingerprint });
    return Promise.resolve(`mach-${licenseID}`);
  }
  checkoutMachineFile(machineID: string): Promise<string> {
    this.checkouts.push(machineID);
    return Promise.resolve(`file-${machineID}`);
  }
  validate(_key: string, _fingerprint: string): Promise<KeygenValidation> {
    const next = this.validations.length > 1
      ? this.validations.shift()!
      : this.validations[0];
    return Promise.resolve(next);
  }
  effectiveEntitlements(_licenseID: string): Promise<string[]> {
    return Promise.resolve(this.entitlements);
  }
  currentExpiry(_licenseID: string): Promise<string | null> {
    if (this.expiryQueue && this.expiryQueue.length > 0) {
      const next = this.expiryQueue.length > 1
        ? this.expiryQueue.shift()!
        : this.expiryQueue[0];
      return Promise.resolve(next);
    }
    return Promise.resolve(this.expiry);
  }
  patchExpiry(licenseID: string, iso: string): Promise<void> {
    this.patchedExpiries.push({ licenseID, iso });
    return Promise.resolve();
  }
}

class FakePurchases implements PurchaseStore {
  records: Array<
    {
      orderID: string;
      licenseID: string;
      purchasedMajor: string;
      entitlementCode: string;
    }
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
      purchasedMajor: string;
      entitlementCode: string;
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
function mintReq(fingerprint: string): MintRequest {
  return { fingerprint, appMajor: "v0", appBuild: "1" };
}

function webhookDeps(
  keygen: KeygenAdmin,
  purchases: PurchaseStore,
  licenseIsMinted: (id: string) => Promise<boolean> = () =>
    Promise.resolve(true),
): WebhookDeps {
  return {
    purchases,
    keygen,
    verifySignature: (_raw, sig) => Promise.resolve(sig === "good"),
    paidVariantID: "paid-variant",
    licenseIsMinted,
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

// ---------------------------------------------------------------------------
// Mint (I3 / I9) — now also activates a machine + checks out a signed file.
// ---------------------------------------------------------------------------

Deno.test("I3a mint is idempotent — second call returns the same license + file, none created", async () => {
  const trials = new FakeTrials();
  const keygen = new FakeKeygen();
  keygen.nextLicense = { id: "lic-1", key: "key-1" };

  const first = await mintTrial(mintDeps(trials, keygen, T0), mintReq("fp"));
  assertEquals(first, {
    status: 200,
    body: {
      minted: true,
      licenseKey: "key-1",
      licenseID: "lic-1",
      machineID: "mach-lic-1",
      machineFile: "file-mach-lic-1",
    },
  });

  const second = await mintTrial(mintDeps(trials, keygen, T0), mintReq("fp"));
  assertEquals(second, {
    status: 200,
    body: {
      minted: true,
      licenseKey: "key-1",
      licenseID: "lic-1",
      machineID: "mach-lic-1",
      machineFile: "file-mach-lic-1",
    },
  });
  assertEquals(keygen.created, 1);
  assertEquals(
    keygen.activateCalls.length,
    1,
    "machine activated once, reused on the second mint",
  );
});

Deno.test("I3b a fresh pending claim does not double-mint", async () => {
  const trials = new FakeTrials();
  const keygen = new FakeKeygen();
  trials.rows.set("fp", pendingRow("fp", T0));

  const result = await mintTrial(
    mintDeps(trials, keygen, T0 + 30_000),
    mintReq("fp"),
  );
  assertEquals(result.status, 503);
  assertEquals(keygen.created, 0);
});

Deno.test("I3c a parallel loser gets a retryable error, not null ids", async () => {
  const trials = new FakeTrials();
  const keygen = new FakeKeygen();
  trials.rows.set("fp", pendingRow("fp", T0));

  const result = await mintTrial(
    mintDeps(trials, keygen, T0 + 1_000),
    mintReq("fp"),
  );
  assertEquals(result, { status: 503, body: { error: "retry" } });
});

Deno.test("I3d a Keygen-create failure releases the claim", async () => {
  const trials = new FakeTrials();
  const keygen = new FakeKeygen();
  keygen.createError = new Error("keygen down");

  const result = await mintTrial(mintDeps(trials, keygen, T0), mintReq("fp"));
  assertEquals(result.status, 503);
  assertEquals(trials.rows.has("fp"), false);
});

Deno.test("I3 a stale pending claim is reclaimed and minted", async () => {
  const trials = new FakeTrials();
  const keygen = new FakeKeygen();
  keygen.nextLicense = { id: "lic-2", key: "key-2" };
  trials.rows.set("fp", pendingRow("fp", T0));
  trials.claimNowMs = T0 + 120_000;

  const result = await mintTrial(
    mintDeps(trials, keygen, T0 + 120_000),
    mintReq("fp"),
  );
  assertEquals(result, {
    status: 200,
    body: {
      minted: true,
      licenseKey: "key-2",
      licenseID: "lic-2",
      machineID: "mach-lic-2",
      machineFile: "file-mach-lic-2",
    },
  });
  assertEquals(keygen.created, 1);
});

Deno.test("I3 a post-create DB failure does not release the claim", async () => {
  const trials = new FakeTrials();
  trials.activateError = new Error("db write failed");
  const keygen = new FakeKeygen();

  const result = await mintTrial(mintDeps(trials, keygen, T0), mintReq("fp"));
  assertEquals(result.status, 503);
  assertEquals(keygen.created, 1);
  assertEquals(trials.rows.get("fp")?.status, "pending");
});

Deno.test("I9 a machine/checkout failure after the row is active keeps it and retries", async () => {
  const trials = new FakeTrials();
  const keygen = new FakeKeygen();
  keygen.nextLicense = { id: "lic-9", key: "key-9" };
  keygen.activateError = new Error("keygen machines 503");

  const result = await mintTrial(mintDeps(trials, keygen, T0), mintReq("fp"));
  assertEquals(result.status, 503);
  assertEquals(keygen.created, 1, "license created exactly once");
  assertEquals(
    trials.rows.get("fp")?.status,
    "active",
    "row stays active so the next mint reuses it",
  );

  // Next mint: reuse path, machine now activates, returns the file. Still one create.
  keygen.activateError = null;
  const retry = await mintTrial(mintDeps(trials, keygen, T0), mintReq("fp"));
  assertEquals(retry.status, 200);
  assertEquals(
    keygen.created,
    1,
    "the retry never mints a second license (orphan-storm guard)",
  );
});

Deno.test("I3 reclaim only deletes a row older than the cutoff", async () => {
  const trials = new FakeTrials();
  trials.rows.set("fp", pendingRow("fp", T0));
  await trials.reclaimStale("fp", T0 - RECLAIM_WINDOW_MS);
  assertEquals(trials.rows.has("fp"), true);
});

Deno.test("I3 activate only succeeds for the owning claim token", async () => {
  const trials = new FakeTrials();
  const tokenA = await trials.claim("fp");
  trials.rows.set("fp", {
    ...pendingRow("fp", T0, "token-B"),
    status: "active",
    keygen_license_id: "lic-B",
    keygen_license_key: "key-B",
  });

  const wonA = await trials.activate("fp", tokenA ?? "", "lic-A", "key-A");
  assertEquals(wonA, false);
  assertEquals(trials.rows.get("fp")?.keygen_license_id, "lic-B");
});

Deno.test("mint requires a fingerprint", async () => {
  const result = await mintTrial(
    mintDeps(new FakeTrials(), new FakeKeygen(), T0),
    mintReq(""),
  );
  assertEquals(result.status, 400);
});

// ---------------------------------------------------------------------------
// Webhook (I8 / I10 / I15) — now also attaches STOWER_V0.
// ---------------------------------------------------------------------------

Deno.test("I9w a bad signature is 401 with no side effects", async () => {
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

Deno.test("I8 a valid order upgrades + attaches STOWER_V0 + records the major", async () => {
  const keygen = new FakeKeygen();
  const purchases = new FakePurchases();
  const result = await handleWebhook(
    webhookDeps(keygen, purchases),
    orderBody(),
    "good",
  );
  assertEquals(result.status, 200);
  assertEquals(keygen.upgrades, ["lic-1"]);
  assertEquals(keygen.attaches, ["lic-1"]);
  assertEquals(
    purchases.records[0].entitlementCode,
    STOWER_V0_ENTITLEMENT_CODE,
  );
  assertEquals(purchases.records[0].purchasedMajor, "v0");
});

Deno.test("a transient attachV0 failure returns 500 so LS retries", async () => {
  const keygen = new FakeKeygen();
  keygen.attachError = new Error("keygen attach 503");
  const purchases = new FakePurchases();
  const result = await handleWebhook(
    webhookDeps(keygen, purchases),
    orderBody(),
    "good",
  );
  assertEquals(result.status, 500);
  assertEquals(keygen.upgrades.length, 1); // upgrade ran; attach is idempotent on retry
  assertEquals(purchases.records.length, 0); // not recorded until attach succeeds
});

Deno.test("I15a a replayed order upgrades once", async () => {
  const keygen = new FakeKeygen();
  const purchases = new FakePurchases();
  const deps = webhookDeps(keygen, purchases);
  await handleWebhook(deps, orderBody(), "good");
  const replay = await handleWebhook(deps, orderBody(), "good");
  assertEquals(replay.status, 200);
  assertEquals(keygen.upgrades.length, 1);
  assertEquals(keygen.attaches.length, 1);
});

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
});

Deno.test("I15c a transient Keygen upgrade failure stays retryable", async () => {
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

Deno.test("an FK violation at record time returns 200 after the upgrade", async () => {
  const keygen = new FakeKeygen();
  const purchases = new FakePurchases();
  purchases.recordError = new PurchaseForgedLicenseError("forged id");
  const result = await handleWebhook(
    webhookDeps(keygen, purchases),
    orderBody(),
    "good",
  );
  assertEquals(result.status, 200);
  assertEquals(keygen.upgrades.length, 1);
});

Deno.test("a transient record failure returns 500 so LS retries", async () => {
  const keygen = new FakeKeygen();
  const purchases = new FakePurchases();
  purchases.recordError = new Error("40001 serialization_failure");
  const result = await handleWebhook(
    webhookDeps(keygen, purchases),
    orderBody(),
    "good",
  );
  assertEquals(result.status, 500);
  assertEquals(keygen.upgrades.length, 1);
});

Deno.test("a paid order missing license_id is acked without upgrading", async () => {
  const keygen = new FakeKeygen();
  const purchases = new FakePurchases();
  const result = await handleWebhook(
    webhookDeps(keygen, purchases),
    orderBody({ licenseID: "" }),
    "good",
  );
  assertEquals(result.status, 200);
  assertEquals(keygen.upgrades.length, 0);
});

Deno.test("a paid order for an unminted license never calls Keygen", async () => {
  const keygen = new FakeKeygen();
  const purchases = new FakePurchases();
  const result = await handleWebhook(
    webhookDeps(keygen, purchases, () => Promise.resolve(false)),
    orderBody(),
    "good",
  );
  assertEquals(result.status, 200);
  assertEquals(keygen.upgrades.length, 0);
});

Deno.test("a transient ownership-lookup failure returns 500", async () => {
  const keygen = new FakeKeygen();
  const purchases = new FakePurchases();
  const result = await handleWebhook(
    webhookDeps(keygen, purchases, () => Promise.reject(new Error("db down"))),
    orderBody(),
    "good",
  );
  assertEquals(result.status, 500);
});

Deno.test("a non order_created event is ignored", async () => {
  const keygen = new FakeKeygen();
  const purchases = new FakePurchases();
  const result = await handleWebhook(
    webhookDeps(keygen, purchases),
    orderBody({ event: "subscription_created" }),
    "good",
  );
  assertEquals(result.status, 200);
});

// ---------------------------------------------------------------------------
// Check-in.
// ---------------------------------------------------------------------------

const GOOD_KEY = "key-ci";
const LICENSE_ID = "lic-ci";

function activeRow(overrides: Partial<TrialRow> = {}): StoredRow {
  return {
    status: "active",
    fingerprint: "fp-ci",
    keygen_license_id: LICENSE_ID,
    keygen_license_key: GOOD_KEY,
    keygen_machine_id: "mach-ci",
    started_major: "v0",
    created_at: isoAt(T0),
    ...overrides,
  };
}

function checkInDeps(
  trials: FakeTrials,
  keygen: FakeKeygen,
  opts: {
    latest?: string | null;
    releases?: StableRelease[];
    goodKey?: string;
  } = {},
): CheckInDeps {
  return {
    trials,
    keygen,
    github: {
      currentLatestMajor: () => Promise.resolve(opts.latest ?? null),
      stableReleases: () => Promise.resolve(opts.releases ?? []),
    },
    verifySignature: (key: string) =>
      Promise.resolve({ ok: key === (opts.goodKey ?? GOOD_KEY) }),
  };
}

function checkInReq(overrides: Partial<CheckInRequest> = {}): CheckInRequest {
  return {
    licenseID: LICENSE_ID,
    fingerprint: "fp-ci",
    appMajor: "v0",
    appBuild: "1",
    ...overrides,
  };
}

function trialsWith(row: StoredRow): FakeTrials {
  const trials = new FakeTrials();
  trials.rows.set(row.fingerprint, row);
  return trials;
}

Deno.test("check-in happy path returns ok + a fresh file, never the key", async () => {
  const trials = trialsWith(activeRow());
  const keygen = new FakeKeygen();
  const result = await checkIn(
    checkInDeps(trials, keygen, { latest: "v0" }),
    checkInReq(),
  );
  assertEquals(result.status, 200);
  const body = result.body as Record<string, unknown>;
  assertEquals(body.status, "ok");
  assertEquals(body.machineFile, "file-mach-ci");
  assert(!("keygen_license_key" in body), "must not return the key field");
  assert(
    !Object.values(body).includes(GOOD_KEY),
    "must not leak the key value",
  );
  assertEquals(trials.checkIns, [LICENSE_ID]);
});

Deno.test("check-in on an unknown license is 404", async () => {
  const trials = new FakeTrials();
  const result = await checkIn(
    checkInDeps(trials, new FakeKeygen()),
    checkInReq(),
  );
  assertEquals(result.status, 404);
});

Deno.test("check-in with a mismatched fingerprint is 409", async () => {
  const trials = trialsWith(activeRow());
  const result = await checkIn(
    checkInDeps(trials, new FakeKeygen()),
    checkInReq({ fingerprint: "other-fp" }),
  );
  assertEquals(result.status, 409);
});

Deno.test("check-in with a bad signature is 401 and does no Keygen work", async () => {
  const trials = trialsWith(activeRow());
  const keygen = new FakeKeygen();
  const result = await checkIn(
    checkInDeps(trials, keygen, { goodKey: "other" }),
    checkInReq(),
  );
  assertEquals(result.status, 401);
  assertEquals(keygen.checkouts.length, 0);
  assertEquals(trials.checkIns.length, 0);
});

Deno.test("check-in maps an EXPIRED license to 200 expired", async () => {
  const trials = trialsWith(activeRow());
  const keygen = new FakeKeygen();
  keygen.validations = [{ valid: false, code: "EXPIRED" }];
  const result = await checkIn(
    checkInDeps(trials, keygen, { latest: "v0" }),
    checkInReq(),
  );
  assertEquals(result.status, 200);
  assertEquals((result.body as Record<string, unknown>).status, "expired");
});

Deno.test("check-in without the required entitlement is 200 wrong_version (I4)", async () => {
  const trials = trialsWith(activeRow());
  const keygen = new FakeKeygen();
  keygen.entitlements = ["STOWER_LEGACY"]; // neither STOWER_TRIAL nor STOWER_V0
  const result = await checkIn(
    checkInDeps(trials, keygen, { latest: "v0" }),
    checkInReq(),
  );
  assertEquals(result.status, 200);
  const body = result.body as Record<string, unknown>;
  assertEquals(body.status, "wrong_version");
  assertEquals(body.currentLatestMajor, "v0");
});

Deno.test("check-in OR accepts STOWER_V0 alone (no trial)", async () => {
  const trials = trialsWith(
    activeRow({ status: "paid", keygen_machine_id: "mach-ci" }),
  );
  const keygen = new FakeKeygen();
  keygen.entitlements = [STOWER_V0_ENTITLEMENT_CODE];
  const result = await checkIn(
    checkInDeps(trials, keygen, { latest: "v0" }),
    checkInReq(),
  );
  assertEquals((result.body as Record<string, unknown>).status, "ok");
});

Deno.test("I11 +7d applies once per major and is idempotent under retry", async () => {
  const releases: StableRelease[] = [
    { major: 0, tag: "v0.9.0", publishedAt: isoAt(T0 - 1000) },
    { major: 1, tag: "v1.0.0", publishedAt: isoAt(T0 + 1000) }, // published AFTER the trial began
  ];
  const trials = trialsWith(activeRow());
  const keygen = new FakeKeygen();
  const deps = checkInDeps(trials, keygen, { latest: "v1", releases });

  const first = await checkIn(deps, checkInReq());
  assertEquals((first.body as Record<string, unknown>).trialExtended, true);
  assertEquals((first.body as Record<string, unknown>).extendedForMajor, "v1");
  assertEquals(keygen.patchedExpiries.length, 1, "patched exactly once");

  const second = await checkIn(deps, checkInReq());
  assertEquals((second.body as Record<string, unknown>).trialExtended, false);
  assertEquals(
    keygen.patchedExpiries.length,
    1,
    "no second patch for the same major",
  );
});

Deno.test("I11 a recorded-but-unpatched grant is re-patched to the FROZEN target (crash recovery)", async () => {
  const releases: StableRelease[] = [{
    major: 1,
    tag: "v1.0.0",
    publishedAt: isoAt(T0 + 1000),
  }];
  const trials = trialsWith(activeRow());
  // Simulate a crash AFTER record, BEFORE patch: a v1 grant exists, patched_at null,
  // with a frozen target that differs from current+7 (proves we use the frozen value).
  const frozenTarget = isoAt(T0 + 999 * 24 * 60 * 60 * 1000);
  trials.grants.set(`${LICENSE_ID}:v1`, {
    targetExpiresAt: frozenTarget,
    patchedAt: null,
  });
  const keygen = new FakeKeygen();
  const result = await checkIn(
    checkInDeps(trials, keygen, { latest: "v1", releases }),
    checkInReq(),
  );
  assertEquals((result.body as Record<string, unknown>).trialExtended, true);
  assertEquals(keygen.patchedExpiries.length, 1);
  assertEquals(
    keygen.patchedExpiries[0].iso,
    frozenTarget,
    "must patch to the frozen target, not current+7",
  );
});

Deno.test("I12 a paid upgrade racing the extension does not re-expire the license (re-read guard)", async () => {
  const releases: StableRelease[] = [{
    major: 1,
    tag: "v1.0.0",
    publishedAt: isoAt(T0 + 1000),
  }];
  const trials = trialsWith(activeRow());
  const keygen = new FakeKeygen();
  // Selection reads the trial expiry; the re-read just before patch sees null — a
  // purchase webhook flipped the license to paid (perpetual) in the meantime.
  keygen.expiryQueue = [isoAt(T0 + 30 * 24 * 60 * 60 * 1000), null];
  const result = await checkIn(
    checkInDeps(trials, keygen, { latest: "v1", releases }),
    checkInReq(),
  );
  assertEquals((result.body as Record<string, unknown>).trialExtended, false);
  assertEquals(
    keygen.patchedExpiries.length,
    0,
    "must NOT re-add an expiry to a now-paid license",
  );
});

Deno.test("I12 no extension on a null (paid) expiry, even if a newer major shipped", async () => {
  const releases: StableRelease[] = [{
    major: 1,
    tag: "v1.0.0",
    publishedAt: isoAt(T0 + 1000),
  }];
  const trials = trialsWith(activeRow());
  const keygen = new FakeKeygen();
  keygen.expiry = null; // perpetual / paid
  const result = await checkIn(
    checkInDeps(trials, keygen, { latest: "v1", releases }),
    checkInReq(),
  );
  assertEquals((result.body as Record<string, unknown>).trialExtended, false);
  assertEquals(keygen.patchedExpiries.length, 0);
});

Deno.test("check-in survives a GitHub failure (extension skipped, still validates + returns a file)", async () => {
  const trials = trialsWith(activeRow());
  const keygen = new FakeKeygen();
  const result = await checkIn(
    checkInDeps(trials, keygen, { latest: null }),
    checkInReq(),
  );
  assertEquals(result.status, 200);
  const body = result.body as Record<string, unknown>;
  assertEquals(body.status, "ok");
  assertEquals(body.trialExtended, false);
  assert(typeof body.machineFile === "string", "still returns a fresh file");
});

Deno.test("check-in repairs a null machine before checkout", async () => {
  const trials = trialsWith(activeRow({ keygen_machine_id: null }));
  const keygen = new FakeKeygen();
  const result = await checkIn(
    checkInDeps(trials, keygen, { latest: "v0" }),
    checkInReq(),
  );
  assertEquals((result.body as Record<string, unknown>).status, "ok");
  assertEquals(trials.machineSets, [{
    licenseID: LICENSE_ID,
    machineID: `mach-${LICENSE_ID}`,
  }]);
  assertEquals(keygen.checkouts, [`mach-${LICENSE_ID}`]);
});

Deno.test("check-in re-activates a NO_MACHINE license then re-validates", async () => {
  const trials = trialsWith(activeRow({ keygen_machine_id: null }));
  const keygen = new FakeKeygen();
  keygen.validations = [{ valid: false, code: "NO_MACHINE" }, {
    valid: true,
    code: null,
  }];
  const result = await checkIn(
    checkInDeps(trials, keygen, { latest: "v0" }),
    checkInReq(),
  );
  assertEquals((result.body as Record<string, unknown>).status, "ok");
  assertEquals(
    keygen.activateCalls.length,
    1,
    "re-activated the missing machine",
  );
});

Deno.test("check-in maps a true machine-limit conflict to 409 fingerprint_mismatch", async () => {
  const trials = trialsWith(activeRow({ keygen_machine_id: null }));
  const keygen = new FakeKeygen();
  keygen.validations = [{ valid: false, code: "NO_MACHINE" }];
  keygen.activateError = new KeygenMachineLimitError("seat taken");
  const result = await checkIn(
    checkInDeps(trials, keygen, { latest: "v0" }),
    checkInReq(),
  );
  assertEquals(result.status, 409);
  assertEquals(
    (result.body as Record<string, unknown>).status,
    "fingerprint_mismatch",
  );
});

Deno.test("check-in propagates a transient activate error (not a false seat conflict)", async () => {
  const trials = trialsWith(activeRow({ keygen_machine_id: null }));
  const keygen = new FakeKeygen();
  keygen.activateError = new Error("keygen machines 503"); // transient, NOT KeygenMachineLimitError
  let threw = false;
  try {
    await checkIn(checkInDeps(trials, keygen, { latest: "v0" }), checkInReq());
  } catch {
    threw = true; // the dispatch maps this to a retryable 503, never a 409 fingerprint_mismatch
  }
  assert(
    threw,
    "a transient activate error must propagate, not become a false fingerprint_mismatch",
  );
});

Deno.test("check-in rejects an unknown major (400)", async () => {
  const trials = trialsWith(activeRow());
  const result = await checkIn(
    checkInDeps(trials, new FakeKeygen()),
    checkInReq({ appMajor: "v999" }),
  );
  assertEquals(result.status, 400);
});
