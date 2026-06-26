// Pure license-function logic with every side effect injected (DB, Keygen, LS +
// per-license signature, clock), so the Deno tests run with no network, disk, or
// env. The HTTP entrypoint (index.ts) wires the real implementations;
// index.test.ts wires fakes. Secrets never appear here — only ids and verdicts,
// and check-in NEVER returns the license key.

import type { StableRelease } from "./github.ts";
import { parseMajor } from "./github.ts";
import type { RequestSignatureResult } from "./requestSignature.ts";

/** A `device_trials` row, as the mint + check-in logic read it. */
export interface TrialRow {
  status: string; // 'pending' | 'active' | 'paid'
  fingerprint: string;
  keygen_license_id: string | null;
  keygen_license_key: string | null;
  keygen_machine_id: string | null;
  started_major: string; // the major the trial was born under (extension eligibility)
  created_at: string; // ISO 8601
}

/** An extension grant row, as `claimExtensionGrant` returns it. */
export interface ExtensionGrant {
  /** The FROZEN absolute target expiry recorded on the first claim for this major. */
  targetExpiresAt: string; // ISO 8601
  /** Null until the Keygen patch is confirmed; the once-per-major CAS flag. */
  patchedAt: string | null;
}

/** The `device_trials` persistence seam (mint + check-in). */
export interface TrialStore {
  /**
   * `INSERT (fingerprint, status='pending', claim_id) ON CONFLICT DO NOTHING`.
   * Resolves the per-claim token when this caller won the claim, or `null` when a
   * row already exists (lost). The token is required by `activate`/`releaseClaim`
   * so a stalled winner can only mutate the row it actually claimed.
   */
  claim(fingerprint: string): Promise<string | null>;
  get(fingerprint: string): Promise<TrialRow | null>;
  /** Looks a row up by license id (check-in's entry). A DB error must SURFACE (throw), never mask as a no-row. */
  getByLicense(licenseID: string): Promise<TrialRow | null>;
  /**
   * `UPDATE ... SET status='active', id, key WHERE fingerprint AND status='pending'
   * AND claim_id = $token`. Resolves true when one row changed (we still own the
   * claim), false when it was reclaimed by another winner in the meantime.
   */
  activate(
    fingerprint: string,
    claimToken: string,
    licenseID: string,
    licenseKey: string,
  ): Promise<boolean>;
  /** `DELETE ... WHERE fingerprint AND status='pending' AND claim_id = $token` — releases only the caller's own claim. */
  releaseClaim(fingerprint: string, claimToken: string): Promise<void>;
  /**
   * `DELETE ... WHERE fingerprint = $1 AND status = 'pending' AND created_at < $2`
   * — reclaims ONLY a stale pending row. The `created_at` guard is load-bearing:
   * without it, a delete-by-fingerprint could remove another request's fresh claim
   * (created after we read the stale one) and cause a double-mint.
   */
  reclaimStale(fingerprint: string, olderThanMs: number): Promise<void>;
  /** Stores the activated machine id (repairs a null after activation). Writes `updated_at`. */
  setMachine(licenseID: string, machineID: string): Promise<void>;
  /**
   * `SELECT major FROM trial_extension_grants WHERE keygen_license_id = $1 AND
   * patched_at IS NOT NULL` — the majors with a CONFIRMED (patched) extension. It
   * must NOT include a recorded-but-unpatched grant: that one has to be re-selected
   * so a crash between record and patch re-converges to +7 exactly once (I11).
   */
  extendedMajors(licenseID: string): Promise<string[]>;
  /**
   * `INSERT trial_extension_grants ON CONFLICT (keygen_license_id, major) DO
   * NOTHING RETURNING` — records the grant FIRST, to a fixed `target_expires_at`,
   * and returns the existing row on conflict. The unique key freezes the absolute
   * target on the first claim, so a retry re-patches to the SAME value (+7 exactly
   * once), never `+= 7` again.
   */
  claimExtensionGrant(
    licenseID: string,
    major: string,
    previousExpiresAt: string,
    targetExpiresAt: string,
  ): Promise<ExtensionGrant>;
  /** `UPDATE ... SET patched_at = now() WHERE ... AND patched_at IS NULL` — the once-per-major CAS. */
  markExtensionPatched(licenseID: string, major: string): Promise<void>;
  /** Records the check-in time. Writes `updated_at`. */
  touchCheckIn(licenseID: string): Promise<void>;
}

