import React, { useCallback, useEffect, useState } from "react";
import { getComparisons, getHealth } from "./api.js";
import { HistoryTable, LatestComparison, StatusStrip } from "./components.jsx";

function BackendHelp({ error }) {
  return (
    <div className="notice notice-error">
      <h2>Backend not reachable</h2>
      {error && <p>{error}</p>}
      <p>Start the backend in a terminal from the project folder:</p>
      <pre><code>cd ~/processx{"\n"}source venv/bin/activate{"\n"}uvicorn backend.main:app --reload</code></pre>
    </div>
  );
}

function App() {
  const [health, setHealth] = useState(null);
  const [history, setHistory] = useState(null);
  const [healthError, setHealthError] = useState(null);
  const [historyError, setHistoryError] = useState(null);
  const [checkedAt, setCheckedAt] = useState(null);
  const [refreshing, setRefreshing] = useState(false);

  const refresh = useCallback(async () => {
    setRefreshing(true);
    const [healthResult, historyResult] = await Promise.allSettled([getHealth(), getComparisons()]);
    if (healthResult.status === "fulfilled") {
      setHealth(healthResult.value);
      setHealthError(null);
    } else {
      setHealth(null);
      setHealthError(healthResult.reason instanceof Error ? healthResult.reason.message : "The backend could not be reached.");
    }
    if (historyResult.status === "fulfilled") {
      setHistory(historyResult.value);
      setHistoryError(null);
    } else {
      setHistory(null);
      setHistoryError(historyResult.reason instanceof Error ? historyResult.reason.message : "The comparison history could not be read.");
    }
    setCheckedAt(new Date().toISOString());
    setRefreshing(false);
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const latest = history?.comparisons?.[0] ?? null;
  return (
    <main className="page-shell">
      <header className="topbar">
        <a className="brand" href="/" aria-label="ProcessX dashboard home">
          <span className="brand-mark" aria-hidden="true">PX</span>
          <span>Process<span className="brand-x">X</span></span>
        </a>
        <span className="topbar-note">System call behavior, made visible</span>
      </header>

      <div className="content">
        <section className="intro">
          <p className="eyebrow">Local analysis dashboard</p>
          <h1>Know what changed.</h1>
          <p>Compare a program’s latest system-call behavior with its saved baseline.</p>
        </section>

        <StatusStrip health={health} checkedAt={checkedAt} onRefresh={refresh} refreshing={refreshing} />

        {!health && <BackendHelp error={healthError} />}
        {health && !health.strace && (
          <div className="notice notice-warning" role="status">
            <h2>strace is not installed</h2>
            <p>The backend is running, but it cannot collect new system-call traces until strace is installed.</p>
          </div>
        )}

        <LatestComparison comparison={latest} />

        {historyError && health ? (
          <div className="notice notice-error" role="alert">
            <h2>History could not be read</h2>
            <p>{historyError}</p>
            <p>Check the backend terminal for the database error, then refresh.</p>
          </div>
        ) : history ? (
          <HistoryTable comparisons={history.comparisons ?? []} total={history.total ?? 0} />
        ) : null}

        <aside className="safety-note">
          <span className="safety-icon" aria-hidden="true">i</span>
          <p>A high score means this run was different from the baseline. It does not mean the program is harmful.</p>
        </aside>
      </div>
      <footer className="footer">ProcessX <span>·</span> Local-first, explainable system-call analysis</footer>
    </main>
  );
}

export default App;
