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

export function getComparisons() {
  return getJson("/comparisons?limit=20");
}