/** A purchase row referencing a license we never minted (FK violation) — permanent, ack 200. */
export class PurchaseForgedLicenseError extends Error {}

/** The `purchases` persistence seam. */
export interface PurchaseStore {
  exists(orderID: string): Promise<boolean>;
  /**
   * `INSERT ... ON CONFLICT (ls_order_id) DO NOTHING`. A duplicate is a no-op
   * (resolves). Throws `PurchaseForgedLicenseError` on an FK violation (a forged
   * license id — permanent), and any other Error for a transient failure the
   * caller should make Lemon Squeezy retry.
   */
  record(purchase: {
    orderID: string;
    licenseID: string;
    email: string;
    variantID: string;
    purchasedMajor: string;
    entitlementCode: string;
  }): Promise<void>;
}

/** The verdict of a Keygen `validate-key` (plain fingerprint scope). */
export interface KeygenValidation {
  valid: boolean;
  code: string | null;
}

/** A forged or unknown license id — the webhook returns 200 (do not retry-storm). */
export class KeygenLicenseNotFoundError extends Error {}

/** A true `maxMachines` conflict (a DIFFERENT device holds the seat) — distinct from a reusable same-fingerprint machine. */
export class KeygenMachineLimitError extends Error {}

/** The Keygen admin seam (holds the secret token in index.ts, never here). */
export interface KeygenAdmin {
  /** Creates a 30-day trial license; resolves its resource id + secret key. */
  createTrialLicense(): Promise<{ id: string; key: string }>;
  /**
   * Upgrades a license to Paid: swaps the policy to the Paid policy AND clears the
   * trial expiry (a one-time purchase is perpetual). Throws
   * `KeygenLicenseNotFoundError` for an unknown/forged license id (a 404), and any
   * other Error for a transient failure.
   */
  upgradeToPaid(licenseID: string): Promise<void>;
  /**
   * Attaches `STOWER_V0` directly to the license (license-level — unlocks add up
   * across majors). A 400 "already attached" resolves (idempotent). Throws on a
   * transient failure so Lemon Squeezy retries. The required entitlement id is
   * read from env at boot — a missing `KEYGEN_V0_ENTITLEMENT` throws at construction.
   */
  attachV0(licenseID: string): Promise<void>;
  /**
   * Activates a machine for `fingerprint` (license-key auth), reusing an existing
   * machine for the SAME fingerprint. Throws `KeygenMachineLimitError` only on a
   * true `maxMachines:1` conflict (a different device). Resolves the machine id.
   */
  activateMachine(
    licenseID: string,
    licenseKey: string,
    fingerprint: string,
  ): Promise<string>;
  /** Checks out a signed machine file (admin auth, `ttl=604800`, signed + `include=`). Resolves the PEM certificate. */
  checkoutMachineFile(machineID: string): Promise<string>;
  /** Plain `validate-key` with a fingerprint scope (no entitlement scope — OR is applied in code, I4). */
  validate(licenseKey: string, fingerprint: string): Promise<KeygenValidation>;
  /** The license's effective entitlement codes (policy-inherited + direct). */
  effectiveEntitlements(licenseID: string): Promise<string[]>;
  /** The license's current expiry (ISO) or null (perpetual / paid). */
  currentExpiry(licenseID: string): Promise<string | null>;
  /** Sets the license expiry to an absolute ISO timestamp (target-state, not a delta). */
  patchExpiry(licenseID: string, iso: string): Promise<void>;
}

/** A handler's HTTP reply. */
export interface Reply {
  status: number;
  body?: unknown;
}

/** Injected dependencies for `mintTrial`. */
export interface MintDeps {
  trials: TrialStore;
  keygen: KeygenAdmin;
  now: () => number; // ms since epoch
  reclaimWindowMs: number;
}

/** The mint request body — only the device fingerprint hash. */
export interface MintRequest {
  fingerprint: string;
}

/** Injected dependencies for `handleWebhook`. */
export interface WebhookDeps {
  purchases: PurchaseStore;
  keygen: KeygenAdmin;
  verifySignature: (rawBody: string, signature: string) => Promise<boolean>;
  paidVariantID: string;
  /** `SELECT 1 FROM device_trials WHERE keygen_license_id = $1` — true when we minted it. */
  licenseIsMinted: (licenseID: string) => Promise<boolean>;
}

