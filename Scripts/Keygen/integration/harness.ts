// Shared helpers for the licensing INTEGRATION tests, which run against a live,
// local Keygen Community Edition harness (Scripts/Keygen/). Unlike the hermetic
// unit tests, these talk real HTTP to the proxy URL in Scripts/Keygen/.runtime.env.
//
// They FAIL LOUDLY when the harness is absent — never skip. A skipped guardrail
// reports green while testing nothing (AGENTS.md: "tests must fail, never skip").
// Plan Beta reuses these helpers for its own integration suite.

const JSON_API_CONTENT_TYPE = "application/vnd.api+json";

/** The live harness coordinates, read from the env that `up.sh` minted. */
export interface HarnessEnv {
  /** The Caddy proxy base URL, e.g. http://localhost:8080. */
  baseUrl: string;
  /** The Keygen account id (a fixed UUID from Scripts/Keygen/.env.docker.fake). */
  account: string;
  /** A freshly-minted admin token (`admin-…`). */
  token: string;
  /** Admin `Authorization` + JSON:API content headers. */
  headers: Record<string, string>;
}

/**
 * Reads + requires the harness env. Throws loudly if any var is missing — this is
 * the fail-loud guard: with no harness up, the integration suite errors instead of
 * passing vacuously. `up.sh` writes these into Scripts/Keygen/.runtime.env and the
 * `test:integration` task loads them via `--env-file`.
 */
export function requireEnv(): HarnessEnv {
  const baseUrl = Deno.env.get("KEYGEN_BASE_URL");
  const account = Deno.env.get("KEYGEN_ACCOUNT");
  const token = Deno.env.get("KEYGEN_TOKEN");
  if (!baseUrl || !account || !token) {
    const missing = [
      ["KEYGEN_BASE_URL", baseUrl],
      ["KEYGEN_ACCOUNT", account],
      ["KEYGEN_TOKEN", token],
    ].filter(([, v]) => !v).map(([k]) => k).join(", ");
    throw new Error(
      `Keygen harness not up (missing ${missing}). Run Scripts/Keygen/up.sh ` +
        `first — integration tests do NOT skip.`,
    );
  }
  return {
    baseUrl,
    account,
    token,
    headers: {
      "Authorization": `Bearer ${token}`,
      "Content-Type": JSON_API_CONTENT_TYPE,
      "Accept": JSON_API_CONTENT_TYPE,
    },
  };
}

/**
 * Reads + requires the account Ed25519 public key (hex), which `up.sh` captures
 * into .runtime.env as KEYGEN_PUBLIC_KEY. Only the machine-path test needs it (to
 * verify a checked-out machine file offline), so it is a separate guard from
 * requireEnv. Throws loudly if absent — never silently skips the signature check.
 */
export function requirePublicKey(): string {
  const publicKey = Deno.env.get("KEYGEN_PUBLIC_KEY");
  if (!publicKey) {
    throw new Error(
      "KEYGEN_PUBLIC_KEY is not set — re-run Scripts/Keygen/up.sh (it captures the " +
        "account Ed25519 public key). The machine-file signature check does NOT skip.",
    );
  }
  return publicKey;
}

/** A JSON:API resource narrowed to the fields these tests read. */
export interface KeygenResource {
  id: string;
  type: string;
  attributes?: Record<string, unknown>;
  meta?: Record<string, unknown>;
}

/** The shape a Keygen JSON:API response can take across these tests. */
export interface KeygenJSON {
  data?: KeygenResource | KeygenResource[];
  meta?: Record<string, unknown>;
  errors?: Array<{ detail?: string; code?: string }>;
}

/**
 * A thin JSON:API client over real `fetch`, bound to the harness `baseUrl` and
 * admin headers. Per-call header overrides (e.g. license-scoped `Authorization`)
 * merge over the admin defaults. Returns the parsed body plus the status so a test
 * can assert on either; never throws on a non-2xx (the test decides what's an error).
 */
export function keygenFetch(env: HarnessEnv) {
  return async function send(
    method: string,
    path: string,
    options: { body?: unknown; headers?: Record<string, string> } = {},
  ): Promise<{ status: number; json: KeygenJSON; text: string }> {
    const url = path.startsWith("http") ? path : `${env.baseUrl}${path}`;
    const response = await fetch(url, {
      method,
      headers: { ...env.headers, ...(options.headers ?? {}) },
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    });
    const text = await response.text();
    let json: KeygenJSON = {};
    try {
      json = text.length > 0 ? JSON.parse(text) as KeygenJSON : {};
    } catch {
      json = {};
    }
    return { status: response.status, json, text };
  };
}

/** The account path prefix every Keygen call shares. */
export function accountPath(env: HarnessEnv): string {
  return `/v1/accounts/${env.account}`;
}
