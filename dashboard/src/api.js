async function getJson(path) {
  const response = await fetch(`/api${path}`, {
    headers: { Accept: "application/json" },
  });
  if (!response.ok) {
    let message = `Request failed (${response.status})`;
    try {
      const body = await response.json();
      if (typeof body.detail === "string") message = body.detail;
    } catch (error) {
      if (!(error instanceof SyntaxError)) throw error;
      if (response.status === 500) message = "The backend could not be reached through the local dashboard proxy.";
    }
    throw new Error(message);
  }
  return response.json();
}

export function getHealth() {
  return getJson("/health");
}

export function getBaselines() {
  return getJson("/baselines");
}

export function getBaseline(name) {
  return getJson(`/baselines/${encodeURIComponent(name)}`);
}

export function getComparisons({ baseline = "", minScore = "", limit = 20, offset = 0 } = {}) {
  const query = new URLSearchParams({ limit: String(limit), offset: String(offset) });
  if (baseline) query.set("baseline", baseline);
  if (minScore !== "") query.set("min_score", String(minScore));
  return getJson(`/comparisons?${query}`);
}