/** The check-in request body. */
export interface CheckInRequest {
  licenseID: string;
  fingerprint: string;
}

/** Injected dependencies for `checkIn`. */
export interface CheckInDeps {
  trials: TrialStore;
  keygen: KeygenAdmin;
  github: {
    currentLatestMajor(): Promise<string | null>;
    stableReleases(): Promise<StableRelease[]>;
  };
  /** Verifies the per-license signature once the row's key is known (JC5). */
  verifySignature: (key: string) => Promise<RequestSignatureResult>;
}

/** The entitlement code the offline OR + the webhook attach both name (JC9: a constant, not env). */
export const STOWER_V0_ENTITLEMENT_CODE = "STOWER_V0";
/** The any-version trial unlock (policy-inherited). */
export const STOWER_TRIAL_ENTITLEMENT_CODE = "STOWER_TRIAL";
/** The major a v0 paid order records. */
const PURCHASED_MAJOR_V0 = "v0";
/** A flat +7-day extension (I12: adds to the current expiry, never restarts). */
const EXTENSION_DAYS = 7;
const MS_PER_DAY = 24 * 60 * 60 * 1000;

/** Keygen `validate-key` codes that mean the trial/license clock ran out. */
const EXPIRED_CODES = ["EXPIRED"];
/** Codes that mean the machine binding is gone and can be re-activated, not a true seat conflict. */
const MACHINE_MISSING_CODES = [
  "NO_MACHINE",
  "NO_MACHINES",
  "FINGERPRINT_SCOPE_MISMATCH",
  "FINGERPRINT_SCOPE_REQUIRED",
];
/** Codes that mean the license is administratively blocked. */
const SUSPENDED_CODES = ["SUSPENDED", "BANNED"];

const RETRY_REPLY: Reply = { status: 503, body: { error: "retry" } };
const MINT_CLAIM_ATTEMPTS = 2;

function reply(status: number, body: unknown): Reply {
  return { status, body };
}

/**
 * Mints (or returns the existing) trial license for `fingerprint`, idempotent on
 * the `device_trials` row. Now also ensures an activated machine + a freshly
 * checked-out signed machine file before replying, so the app has offline
 * authority from first run. A Keygen failure AFTER the license exists keeps the
 * (now active) row and returns a retry — the app's next mint reuses it (I9).
 */
export async function mintTrial(
  deps: MintDeps,
  req: MintRequest,
): Promise<Reply> {
  if (!req.fingerprint) {
    return { status: 400, body: { error: "fingerprint required" } };
  }

  for (let attempt = 0; attempt < MINT_CLAIM_ATTEMPTS; attempt++) {
    const claimToken = await deps.trials.claim(req.fingerprint);
    if (claimToken) {
      return await mintForWinner(deps, req.fingerprint, claimToken);
    }
    const row = await deps.trials.get(req.fingerprint);
    if (!row) continue; // lost the claim, then the row vanished — retry the claim

    if (
      row.status === "active" && row.keygen_license_key && row.keygen_license_id
    ) {
      try {
        return await mintSuccessReply(deps, {
          licenseID: row.keygen_license_id,
          licenseKey: row.keygen_license_key,
          machineID: row.keygen_machine_id,
        }, req.fingerprint);
      } catch (_error) {
        return RETRY_REPLY; // machine/checkout failed; the license stays, app retries
      }
    }
    // A 'pending' row: a winner is mid-mint, or it crashed. Reclaim it once it is
    // older than the window; otherwise tell the caller to retry shortly. The
    // reclaim deletes only rows older than `cutoff`, so a competing fresh claim
    // (newer created_at) is never destroyed.
    const cutoffMs = deps.now() - deps.reclaimWindowMs;
    if (Date.parse(row.created_at) < cutoffMs) {
      await deps.trials.reclaimStale(req.fingerprint, cutoffMs);
      continue;
    }
    return RETRY_REPLY;
  }
  return RETRY_REPLY;
}

/**
 * The claim winner. Keygen-create failure → nothing created → release the claim.
 * DB-activate failure AFTER create → the license exists → keep the claim (orphan
 * guard). Machine/checkout failure AFTER the row is active → keep the active row
 * and return retry; the next mint reuses it. The reply renames the as-built `key`
 * field to `licenseKey` and adds `machineID`/`machineFile` (contract v1.13).
 */
