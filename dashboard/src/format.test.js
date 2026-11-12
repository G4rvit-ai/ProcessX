import test from "node:test";
import assert from "node:assert/strict";
import { formatClock, formatLevel, formatTime, levelClass, scorePosition } from "./format.js";

test("formats the supported score levels and safely labels unknown levels", () => {
  assert.equal(formatLevel("slightly unusual"), "slightly unusual");
  assert.equal(formatLevel("unexpected"), "unknown");
  assert.equal(levelClass("very unusual"), "level-very-unusual");
});

test("formats valid times and handles missing or invalid values", () => {
  assert.notEqual(formatTime("2026-11-12T12:00:00+00:00"), "Time unavailable");
  assert.equal(formatTime("not a date"), "Time unavailable");
  assert.equal(formatClock(null), "--:--:--");
});

test("places every score inside the matching equal-width band", () => {
  assert.ok(scorePosition(0) > 0 && scorePosition(2) < 25);
  assert.ok(scorePosition(3) > 25 && scorePosition(9) < 50);
  assert.ok(scorePosition(10) > 50 && scorePosition(24) < 75);
  assert.ok(scorePosition(25) > 75 && scorePosition(100) < 100);
  assert.equal(scorePosition(200), scorePosition(100));
});
