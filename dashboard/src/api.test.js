import test from "node:test";
import assert from "node:assert/strict";
import { getBaseline, getBaselines, getComparisons, getHealth } from "./api.js";

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
  await getComparisons({ baseline: "demo", minScore: 15, limit: 10, offset: 20 });
  assert.deepEqual(requested, [
    "/api/baselines",
    "/api/baselines/demo%2Ftest",
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
