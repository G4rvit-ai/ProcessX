import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "vite";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";

let server;
let components;
test("load dashboard components through Vite for server-side rendering", async () => {
  server = await createServer({
    configFile: "./vite.config.js",
    optimizeDeps: { noDiscovery: true, include: [] },
    server: { middlewareMode: true },
  });
  components = await server.ssrLoadModule("/src/components.jsx");
});

test("status strip includes backend state and refresh action", () => {
  const html = renderToStaticMarkup(React.createElement(components.StatusStrip, {
    health: { strace: true, baselines: 4 },
    checkedAt: "2026-11-12T12:00:00Z",
    onRefresh: () => {},
    refreshing: false,
  }));
  assert.match(html, /Running/);
  assert.match(html, /Installed/);
  assert.match(html, /Baselines/);
  assert.match(html, /Refresh/);
});

test("history renders the newest rows, counts and score labels accessibly", () => {
  const html = renderToStaticMarkup(React.createElement(components.HistoryTable, {
    total: 37,
    comparisons: [{
      id: 8,
      created_at: "2026-11-12T12:00:00+00:00",
      baseline: "demo",
      score: 8,
      level: "slightly unusual",
      outside_range: 2,
      features_compared: 40,
    }],
  }));
  assert.match(html, /37 comparisons saved/);
  assert.match(html, /newest 20/);
  assert.match(html, /2 of 40 features/);
  assert.match(html, /slightly unusual/);
  assert.match(html, /tabindex="0"/);
});

test("empty history displays the documented curl command", () => {
  const html = renderToStaticMarkup(React.createElement(components.HistoryTable, {
    total: 0,
    comparisons: [],
  }));
  assert.match(html, /No comparisons saved yet/);
  assert.match(html, /curl -X POST http:\/\/127\.0\.0\.1:8000\/baselines\/demo\/compare/);
});

test.after(async () => {
  if (server) await server.close();
});
