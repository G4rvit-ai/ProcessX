import React from "react";
import { formatClock, formatLevel, formatTime, levelClass, scorePosition } from "./format.js";

export function StatusStrip({ health, checkedAt, onRefresh, refreshing }) {
  const reachable = health !== null;
  return (
    <section className="status-strip" aria-label="System status">
      <div className="status-item">
        <span className={`status-dot ${reachable ? "is-up" : "is-down"}`} aria-hidden="true" />
        <span className="status-label">Backend</span>
        <strong>{reachable ? "Running" : "Not reachable"}</strong>
      </div>
      <div className="status-item">
        <span className="status-label">strace</span>
        <strong>{reachable ? (health.strace ? "Installed" : "Not installed") : "Unknown"}</strong>
      </div>
      <div className="status-item">
        <span className="status-label">Baselines</span>
        <strong>{reachable ? health.baselines : "—"}</strong>
      </div>
      <div className="status-checked">
        <span>Checked at {formatClock(checkedAt)}</span>
        <button className="button button-small" type="button" onClick={onRefresh} disabled={refreshing}>
          {refreshing ? "Refreshing…" : "Refresh"}
        </button>
      </div>
    </section>
  );
}

export function ScoreRuler({ score, level, compact = false }) {
  const safeScore = Math.max(0, Math.min(100, Number(score) || 0));
  const position = scorePosition(safeScore);
  return (
    <div className={`score-ruler${compact ? " score-ruler-compact" : ""}`}>
      <div
        className="ruler-track"
        role="img"
        aria-label={`Score ${safeScore} of 100, ${formatLevel(level)}`}
      >
        <span className="ruler-band band-normal" />
        <span className="ruler-band band-slight" />
        <span className="ruler-band band-unusual" />
        <span className="ruler-band band-very" />
        <span
          className="ruler-marker"
          style={{ left: `${position}%` }}
          data-enter={!compact ? "true" : undefined}
        />
      </div>
      <div className="ruler-labels" aria-hidden="true">
        {["normal", "slightly unusual", "unusual", "very unusual"].map((name) => (
          <span key={name} className={name === formatLevel(level) ? "ruler-label is-current" : "ruler-label"}>
            {name}
          </span>
        ))}
      </div>
      {!compact && (
        <div className="ruler-scale" aria-hidden="true">
          <span>0</span><span>3</span><span>10</span><span>25</span><span>100</span>
        </div>
      )}
    </div>
  );
}

export function LatestComparison({ comparison }) {
  if (!comparison) return null;
  return (
    <section className="latest-card" aria-labelledby="latest-title">
      <div className="latest-heading">
        <div>
          <p className="eyebrow">Most recent saved run</p>
          <h2 id="latest-title">{comparison.baseline}</h2>
        </div>
        <time dateTime={comparison.created_at}>{formatTime(comparison.created_at)}</time>
      </div>
      <div className="latest-score">
        <strong className={`score-number ${levelClass(comparison.level)}`}>{comparison.score}</strong>
        <div>
          <span className="score-out-of">out of 100</span>
          <span className={`level-pill ${levelClass(comparison.level)}`}>{formatLevel(comparison.level)}</span>
        </div>
      </div>
      <ScoreRuler score={comparison.score} level={comparison.level} />
    </section>
  );
}

export function BaselinesPanel({ baselines, error, selectedName, detail, detailError, detailLoading, onSelect }) {
  return (
    <section className="baselines-section" aria-labelledby="baselines-title">
      <div className="section-heading">
        <div>
          <p className="eyebrow">Saved behavior profiles</p>
          <h2 id="baselines-title">Baselines</h2>
        </div>
        {baselines && <p className="history-count">{baselines.count} usable</p>}
      </div>
      {error ? (
        <p className="panel-message panel-error" role="alert">{error}</p>
      ) : !baselines ? (
        <p className="panel-message">Loading baselines…</p>
      ) : baselines.baselines.length === 0 ? (
        <p className="panel-message">No usable baselines found. Build one with <code>src/baseline.py build</code>.</p>
      ) : (
        <div className="baseline-grid">
          {baselines.baselines.map((baseline) => (
            <article className={`baseline-card${selectedName === baseline.name ? " is-selected" : ""}`} key={baseline.name}>
              <div className="baseline-card-heading">
                <div>
                  <h3>{baseline.name}</h3>
                  <p>{baseline.program}</p>
                </div>
                <button
                  type="button"
                  className="button button-small"
                  aria-expanded={selectedName === baseline.name}
                  onClick={() => onSelect(selectedName === baseline.name ? null : baseline.name)}
                >
                  {selectedName === baseline.name ? "Hide ranges" : "Feature ranges"}
                </button>
              </div>
              <dl className="baseline-meta">
                <div><dt>Normal runs</dt><dd>{baseline.runs}</dd></div>
                <div><dt>Features</dt><dd>{baseline.feature_count}</dd></div>
                <div><dt>Command</dt><dd><code>{(baseline.command ?? []).join(" ") || "Unavailable"}</code></dd></div>
              </dl>
              {selectedName === baseline.name && (
                <div className="feature-ranges">
                  {detailLoading ? <p>Loading feature ranges…</p> : detailError ? (
                    <p className="panel-error" role="alert">{detailError}</p>
                  ) : detail ? (
                    <>
                      <h4>Normal range for each feature</h4>
                      <div className="range-scroll" tabIndex="0" aria-label={`${baseline.name} feature ranges`}>
                        <table>
                          <thead><tr><th scope="col">Feature</th><th scope="col">Minimum</th><th scope="col">Maximum</th><th scope="col">Runs present</th></tr></thead>
                          <tbody>
                            {Object.entries(detail.features ?? {}).map(([feature, range]) => (
                              <tr key={feature}>
                                <td className="mono">{feature}</td>
                                <td>{range.min ?? "—"}</td>
                                <td>{range.max ?? "—"}</td>
                                <td>{range.present ?? "—"} of {detail.runs}</td>
                              </tr>
                            ))}
                          </tbody>
                        </table>
                      </div>
                    </>
                  ) : null}
                </div>
              )}
            </article>
          ))}
        </div>
      )}
      {baselines?.unreadable?.length > 0 && (
        <details className="unreadable-baselines">
          <summary>{baselines.unreadable.length} unusable {baselines.unreadable.length === 1 ? "baseline file" : "baseline files"}</summary>
          <ul>{baselines.unreadable.map((item) => <li key={item.name}><strong>{item.name}</strong>: {item.problem}</li>)}</ul>
        </details>
      )}
    </section>
  );
}