async function mintForWinner(
  deps: MintDeps,
  fingerprint: string,
  claimToken: string,
): Promise<Reply> {
  let license: { id: string; key: string };
  try {
    license = await deps.keygen.createTrialLicense();
  } catch (_error) {
    await deps.trials.releaseClaim(fingerprint, claimToken);
    return RETRY_REPLY;
  }
  let won: boolean;
  try {
    won = await deps.trials.activate(
      fingerprint,
      claimToken,
      license.id,
      license.key,
    );
  } catch (_error) {
    return RETRY_REPLY; // DB write failed; keep the claim (orphan-storm guard)
  }
  if (!won) {
    // Our claim was reclaimed while we were minting; another winner owns the row.
    // Our license is an orphan — never return it as authoritative. Retry: the next
    // loop reads the now-active row and returns the owning license.
    return RETRY_REPLY;
  }
  try {
    return await mintSuccessReply(deps, {
      licenseID: license.id,
      licenseKey: license.key,
      machineID: null,
    }, fingerprint);
  } catch (_error) {
    return RETRY_REPLY; // license + active row exist; the next mint reuses them
  }
}

/** Ensures an activated machine + a fresh signed file, then builds the mint reply. */
async function mintSuccessReply(
  deps: MintDeps,
  ids: { licenseID: string; licenseKey: string; machineID: string | null },
  fingerprint: string,
): Promise<Reply> {
  let machineID = ids.machineID;
  if (machineID === null) {
    machineID = await deps.keygen.activateMachine(
      ids.licenseID,
      ids.licenseKey,
      fingerprint,
    );
    await deps.trials.setMachine(ids.licenseID, machineID);
  }
  const machineFile = await deps.keygen.checkoutMachineFile(machineID);
  return {
    status: 200,
    body: {
      minted: true,
      licenseKey: ids.licenseKey,
      licenseID: ids.licenseID,
      machineID,
      machineFile,
    },
  };
}

/**
 * Reachable-launch check-in (the gate authority). Verifies the per-license
 * signature, applies an at-most-one-per-major +7d
 * extension (record-before-patch, idempotent — I11), validates with Keygen +
 * repairs a missing machine, applies the entitlement OR in code (I4), checks out a
 * fresh signed file (I13), and NEVER returns `keygen_license_key`.
 */
export async function checkIn(
  deps: CheckInDeps,
  req: CheckInRequest,
): Promise<Reply> {
  const row = await deps.trials.getByLicense(req.licenseID); // DB error surfaces → dispatch 503
  if (!row || !row.keygen_license_id || !row.keygen_license_key) {
    return reply(404, { status: "unknown_license" });
  }
  if (row.fingerprint !== req.fingerprint) {
    return reply(409, {
      status: "fingerprint_mismatch",
      licenseID: req.licenseID,
    });
  }
  const signature = await deps.verifySignature(row.keygen_license_key);
  if (!signature.ok) return reply(401, { status: "bad_signature" });

  const required = STOWER_V0_ENTITLEMENT_CODE; // v0 is the only product today

  const latest = await deps.github.currentLatestMajor(); // null on failure (never throws)
  const extension = await applyExtension(deps, row, latest);

  const validated = await validateWithRepair(deps, row, req.fingerprint);
  if ("terminal" in validated) return validated.terminal;

  const entitlements = await deps.keygen.effectiveEntitlements(
    row.keygen_license_id,
  );
  if (
    !(entitlements.includes(STOWER_TRIAL_ENTITLEMENT_CODE) ||
      entitlements.includes(required))
  ) {
    return reply(200, {
      status: "wrong_version",
      licenseID: req.licenseID,
      currentLatestMajor: latest,
    });
  }

  let machineID = validated.machineID;
  if (machineID === null) {
    try {
      machineID = await deps.keygen.activateMachine(
        row.keygen_license_id,
        row.keygen_license_key,
        req.fingerprint,
      );
    } catch (error) {
      if (error instanceof KeygenMachineLimitError) {
        return reply(409, {
          status: "fingerprint_mismatch",
          licenseID: req.licenseID,
        });
      }
      throw error;
    }
  }
  if (machineID !== row.keygen_machine_id) {
    await deps.trials.setMachine(row.keygen_license_id, machineID);
  }
  const machineFile = await deps.keygen.checkoutMachineFile(machineID);
  await deps.trials.touchCheckIn(row.keygen_license_id);

  return reply(200, {
    status: "ok",
    trialExtended: extension.extended,
    extendedForMajor: extension.major,
    currentLatestMajor: latest,
    licenseID: req.licenseID,
    machineFile,
  });
}

