import test from "node:test";
import assert from "node:assert/strict";
import { getBaseline, getBaselines, getComparison, getComparisons, getHealth, runComparison } from "./api.js";

test("requests health and the newest 20 comparisons through the proxy", async (t) => {
  const originalFetch = globalThis.fetch;
  const requested = [];
  globalThis.fetch = async (path, options) => {
    requested.push([path, options.headers.Accept]);
    return { ok: true, json: async () => ({ status: "ok" }) };
  };
  t.after(() => { globalThis.fetch = originalFetch; });

  await getHealth();
  await getComparisons({ limit: 20 });
  assert.deepEqual(requested, [
    ["/api/health", "application/json"],
    ["/api/comparisons?limit=20&offset=0", "application/json"],
  ]);
});

test("encodes baseline names and sends history filters and paging", async (t) => {
  const originalFetch = globalThis.fetch;
  const requested = [];
  globalThis.fetch = async (path) => {
    requested.push(path);
    return { ok: true, json: async () => ({}) };
  };
  t.after(() => { globalThis.fetch = originalFetch; });

  await getBaselines();
  await getBaseline("demo/test");
  await getComparison(42);
  await getComparisons({ baseline: "demo", minScore: 15, limit: 10, offset: 20 });
  assert.deepEqual(requested, [
    "/api/baselines",
    "/api/baselines/demo%2Ftest",
    "/api/comparisons/42",
    "/api/comparisons?limit=10&offset=20&baseline=demo&min_score=15",
  ]);
});

test("reports the backend detail for an unsuccessful response", async (t) => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({
    ok: false,
    status: 503,
    json: async () => ({ detail: "The database could not be read." }),
  });
  t.after(() => { globalThis.fetch = originalFetch; });
  await assert.rejects(getComparisons(), /The database could not be read/);
});

test("runs a comparison using POST and preserves API status on errors", async (t) => {
  const originalFetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (path, options) => {
    calls.push([path, options.method, options.headers.Accept]);
    return { ok: true, json: async () => ({ id: 12, score: 0 }) };
  };
  t.after(() => { globalThis.fetch = originalFetch; });
  assert.deepEqual(await runComparison("demo"), { id: 12, score: 0 });
  assert.deepEqual(calls, [["/api/baselines/demo/compare", "POST", "application/json"]]);
});

test("keeps the HTTP status available for action-specific error handling", async (t) => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({
    ok: false,
    status: 409,
    json: async () => ({ detail: "Another comparison is already running." }),
  });
  t.after(() => { globalThis.fetch = originalFetch; });
  await assert.rejects(runComparison("demo"), (error) => {
    assert.equal(error.status, 409);
    assert.match(error.message, /already running/);
    return true;
  });
});