export function HistoryFilters({ baselines, values, onChange, onSubmit, onReset, disabled }) {
  return (
    <form className="history-filters" onSubmit={onSubmit}>
      <label>
        <span>Baseline</span>
        <select value={values.baseline} onChange={(event) => onChange("baseline", event.target.value)}>
          <option value="">All baselines</option>
          {(baselines ?? []).map((baseline) => <option value={baseline.name} key={baseline.name}>{baseline.name}</option>)}
        </select>
      </label>
      <label>
        <span>Minimum score</span>
        <input
          type="number"
          min="0"
          max="100"
          step="1"
          inputMode="numeric"
          placeholder="0–100"
          value={values.minScore}
          onChange={(event) => onChange("minScore", event.target.value)}
        />
      </label>
      <label>
        <span>Rows per page</span>
        <select value={values.limit} onChange={(event) => onChange("limit", Number(event.target.value))}>
          {[10, 20, 50].map((size) => <option key={size} value={size}>{size}</option>)}
        </select>
      </label>
      <div className="filter-actions">
        <button className="button button-primary" type="submit" disabled={disabled}>Apply filters</button>
        <button className="button" type="button" onClick={onReset} disabled={disabled}>Clear</button>
      </div>
    </form>
  );
}

export function HistoryTable({ comparisons, total, offset, limit, loading, onPage }) {
  const first = total === 0 ? 0 : offset + 1;
  const last = Math.min(offset + comparisons.length, total);
  return (
    <section className="history-section" aria-labelledby="history-title">
      <div className="section-heading">
        <div>
          <p className="eyebrow">Saved runs</p>
          <h2 id="history-title">Comparison history</h2>
        </div>
        <p className="history-count">{loading ? "Loading comparisons…" : `Showing ${first}-${last} of ${total} matching comparisons`}</p>
      </div>
      {loading ? <p className="panel-message">Loading saved comparison history…</p> : comparisons.length === 0 ? (
        <div className="empty-state">
          {total === 0 ? (
            <>
              <h3>No matching comparisons</h3>
              <p>Try clearing a filter, or run a comparison from another terminal:</p>
              <code>curl -X POST http://127.0.0.1:8000/baselines/demo/compare</code>
            </>
          ) : <h3>No comparisons on this page</h3>}
        </div>
      ) : (
        <div className="table-scroll" tabIndex="0" aria-label="Scrollable comparison history">
          <table>
            <thead>
              <tr>
                <th scope="col">ID</th>
                <th scope="col">When</th>
                <th scope="col">Baseline</th>
                <th scope="col">Score</th>
                <th scope="col">Level</th>
                <th scope="col">Features outside range</th>
              </tr>
            </thead>
            <tbody>
              {comparisons.map((item) => (
                <tr key={item.id}>
                  <td className="mono">#{item.id}</td>
                  <td><time dateTime={item.created_at}>{formatTime(item.created_at)}</time></td>
                  <td className="baseline-cell">{item.baseline}</td>
                  <td>
                    <div className="table-score">
                      <strong>{item.score}</strong>
                      <ScoreRuler score={item.score} level={item.level} compact />
                    </div>
                  </td>
                  <td><span className={`level-pill ${levelClass(item.level)}`}>{formatLevel(item.level)}</span></td>
                  <td>{item.outside_range} of {item.features_compared} features</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {!loading && total > 0 && (
        <nav className="pagination" aria-label="Comparison history pages">
          <button type="button" className="button" onClick={() => onPage(Math.max(0, offset - limit))} disabled={offset === 0}>Previous</button>
          <span>Page {Math.floor(offset / limit) + 1} of {Math.max(1, Math.ceil(total / limit))}</span>
          <button type="button" className="button" onClick={() => onPage(offset + limit)} disabled={offset + limit >= total}>Next</button>
        </nav>
      )}
    </section>
  );
}
