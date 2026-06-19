// Pure license-function logic with every side effect injected (DB, Keygen, LS
// signature, clock), so the Deno tests run with no network, disk, or env. The
// HTTP entrypoint (index.ts) wires the real implementations; index.test.ts wires
// fakes. Secrets never appear here — only ids and verdicts.

/** A `device_trials` row, as the mint logic reads it. */
export interface TrialRow {
  status: string;
  keygen_license_id: string | null;
  keygen_license_key: string | null;
  created_at: string; // ISO 8601
}

/** The `device_trials` persistence seam. */
export interface TrialStore {
  /**
   * `INSERT (fingerprint, status='pending', claim_id) ON CONFLICT DO NOTHING`.
   * Resolves the per-claim token when this caller won the claim, or `null` when a
   * row already exists (lost). The token is required by `activate`/`releaseClaim`
   * so a stalled winner can only mutate the row it actually claimed.
   */
  claim(fingerprint: string): Promise<string | null>;
  get(fingerprint: string): Promise<TrialRow | null>;
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
  }): Promise<void>;
}

/** The Keygen admin seam (holds the secret token in index.ts, never here). */
export interface KeygenAdmin {
  /** Creates a 30-day trial license; resolves its resource id + secret key. */
  createTrialLicense(): Promise<{ id: string; key: string }>;
  /**
   * Upgrades a license to Paid: swaps the policy to the Paid policy AND clears the
   * trial expiry (a one-time purchase is perpetual — the policy swap alone would
   * leave the now+30d trial expiry, so the paid license would still expire).
   * Throws `KeygenLicenseNotFoundError` for an unknown/forged license id (a 404),
   * and any other Error for a transient failure.
   */
  upgradeToPaid(licenseID: string): Promise<void>;
}

/** A forged or unknown license id — the webhook returns 200 (do not retry-storm). */
export class KeygenLicenseNotFoundError extends Error {}

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

/** Injected dependencies for `handleWebhook`. */
export interface WebhookDeps {
  purchases: PurchaseStore;
  keygen: KeygenAdmin;
  verifySignature: (rawBody: string, signature: string) => Promise<boolean>;
  paidVariantID: string;
  /** `SELECT 1 FROM device_trials WHERE keygen_license_id = $1` — true when we minted it. */
  licenseIsMinted: (licenseID: string) => Promise<boolean>;
}

const RETRY_REPLY: Reply = { status: 503, body: { error: "retry" } };
const MINT_CLAIM_ATTEMPTS = 2;

/**
 * Mints (or returns the existing) trial license for `fingerprint`, idempotent on
 * the `device_trials` row, never on a Keygen machine lookup (closes B2). A claim
 * is the `pending` row; only the winner calls Keygen; a Keygen failure releases
 * the claim so the fingerprint is never poisoned with null ids.
 */
export async function mintTrial(
  deps: MintDeps,
  fingerprint: string,
): Promise<Reply> {
  if (!fingerprint) {
    return { status: 400, body: { error: "fingerprint required" } };
  }

  for (let attempt = 0; attempt < MINT_CLAIM_ATTEMPTS; attempt++) {
    const claimToken = await deps.trials.claim(fingerprint);
    if (claimToken) {
      return await mintForWinner(deps, fingerprint, claimToken);
    }
    const row = await deps.trials.get(fingerprint);
    if (!row) continue; // lost the claim, then the row vanished — retry the claim

    if (
      row.status === "active" && row.keygen_license_key && row.keygen_license_id
    ) {
      return {
        status: 200,
        body: { key: row.keygen_license_key, licenseID: row.keygen_license_id },
      };
    }
    // A 'pending' row: a winner is mid-mint, or it crashed. Reclaim it once it is
    // older than the window; otherwise tell the caller to retry shortly. The
    // reclaim deletes only rows older than `cutoff`, so a competing fresh claim
    // (newer created_at) is never destroyed.
    const cutoffMs = deps.now() - deps.reclaimWindowMs;
    if (Date.parse(row.created_at) < cutoffMs) {
      await deps.trials.reclaimStale(fingerprint, cutoffMs);
      continue;
    }
    return RETRY_REPLY;
  }
  return RETRY_REPLY;
}

/**
 * The claim winner. The two failure modes are handled differently on purpose:
 *  - Keygen create failed → nothing was created, so release the claim; a retry
 *    can safely mint.
 *  - Keygen create SUCCEEDED but the DB write failed → the license exists.
 *    Do NOT release the claim — releasing it would let a retry mint a SECOND
 *    license (an orphan storm). Leave the pending row; only the bounded
 *    stale-reclaim path may re-mint, capping orphans instead of one-per-retry.
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
  return { status: 200, body: { key: license.key, licenseID: license.id } };
}

/**
 * Processes a Lemon Squeezy `order_created` webhook. Validates and upgrades
 * BEFORE recording, so a bad variant is never marked processed and a transient
 * Keygen failure stays retryable (closes B7): verify signature, replay-check,
 * variant-check, `PUT /policy`, then record only on success.
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
    // A paid order for OUR variant but with no license id to map it to (a checkout
    // that didn't carry custom_data.license_id). Retrying can't conjure the id, so
    // ack (200) to stop an LS retry storm, but alert loudly for manual
    // reconciliation rather than silently leaving a paying buyer on trial.
    console.error(
      `paid order ${orderID} for the paid variant has no license_id; manual reconciliation needed`,
    );
    return { status: 200 };
  }

  // The license id is client-controlled checkout data. Prove WE minted it before
  // mutating any Keygen license — otherwise a tampered checkout could PUT an
  // arbitrary license to Paid. (The purchases FK is the same guard one layer down;
  // this just refuses the Keygen call entirely for a license we don't own.)
  let minted: boolean;
  try {
    minted = await deps.licenseIsMinted(licenseID);
  } catch (_error) {
    // A transient lookup failure must NOT be acked as "not minted" (that would
    // drop a real paid upgrade silently) — 500 so Lemon Squeezy retries.
    return { status: 500 };
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
    if (error instanceof KeygenLicenseNotFoundError) return { status: 200 }; // forged id — do not retry-storm
    return { status: 500 }; // transient — LS retries and re-attempts the upgrade
  }

  try {
    await deps.purchases.record({ orderID, licenseID, email, variantID });
  } catch (error) {
    // A forged license id (FK violation) is permanent — the upgrade already ran
    // (idempotent), so ack and stop. A transient DB failure must NOT be acked:
    // return 500 so Lemon Squeezy retries and the audit row eventually lands (the
    // re-run upgrade PUT is idempotent and harmless).
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
