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

export function HistoryTable({ comparisons, total }) {
  return (
    <section className="history-section" aria-labelledby="history-title">
      <div className="section-heading">
        <div>
          <p className="eyebrow">Saved runs</p>
          <h2 id="history-title">Comparison history</h2>
        </div>
        <p className="history-count">
          {total} {total === 1 ? "comparison" : "comparisons"} saved. The table shows the newest {Math.min(total, 20)}.
        </p>
      </div>
      {comparisons.length === 0 ? (
        <div className="empty-state">
          <h3>No comparisons saved yet</h3>
          <p>Run a comparison from another terminal to create the first history entry:</p>
          <code>curl -X POST http://127.0.0.1:8000/baselines/demo/compare</code>
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
    </section>
  );
}