/**
 * Applies an at-most-one-per-major +7d extension. Records the grant to a fixed
 * target BEFORE patching Keygen, then patches to that frozen absolute target —
 * so a crash anywhere re-converges to +7 exactly once (I11). The `patched_at` CAS
 * skips the Keygen call once confirmed.
 */
async function applyExtension(
  deps: CheckInDeps,
  row: TrialRow,
  latest: string | null,
): Promise<{ extended: boolean; major?: string }> {
  if (latest === null) return { extended: false };
  const current = await deps.keygen.currentExpiry(
    row.keygen_license_id as string,
  );
  const major = await selectExtensionMajor(deps, row, latest, current);
  if (major === null || current === null) return { extended: false };

  const target = addDays(current, EXTENSION_DAYS);
  if (target === null) return { extended: false }; // NaN-expiry guard (I12)
  const grant = await deps.trials.claimExtensionGrant(
    row.keygen_license_id as string,
    major,
    current,
    target,
  );
  if (grant.patchedAt !== null) return { extended: false }; // already extended for this major
  // Re-read the expiry immediately before patching. A purchase webhook may have run
  // concurrently and set the expiry to null (perpetual/paid); patching then would
  // re-add an expiry to a PAID license and eventually lock the buyer out. If it is
  // no longer a trial expiry, skip — never re-add an expiry to a paid license.
  const latestExpiry = await deps.keygen.currentExpiry(
    row.keygen_license_id as string,
  );
  if (latestExpiry === null) return { extended: false };
  await deps.keygen.patchExpiry(
    row.keygen_license_id as string,
    grant.targetExpiresAt,
  );
  await deps.trials.markExtensionPatched(
    row.keygen_license_id as string,
    major,
  );
  return { extended: true, major };
}

/**
 * The single oldest un-extended eligible major, or null. Never on paid / null
 * expiry; only majors above the started major, published after the trial began,
 * and not already granted (JC8).
 */
async function selectExtensionMajor(
  deps: CheckInDeps,
  row: TrialRow,
  latest: string,
  currentExpiry: string | null,
): Promise<string | null> {
  if (row.status === "paid") return null;
  if (currentExpiry === null) return null;
  const startedNum = parseMajor(row.started_major);
  const latestNum = parseMajor(latest);
  if (startedNum === null || latestNum === null || latestNum <= startedNum) {
    return null;
  }
  const granted = new Set(
    await deps.trials.extendedMajors(row.keygen_license_id as string),
  );
  const createdAtMs = Date.parse(row.created_at);
  const candidates = (await deps.github.stableReleases())
    .filter((r) => r.major > startedNum && r.major <= latestNum)
    .filter((r) => Date.parse(r.publishedAt) > createdAtMs)
    .filter((r) => !granted.has(`v${r.major}`))
    .map((r) => r.major)
    .sort((a, b) => a - b);
  return candidates.length === 0 ? null : `v${candidates[0]}`;
}

/** Adds whole days to an ISO timestamp; null on an unparseable expiry. */
function addDays(iso: string, days: number): string | null {
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) return null;
  return new Date(ms + days * MS_PER_DAY).toISOString();
}

/**
 * Validates the license; on a missing-machine code, re-activates the stored
 * machine and re-validates once. Returns a terminal Reply for a blocked/expired
 * license, or the (possibly repaired) machine id to proceed with.
 */
