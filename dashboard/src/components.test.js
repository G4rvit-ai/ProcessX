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
    offset: 0,
    limit: 20,
    loading: false,
    onPage: () => {},
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
  assert.match(html, /Showing 1-1 of 37 matching comparisons/);
  assert.match(html, /2 of 40 features/);
  assert.match(html, /slightly unusual/);
  assert.match(html, /tabindex="0"/);
});

test("empty history displays the documented curl command", () => {
  const html = renderToStaticMarkup(React.createElement(components.HistoryTable, {
    total: 0,
    offset: 0,
    limit: 20,
    loading: false,
    onPage: () => {},
    comparisons: [],
  }));
  assert.match(html, /No matching comparisons/);
  assert.match(html, /curl -X POST http:\/\/127\.0\.0\.1:8000\/baselines\/demo\/compare/);
});

test("baseline panel shows summaries and normal feature ranges", () => {
  const summary = {
    count: 1,
    baselines: [{ name: "demo", program: "demo.sh", command: ["demo.sh"], runs: 10, feature_count: 1 }],
    unreadable: [{ name: "broken", problem: "invalid JSON" }],
  };
  const collapsed = renderToStaticMarkup(React.createElement(components.BaselinesPanel, {
    baselines: summary, selectedName: null, detail: null, onSelect: () => {},
  }));
  assert.match(collapsed, /demo/);
  assert.match(collapsed, /10/);
  assert.match(collapsed, /1 unusable baseline file/);

  const expanded = renderToStaticMarkup(React.createElement(components.BaselinesPanel, {
    baselines: summary,
    selectedName: "demo",
    detail: { runs: 10, features: { "calls.total": { min: 20, max: 22, present: 10 } } },
    onSelect: () => {},
  }));
  assert.match(expanded, /calls\.total/);
  assert.match(expanded, />20</);
  assert.match(expanded, />22</);
  assert.match(expanded, /10 of 10/);
});

test("history filters expose baseline, score and page-size controls", () => {
  const html = renderToStaticMarkup(React.createElement(components.HistoryFilters, {
    baselines: [{ name: "demo" }],
    values: { baseline: "", minScore: "", limit: 20 },
    onChange: () => {},
    onSubmit: () => {},
    onReset: () => {},
    disabled: false,
  }));
  assert.match(html, /Baseline/);
  assert.match(html, /Minimum score/);
  assert.match(html, /Rows per page/);
  assert.match(html, /Apply filters/);
});

test.after(async () => {
  if (server) await server.close();
});
