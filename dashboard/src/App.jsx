import React, { useCallback, useEffect, useState } from "react";
import { getBaseline, getBaselines, getComparison, getComparisons, getHealth, runComparison } from "./api.js";
import { BaselinesPanel, ComparisonDetails, HistoryFilters, HistoryTable, LatestComparison, StatusStrip } from "./components.jsx";

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
  const [baselines, setBaselines] = useState(null);
  const [healthError, setHealthError] = useState(null);
  const [historyError, setHistoryError] = useState(null);
  const [baselinesError, setBaselinesError] = useState(null);
  const [checkedAt, setCheckedAt] = useState(null);
  const [refreshing, setRefreshing] = useState(false);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [filters, setFilters] = useState({ baseline: "", minScore: "", limit: 20 });
  const [appliedFilters, setAppliedFilters] = useState({ baseline: "", minScore: "", limit: 20 });
  const [offset, setOffset] = useState(0);
  const [latest, setLatest] = useState(null);
  const [selectedBaseline, setSelectedBaseline] = useState(null);
  const [baselineDetail, setBaselineDetail] = useState(null);
  const [baselineDetailError, setBaselineDetailError] = useState(null);
  const [loadingBaselineDetail, setLoadingBaselineDetail] = useState(false);
  const [selectedComparisonId, setSelectedComparisonId] = useState(null);
  const [comparisonDetail, setComparisonDetail] = useState(null);
  const [comparisonDetailError, setComparisonDetailError] = useState(null);
  const [loadingComparisonDetail, setLoadingComparisonDetail] = useState(false);
  const [runningBaseline, setRunningBaseline] = useState(null);
  const [runFeedback, setRunFeedback] = useState(null);

  const refreshStatus = useCallback(async () => {
    setRefreshing(true);
    const [healthResult, baselinesResult, latestResult] = await Promise.allSettled([
      getHealth(),
      getBaselines(),
      getComparisons({ limit: 1 }),
    ]);
    if (healthResult.status === "fulfilled") {
      setHealth(healthResult.value);
      setHealthError(null);
    } else {
      setHealth(null);
      setHealthError(healthResult.reason instanceof Error ? healthResult.reason.message : "The backend could not be reached.");
    }
    if (baselinesResult.status === "fulfilled") {
      setBaselines(baselinesResult.value);
      setBaselinesError(null);
    } else {
      setBaselines(null);
      setBaselinesError(baselinesResult.reason instanceof Error ? baselinesResult.reason.message : "Baselines could not be read.");
    }
    setLatest(latestResult.status === "fulfilled" ? latestResult.value.comparisons?.[0] ?? null : null);
    setCheckedAt(new Date().toISOString());
    setRefreshing(false);
  }, []);

  const refreshDashboard = useCallback(async () => {
    setLoadingHistory(true);
    await refreshStatus();
    try {
      const result = await getComparisons({ ...appliedFilters, offset });
      setHistory(result);
      setHistoryError(null);
    } catch (error) {
      setHistory(null);
      setHistoryError(error instanceof Error ? error.message : "The comparison history could not be read.");
    } finally {
      setLoadingHistory(false);
    }
  }, [appliedFilters, offset, refreshStatus]);

  useEffect(() => {
    refreshStatus();
  }, [refreshStatus]);

  useEffect(() => {
    let active = true;
    setLoadingHistory(true);
    getComparisons({ ...appliedFilters, offset }).then((result) => {
      if (!active) return;
      setHistory(result);
      setHistoryError(null);
    }).catch((error) => {
      if (!active) return;
      setHistory(null);
      setHistoryError(error instanceof Error ? error.message : "The comparison history could not be read.");
    }).finally(() => {
      if (active) setLoadingHistory(false);
    });
    return () => { active = false; };
  }, [appliedFilters, offset]);

  useEffect(() => {
    if (!selectedBaseline) {
      setBaselineDetail(null);
      setBaselineDetailError(null);
      setLoadingBaselineDetail(false);
      return;
    }
    let active = true;
    setBaselineDetail(null);
    setBaselineDetailError(null);
    setLoadingBaselineDetail(true);
    getBaseline(selectedBaseline).then((detail) => {
      if (active) setBaselineDetail(detail);
    }).catch((error) => {
      if (active) setBaselineDetailError(error instanceof Error ? error.message : "This baseline could not be loaded.");
    }).finally(() => {
      if (active) setLoadingBaselineDetail(false);
    });
    return () => { active = false; };
  }, [selectedBaseline]);

  useEffect(() => {
    if (selectedComparisonId === null) {
      setComparisonDetail(null);
      setComparisonDetailError(null);
      setLoadingComparisonDetail(false);
      return;
    }
    let active = true;
    setComparisonDetail(null);
    setComparisonDetailError(null);
    setLoadingComparisonDetail(true);
    getComparison(selectedComparisonId).then((detail) => {
      if (active) setComparisonDetail(detail);
    }).catch((error) => {
      if (active) setComparisonDetailError(error instanceof Error ? error.message : "This comparison could not be loaded.");
    }).finally(() => {
      if (active) setLoadingComparisonDetail(false);
    });
    return () => { active = false; };
  }, [selectedComparisonId]);

  function setFilter(name, value) {
    setFilters((current) => ({ ...current, [name]: value }));
  }

  function applyFilters(event) {
    event.preventDefault();
    const minScore = filters.minScore === "" ? "" : Math.max(0, Math.min(100, Number(filters.minScore)));
    setFilters((current) => ({ ...current, minScore }));
    setAppliedFilters({ ...filters, minScore });
    setOffset(0);
  }

  function clearFilters() {
    const empty = { baseline: "", minScore: "", limit: 20 };
    setFilters(empty);
    setAppliedFilters(empty);
    setOffset(0);
  }

  async function handleRunComparison(name) {
    if (runningBaseline) return;
    setRunningBaseline(name);
    setRunFeedback({ type: "progress", baseline: name, message: "Tracing and comparing the saved command. This can take a few seconds…" });
    try {
      const result = await runComparison(name);
      if (result.id === null) {
        setRunFeedback({
          type: "warning",
          baseline: name,
          message: result.warnings?.join(" ") || "The comparison finished, but it could not be saved to history.",
        });
      } else {
        setRunFeedback({ type: "success", baseline: name, message: `Comparison saved as #${result.id}. Opening its details…` });
      }
      await refreshDashboard();
      if (result.id !== null) setSelectedComparisonId(result.id);
    } catch (error) {
      const detail = error instanceof Error ? error.message : "The comparison request failed.";
      let message = detail;
      if (error?.status === 409) message = "Another comparison is already running. Wait for it to finish, then try again.";
      else if (error?.status === 403) message = `The backend refused this page-origin request. Open the dashboard through the local address and SSH tunnel, then retry. ${detail}`;
      else if (error?.status === 404) message = `This baseline is no longer available. Refresh the dashboard and try again. ${detail}`;
      else if (error?.status === 503) message = `The comparison cannot run because strace is unavailable or the service is unavailable. ${detail}`;
      else if (error?.status >= 500) message = `The backend could not complete this comparison. Check its terminal for details. ${detail}`;
      setRunFeedback({ type: "error", baseline: name, message });
    } finally {
      setRunningBaseline(null);
    }
  }

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

        <StatusStrip health={health} checkedAt={checkedAt} onRefresh={refreshDashboard} refreshing={refreshing} />

        {!health && <BackendHelp error={healthError} />}
        {health && !health.strace && (
          <div className="notice notice-warning" role="status">
            <h2>strace is not installed</h2>
            <p>The backend is running, but it cannot collect new system-call traces until strace is installed.</p>
          </div>
        )}

        <LatestComparison comparison={latest} />

        <BaselinesPanel
          baselines={baselines}
          error={baselinesError ?? (!health ? healthError : null)}
          selectedName={selectedBaseline}
          detail={baselineDetail}
          detailError={baselineDetailError}
          detailLoading={loadingBaselineDetail}
          onSelect={setSelectedBaseline}
          onRun={handleRunComparison}
          runningBaseline={runningBaseline}
          runFeedback={runFeedback}
        />

        <HistoryFilters
          baselines={baselines?.baselines}
          values={filters}
          onChange={setFilter}
          onSubmit={applyFilters}
          onReset={clearFilters}
          disabled={loadingHistory}
        />

        {historyError ? (health && (
          <div className="notice notice-error" role="alert">
            <h2>History could not be read</h2>
            <p>{historyError}</p>
            <p>Check the backend terminal for the database error, then refresh.</p>
          </div>
        )) : (
          <HistoryTable
            comparisons={history?.comparisons ?? []}
            total={history?.total ?? 0}
            offset={offset}
            limit={appliedFilters.limit}
            loading={loadingHistory}
            onPage={setOffset}
            selectedId={selectedComparisonId}
            onSelect={setSelectedComparisonId}
          />
        )}

        <ComparisonDetails
          comparison={comparisonDetail}
          loading={loadingComparisonDetail}
          error={comparisonDetailError}
          onClose={() => setSelectedComparisonId(null)}
        />

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