async function validateWithRepair(
  deps: CheckInDeps,
  row: TrialRow,
  fingerprint: string,
): Promise<{ terminal: Reply } | { machineID: string | null }> {
  const licenseID = row.keygen_license_id as string;
  const key = row.keygen_license_key as string;
  let verdict = await deps.keygen.validate(key, fingerprint);
  if (verdict.valid) return { machineID: row.keygen_machine_id };

  const code = (verdict.code ?? "").toUpperCase();
  if (EXPIRED_CODES.includes(code)) {
    return { terminal: reply(200, { status: "expired", licenseID }) };
  }
  if (SUSPENDED_CODES.includes(code)) {
    return { terminal: reply(200, { status: "expired", licenseID }) };
  }
  if (MACHINE_MISSING_CODES.includes(code)) {
    let machineID: string;
    try {
      machineID = await deps.keygen.activateMachine(
        licenseID,
        key,
        fingerprint,
      );
    } catch (error) {
      if (error instanceof KeygenMachineLimitError) {
        return {
          terminal: reply(409, { status: "fingerprint_mismatch", licenseID }),
        };
      }
      throw error;
    }
    if (machineID !== row.keygen_machine_id) {
      await deps.trials.setMachine(licenseID, machineID);
    }
    verdict = await deps.keygen.validate(key, fingerprint);
    if (verdict.valid) return { machineID };
    if (EXPIRED_CODES.includes((verdict.code ?? "").toUpperCase())) {
      return { terminal: reply(200, { status: "expired", licenseID }) };
    }
    return { terminal: reply(200, { status: "expired", licenseID }) }; // still invalid → blocked
  }
  // Unknown invalid code: fail closed (blocked) rather than let an unrecognized state through.
  return { terminal: reply(200, { status: "expired", licenseID }) };
}

/**
 * Processes a Lemon Squeezy `order_created` webhook. Validates and upgrades
 * BEFORE recording, so a bad variant is never marked processed and a transient
 * failure stays retryable (B7): verify signature, replay-check, variant-check,
 * `PUT /policy` + clear expiry, attach `STOWER_V0`, then record only on success.
 */
export async function handleWebhook(
  deps: WebhookDeps,
  rawBody: string,
  signature: string,
): Promise<Reply> {
  if (!(await deps.verifySignature(rawBody, signature))) return { status: 401 };

  let event: LemonSqueezyEvent;
  try {
    event = JSON.parse(rawBody) as LemonSqueezyEvent;
  } catch {
    return { status: 400 };
  }
  if (event?.meta?.event_name !== "order_created") return { status: 200 };

  const orderID = String(event?.data?.id ?? "");
  const licenseID = String(event?.meta?.custom_data?.license_id ?? "");
  const variantID = String(
    event?.data?.attributes?.first_order_item?.variant_id ?? "",
  );
  const email = String(event?.data?.attributes?.user_email ?? "");
  if (!orderID) return { status: 200 };

  if (await deps.purchases.exists(orderID)) return { status: 200 }; // replay no-op
  if (variantID !== deps.paidVariantID) return { status: 200 }; // not our product

  if (!licenseID) {
    console.error(
      `paid order ${orderID} for the paid variant has no license_id; manual reconciliation needed`,
    );
    return { status: 200 };
  }

  // The license id is client-controlled checkout data. Prove WE minted it before
  // mutating any Keygen license — otherwise a tampered checkout could upgrade an
  // arbitrary license.
  let minted: boolean;
  try {
    minted = await deps.licenseIsMinted(licenseID);
  } catch (_error) {
    return { status: 500 }; // transient lookup failure → LS retries (never ack as "not minted")
  }
  if (!minted) {
    console.error(
      `order ${orderID} references a license we did not mint; ignoring`,
    );
    return { status: 200 };
  }

  try {
    await deps.keygen.upgradeToPaid(licenseID);
  } catch (error) {
    if (error instanceof KeygenLicenseNotFoundError) return { status: 200 }; // forged id
    return { status: 500 }; // transient — LS retries (upgrade is idempotent)
  }

  try {
    await deps.keygen.attachV0(licenseID);
  } catch (error) {
    if (error instanceof KeygenLicenseNotFoundError) return { status: 200 };
    return { status: 500 }; // transient attach failure — LS retries (attach is idempotent)
  }

  try {
    await deps.purchases.record({
      orderID,
      licenseID,
      email,
      variantID,
      purchasedMajor: PURCHASED_MAJOR_V0,
      entitlementCode: STOWER_V0_ENTITLEMENT_CODE,
    });
  } catch (error) {
    // A forged license id (FK violation) is permanent — the upgrade already ran
    // (idempotent), so ack and stop. A transient DB failure → 500 so LS retries.
    if (error instanceof PurchaseForgedLicenseError) return { status: 200 };
    return { status: 500 };
  }
  return { status: 200 };
}

/** The slice of the LS `order_created` payload the webhook reads. */
interface LemonSqueezyEvent {
  meta?: {
    event_name?: string;
    custom_data?: { license_id?: unknown };
  };
  data?: {
    id?: unknown;
    attributes?: {
      user_email?: unknown;
      first_order_item?: { variant_id?: unknown };
    };
  };
}
