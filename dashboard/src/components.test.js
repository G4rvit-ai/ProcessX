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

test("analysis guide explains the tracing and scoring pipeline", () => {
  const html = renderToStaticMarkup(React.createElement(components.AnalysisGuide));
  assert.match(html, /From process to explanation/);
  assert.match(html, /strace records/);
  assert.match(html, /Behavior signals we inspect/);
  assert.match(html, /Internet sockets/);
  assert.match(html, /25\+ very unusual/);
});

test("overview shows saved comparison and signal metrics", () => {
  const html = renderToStaticMarkup(React.createElement(components.DashboardOverview, {
    health: { strace: true },
    baselines: { count: 2, baselines: [{ feature_count: 12 }, { feature_count: 8 }] },
    totalComparisons: 7,
    latest: { score: 18, level: "unusual" },
    recentComparisons: [
      { score: 18, level: "unusual", outside_range: 3 },
      { score: 0, level: "normal", outside_range: 0 },
    ],
  }));
  assert.match(html, /Your analysis at a glance/);
  assert.match(html, />7</);
  assert.match(html, /20 tracked features/);
  assert.match(html, /3<\/strong>/);
  assert.match(html, /Unusual/);
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
  assert.match(html, /data-label="When"/);
  assert.match(html, /data-label="Outside range"/);
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
    baselines: summary, selectedName: null, detail: null, onSelect: () => {}, onRun: () => {},
  }));
  assert.match(collapsed, /demo/);
  assert.match(collapsed, /10/);
  assert.match(collapsed, /1 unusable baseline file/);
  assert.match(collapsed, /Run comparison/);

  const expanded = renderToStaticMarkup(React.createElement(components.BaselinesPanel, {
    baselines: summary,
    selectedName: "demo",
    detail: { runs: 10, features: { "calls.total": { min: 20, max: 22, present: 10 } } },
    onSelect: () => {}, onRun: () => {},
  }));
  assert.match(expanded, /calls\.total/);
  assert.match(expanded, />20</);
  assert.match(expanded, />22</);
  assert.match(expanded, /10 of 10/);
});

test("baseline panel communicates active comparisons and errors", () => {
  const html = renderToStaticMarkup(React.createElement(components.BaselinesPanel, {
    baselines: {
      count: 1,
      baselines: [{ name: "demo", program: "demo.sh", command: ["demo.sh"], runs: 10, feature_count: 1 }],
      unreadable: [],
    },
    selectedName: null,
    detail: null,
    onSelect: () => {},
    onRun: () => {},
    runningBaseline: "other",
    runFeedback: { type: "error", baseline: "demo", message: "Another comparison is already running." },
  }));
  assert.match(html, /Busy/);
  assert.match(html, /role="alert"/);
  assert.match(html, /already running/);
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

test("comparison details render findings, differences, warning and close action", () => {
  const html = renderToStaticMarkup(React.createElement(components.ComparisonDetails, {
    comparison: {
      id: 8,
      baseline: "demo",
      score: 8,
      level: "slightly unusual",
      created_at: "2026-11-12T12:00:00+00:00",
      run: "compare-demo-2026-11-12",
      features_compared: 40,
      outside_range: 1,
      findings: [{ points: 2, text: "A new file was read." }],
      differences: [{
        kind: "never",
        feature: "files.read_files: /tmp/example",
        what: "read /tmp/example",
        value: 1,
        baseline_low: 0,
        baseline_high: 0,
      }],
      warnings: ["This baseline was built with different environment settings."],
    },
    loading: false,
    error: null,
    onClose: () => {},
  }));
  assert.match(html, /Run #8 · demo/);
  assert.match(html, /2 points/);
  assert.match(html, /A new file was read/);
  assert.match(html, /files\.read_files/);
  assert.match(html, /0–0/);
  assert.match(html, /Warnings/);
  assert.match(html, /different environment settings/);
  assert.match(html, /Close details/);
});

test("comparison detail displays loading and API error states", () => {
  const loadingHtml = renderToStaticMarkup(React.createElement(components.ComparisonDetails, {
    comparison: null, loading: true, error: null, onClose: () => {},
  }));
  const errorHtml = renderToStaticMarkup(React.createElement(components.ComparisonDetails, {
    comparison: null, loading: false, error: "No comparison with id 999.", onClose: () => {},
  }));
  assert.match(loadingHtml, /Loading comparison details/);
  assert.match(errorHtml, /No comparison with id 999/);
});

test.after(async () => {
  if (server) await server.close();
});
