import assert from "node:assert/strict";
import test from "node:test";

import {
  compareRadii,
  haversineKm,
  parseRadiusText,
  randomDelayMs,
  sanitizeText,
} from "./facebook-radius-audit.mjs";

test("parses metric and imperial visual radius labels", () => {
  assert.deepEqual(parseRadiusText("San Francisco · Within 16 km"), {
    text: "San Francisco · Within 16 km",
    value: 16,
    unit: "km",
    kilometers: 16,
  });
  assert.equal(parseRadiusText("Toronto · 10 mi").kilometers, 16.09344);
});

test("accepts 10 miles as a visual match for a 16 km request", () => {
  assert.deepEqual(
    compareRadii({
      urlRadiusKm: 16,
      responseRadiusKm: 16,
      visualRadiusKm: 16.09344,
    }),
    {
      tolerance_km: 0.25,
      url_matches_response: true,
      visual_matches_response: true,
      all_match: true,
    },
  );
});

test("detects a saved-radius override", () => {
  assert.equal(
    compareRadii({
      urlRadiusKm: 16,
      responseRadiusKm: 8,
      visualRadiusKm: 8.04672,
    }).all_match,
    false,
  );
});

test("calculates the measured San Mateo example", () => {
  const distance = haversineKm(
    37.7793,
    -122.419,
    37.570495605469,
    -122.32727050781,
  );
  assert.ok(Math.abs(distance - 24.6) < 0.1);
});

test("redacts contact strings without removing requested listing text", () => {
  assert.equal(
    sanitizeText("Dresser call 415-555-1212 seller@example.com https://example.com"),
    "Dresser call [redacted-phone] [redacted-email] [redacted-url]",
  );
});

test("randomized delays include both configured bounds", () => {
  assert.equal(randomDelayMs(3_000, 6_000, () => 0), 3_000);
  assert.equal(randomDelayMs(3_000, 6_000, () => 0.999999), 6_000);
  assert.throws(() => randomDelayMs(6_000, 3_000), /Maximum delay/);
});
