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
  /** `INSERT ... ON CONFLICT DO NOTHING`; resolves true when this caller won the claim. */
  claim(fingerprint: string): Promise<boolean>;
  get(fingerprint: string): Promise<TrialRow | null>;
  /** Sets the minted id/key and flips status to 'active'. */
  activate(
    fingerprint: string,
    licenseID: string,
    licenseKey: string,
  ): Promise<void>;
  /** `DELETE ... WHERE fingerprint = $1 AND status = 'pending'` — releases a claim, never an active row. */
  releaseClaim(fingerprint: string): Promise<void>;
}

/** The `purchases` persistence seam. */
export interface PurchaseStore {
  exists(orderID: string): Promise<boolean>;
  /** `INSERT ... ON CONFLICT (ls_order_id) DO NOTHING`; throws on an FK violation (a forged license id). */
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
   * Changes a license's policy to Paid. Throws `KeygenLicenseNotFoundError` for an
   * unknown/forged license id (a 404), and any other Error for a transient failure.
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
    if (await deps.trials.claim(fingerprint)) {
      return await mintForWinner(deps, fingerprint);
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
    // older than the window; otherwise tell the caller to retry shortly.
    const age = deps.now() - Date.parse(row.created_at);
    if (age > deps.reclaimWindowMs) {
      await deps.trials.releaseClaim(fingerprint);
      continue;
    }
    return RETRY_REPLY;
  }
  return RETRY_REPLY;
}

/** The claim winner: create the Keygen license, or release the claim on failure. */
async function mintForWinner(
  deps: MintDeps,
  fingerprint: string,
): Promise<Reply> {
  try {
    const license = await deps.keygen.createTrialLicense();
    await deps.trials.activate(fingerprint, license.id, license.key);
    return { status: 200, body: { key: license.key, licenseID: license.id } };
  } catch (_error) {
    await deps.trials.releaseClaim(fingerprint);
    return RETRY_REPLY;
  }
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

  try {
    await deps.keygen.upgradeToPaid(licenseID);
  } catch (error) {
    if (error instanceof KeygenLicenseNotFoundError) return { status: 200 }; // forged id — do not retry-storm
    return { status: 500 }; // transient — LS retries and re-attempts the upgrade
  }

  try {
    await deps.purchases.record({ orderID, licenseID, email, variantID });
  } catch (_error) {
    return { status: 200 }; // FK violation / dup — already upgraded; do not retry
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
