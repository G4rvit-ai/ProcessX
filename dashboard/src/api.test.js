import test from "node:test";
import assert from "node:assert/strict";
import { getComparisons, getHealth } from "./api.js";

test("requests health and the newest 20 comparisons through the proxy", async (t) => {
  const originalFetch = globalThis.fetch;
  const requested = [];
  globalThis.fetch = async (path, options) => {
    requested.push([path, options.headers.Accept]);
    return { ok: true, json: async () => ({ status: "ok" }) };
  };
  t.after(() => { globalThis.fetch = originalFetch; });

  await getHealth();
  await getComparisons();
  assert.deepEqual(requested, [
    ["/api/health", "application/json"],
    ["/api/comparisons?limit=20", "application/json"],
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
