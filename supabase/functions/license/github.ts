// GitHub releases adapter: answers the one licensing question check-in asks of
// GitHub — "what is the highest STABLE major shipped?" — for the once-per-major
// +7-day extension decision (JC4). This is licensing-only: NOT Sparkle, NOT
// app-upgrade logic. It drops drafts/prereleases, parses the SemVer major, caches
// for 5 minutes (the cache is injected so it survives warm Edge Function
// invocations), and on ANY failure returns cached-or-null — check-in proceeds and
// the extension is simply skipped, never blocked by a release-source flake.

/** A shipped stable release, narrowed to what the extension decision needs. */
export interface StableRelease {
  major: number;
  tag: string;
  publishedAt: string; // ISO 8601
}

/** The injected, mutated cache — module-level in index.ts so it stays warm. */
export interface GithubReleasesCache {
  releases: StableRelease[] | null;
  fetchedAtMs: number;
  lastLatestMajor: string | null;
}

/** A fresh, empty cache. */
export function emptyGithubCache(): GithubReleasesCache {
  return { releases: null, fetchedAtMs: 0, lastLatestMajor: null };
}

/** Injected dependencies for the GitHub releases adapter. */
export interface GithubDeps {
  fetch: typeof globalThis.fetch;
  now: () => number; // ms since epoch
  releasesUrl: string; // full GET URL for the repo's releases
  headers: Record<string, string>; // User-Agent (required by GitHub) + optional auth
  cache: GithubReleasesCache;
  cacheTtlMs: number;
  log: (message: string) => void;
}

/** A GitHub release object, narrowed to the fields this adapter reads. */
interface GithubReleaseJSON {
  tag_name?: unknown;
  draft?: unknown;
  prerelease?: unknown;
  published_at?: unknown;
}

/** Builds the releases adapter over the injected seams. */
export function githubReleases(deps: GithubDeps) {
  async function stableReleases(): Promise<StableRelease[]> {
    const fresh = deps.cache.releases !== null &&
      deps.now() - deps.cache.fetchedAtMs < deps.cacheTtlMs;
    if (fresh) return deps.cache.releases ?? [];

    const fetched = await fetchStableReleases(deps);
    if (fetched === null) {
      // Failure: serve a prior good snapshot if we have one, else empty. Do NOT
      // touch fetchedAtMs, so the next check-in re-attempts the fetch.
      return deps.cache.releases ?? [];
    }
    deps.cache.releases = fetched;
    deps.cache.fetchedAtMs = deps.now();
    return fetched;
  }

  async function currentLatestMajor(): Promise<string | null> {
    const releases = await stableReleases();
    if (releases.length === 0) return null;
    const max = releases.reduce(
      (m, r) => (r.major > m ? r.major : m),
      releases[0].major,
    );
    const latest = `v${max}`;
    if (latest !== deps.cache.lastLatestMajor) {
      deps.log(
        `github: computed latest stable major changed ${
          deps.cache.lastLatestMajor ?? "∅"
        } -> ${latest}`,
      );
      deps.cache.lastLatestMajor = latest;
    }
    return latest;
  }

  return { stableReleases, currentLatestMajor };
}

/** Fetches + parses stable releases; returns null on ANY failure (never throws). */
async function fetchStableReleases(
  deps: GithubDeps,
): Promise<StableRelease[] | null> {
  try {
    const response = await deps.fetch(deps.releasesUrl, {
      headers: deps.headers,
    });
    if (!response.ok) {
      deps.log(`github: releases fetch returned ${response.status}`);
      return null;
    }
    const json = await response.json();
    if (!Array.isArray(json)) return null;
    const out: StableRelease[] = [];
    for (const raw of json as GithubReleaseJSON[]) {
      if (raw.draft === true || raw.prerelease === true) continue;
      const tag = typeof raw.tag_name === "string" ? raw.tag_name : "";
      const major = parseMajor(tag);
      if (major === null) continue;
      out.push({
        major,
        tag,
        publishedAt: typeof raw.published_at === "string"
          ? raw.published_at
          : "",
      });
    }
    return out;
  } catch (_error) {
    deps.log("github: releases fetch failed (network/parse)");
    return null;
  }
}

/** Parses the SemVer major from a tag like `v1.2.3`, `1.2.3`, or `v1`; null if none. */
export function parseMajor(tag: string): number | null {
  const match = /^v?(\d+)(?:[.\-+]|$)/.exec(tag.trim());
  if (!match) return null;
  const major = Number(match[1]);
  return Number.isFinite(major) ? major : null;
}
