// Hermetic tests for the GitHub releases adapter. Fully offline: `fetch`, the
// clock, and the cache are all injected. Covers draft/prerelease filtering, major
// parsing, the 5-minute cache, and the never-throw failure path (cached-or-null).

import {
  emptyGithubCache,
  type GithubDeps,
  githubReleases,
  parseMajor,
  type StableRelease,
} from "./github.ts";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}
function assertEquals(
  actual: unknown,
  expected: unknown,
  message?: string,
): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(message ?? `${a} !== ${e}`);
}

const TTL_MS = 5 * 60 * 1000;
const RELEASES_URL = "https://api.github.test/repos/stower/stower/releases";

interface FakeFetch {
  fetch: typeof globalThis.fetch;
  calls: number;
}

function fakeFetch(responder: () => Response | Promise<Response>): FakeFetch {
  const state = { calls: 0 };
  const fetch = ((_url: string | URL | Request, _init?: RequestInit) => {
    state.calls++;
    return Promise.resolve(responder());
  }) as unknown as typeof globalThis.fetch;
  return Object.assign(state, { fetch });
}

function jsonReleases(
  items: Array<
    { tag: string; draft?: boolean; prerelease?: boolean; published?: string }
  >,
): Response {
  const body = items.map((i) => ({
    tag_name: i.tag,
    draft: i.draft ?? false,
    prerelease: i.prerelease ?? false,
    published_at: i.published ?? "2026-01-01T00:00:00Z",
  }));
  return new Response(JSON.stringify(body), { status: 200 });
}

function deps(overrides: Partial<GithubDeps>): GithubDeps {
  return {
    fetch: (() =>
      Promise.resolve(
        new Response("[]"),
      )) as unknown as typeof globalThis.fetch,
    now: () => 1_000_000,
    releasesUrl: RELEASES_URL,
    headers: { "User-Agent": "stower-test" },
    cache: emptyGithubCache(),
    cacheTtlMs: TTL_MS,
    log: () => {},
    ...overrides,
  };
}

Deno.test("stableReleases drops drafts + prereleases and parses majors", async () => {
  const ff = fakeFetch(() =>
    jsonReleases([
      { tag: "v2.1.0" },
      { tag: "v3.0.0-rc.1", prerelease: true },
      { tag: "v1.0.0", draft: true },
      { tag: "v0.9.0" },
      { tag: "not-a-version" },
    ])
  );
  const gh = githubReleases(deps({ fetch: ff.fetch }));
  const releases = await gh.stableReleases();
  const majors = releases.map((r: StableRelease) => r.major).sort();
  assertEquals(majors, [0, 2], "only stable v0 + v2 survive");
});

Deno.test("currentLatestMajor returns the highest stable major as vN", async () => {
  const ff = fakeFetch(() =>
    jsonReleases([{ tag: "v0.9.0" }, { tag: "v2.1.0" }, { tag: "v1.5.0" }])
  );
  const gh = githubReleases(deps({ fetch: ff.fetch }));
  assertEquals(await gh.currentLatestMajor(), "v2");
});

Deno.test("a fresh result is cached — no second fetch within the TTL", async () => {
  const ff = fakeFetch(() => jsonReleases([{ tag: "v1.0.0" }]));
  const shared = deps({ fetch: ff.fetch });
  const gh = githubReleases(shared);
  await gh.stableReleases();
  await gh.stableReleases();
  assertEquals(ff.calls, 1, "second call must hit the cache");
});

Deno.test("the cache expires after the TTL and refetches", async () => {
  const ff = fakeFetch(() => jsonReleases([{ tag: "v1.0.0" }]));
  let nowMs = 1_000_000;
  const shared = deps({ fetch: ff.fetch, now: () => nowMs });
  const gh = githubReleases(shared);
  await gh.stableReleases();
  nowMs += TTL_MS + 1;
  await gh.stableReleases();
  assertEquals(ff.calls, 2, "an expired cache must refetch");
});

Deno.test("a fetch failure returns null latest-major, never throws", async () => {
  const ff = fakeFetch(() => new Response("boom", { status: 500 }));
  const gh = githubReleases(deps({ fetch: ff.fetch }));
  assertEquals(
    await gh.currentLatestMajor(),
    null,
    "no cache + failure => null",
  );
  assertEquals(await gh.stableReleases(), [], "no cache + failure => empty");
});

Deno.test("a fetch throw returns the prior cached snapshot", async () => {
  let fail = false;
  const ff = fakeFetch(() => {
    if (fail) throw new Error("network down");
    return jsonReleases([{ tag: "v4.0.0" }]);
  });
  let nowMs = 1_000_000;
  const gh = githubReleases(deps({ fetch: ff.fetch, now: () => nowMs }));
  assertEquals(
    await gh.currentLatestMajor(),
    "v4",
    "first call populates the cache",
  );
  fail = true;
  nowMs += TTL_MS + 1; // force a refetch attempt, which now throws
  assertEquals(
    await gh.currentLatestMajor(),
    "v4",
    "failure falls back to the cached snapshot",
  );
});

Deno.test("a computed latest-major change is logged loudly", async () => {
  const logs: string[] = [];
  let tag = "v1.0.0";
  const ff = fakeFetch(() => jsonReleases([{ tag }]));
  let nowMs = 1_000_000;
  const gh = githubReleases(
    deps({ fetch: ff.fetch, now: () => nowMs, log: (m) => logs.push(m) }),
  );
  await gh.currentLatestMajor();
  tag = "v2.0.0";
  nowMs += TTL_MS + 1;
  await gh.currentLatestMajor();
  assert(
    logs.some((l) => l.includes("v1") && l.includes("v2")),
    "the major change must be logged",
  );
});

Deno.test("parseMajor handles v-prefixed, bare, and major-only tags", () => {
  assertEquals(parseMajor("v1.2.3"), 1);
  assertEquals(parseMajor("2.0.0"), 2);
  assertEquals(parseMajor("v0"), 0);
  assertEquals(parseMajor("nightly"), null);
  assertEquals(parseMajor(""), null);
});
