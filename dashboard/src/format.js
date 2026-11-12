const LEVELS = ["normal", "slightly unusual", "unusual", "very unusual"];

export function formatLevel(level) {
  return LEVELS.includes(level) ? level : "unknown";
}

export function formatTime(value) {
  if (!value) return "Time unavailable";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Time unavailable";
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

export function formatClock(value) {
  if (!value) return "--:--:--";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "--:--:--";
  return new Intl.DateTimeFormat(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(date);
}

export function scorePosition(score) {
  const safeScore = Math.max(0, Math.min(100, Number(score) || 0));
  if (safeScore <= 2) return 1.5 + (safeScore / 2) * 22;
  if (safeScore <= 9) return 26.5 + ((safeScore - 3) / 6) * 22;
  if (safeScore <= 24) return 51.5 + ((safeScore - 10) / 14) * 22;
  return 76.5 + ((safeScore - 25) / 75) * 22;
}

export function levelClass(level) {
  return `level-${formatLevel(level).replaceAll(" ", "-")}`;
}
