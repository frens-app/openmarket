import assert from "node:assert/strict";
import test from "node:test";

import {
  classifyFulfillment,
  classifySponsorship,
  compareRadii,
  finiteNumberOrNull,
  parseRadiusText,
  randomDelayMs,
  sanitizeText,
  wgs84GeodesicKm,
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
      status: "matched",
      visual_available: true,
      url_matches_response: true,
      visual_matches_response: true,
      all_match: true,
    },
  );
});

test("detects a saved-radius override", () => {
  const result = compareRadii({
    urlRadiusKm: 16,
    responseRadiusKm: 8,
    visualRadiusKm: 8.04672,
  });
  assert.equal(result.all_match, false);
  assert.equal(result.status, "url_response_mismatch");
});

test("distinguishes a missing visual radius from a mismatch", () => {
  const result = compareRadii({
    urlRadiusKm: 16,
    responseRadiusKm: 16,
    visualRadiusKm: undefined,
  });
  assert.equal(result.status, "visual_unavailable");
  assert.equal(result.visual_available, false);
  assert.equal(result.visual_matches_response, null);
  assert.equal(
    compareRadii({
      urlRadiusKm: 16,
      responseRadiusKm: 16,
      visualRadiusKm: 8,
    }).status,
    "visual_mismatch",
  );
});

test("calculates WGS84 ellipsoidal distance", () => {
  assert.ok(Math.abs(wgs84GeodesicKm(0, 0, 0, 1) - 111.319490793) < 1e-6);
  const distance = wgs84GeodesicKm(
    37.7793,
    -122.419,
    37.570495605469,
    -122.32727050781,
  );
  assert.ok(Math.abs(distance - 24.6) < 0.1);
});

test("does not coerce missing coordinates to zero", () => {
  assert.equal(finiteNumberOrNull(null), null);
  assert.equal(finiteNumberOrNull(undefined), null);
  assert.equal(finiteNumberOrNull(""), null);
  assert.equal(finiteNumberOrNull("37.5"), 37.5);
});

test("classifies fulfillment without treating missing data as local pickup", () => {
  assert.equal(
    classifyFulfillment(["IN_PERSON", "DOOR_PICKUP"], false).fulfillment_class,
    "local_only",
  );
  assert.equal(
    classifyFulfillment(["IN_PERSON", "SHIPPING_ONSITE"], true).fulfillment_class,
    "local_and_shipping",
  );
  assert.equal(classifyFulfillment(null, null).fulfillment_class, "unknown");
});

test("classifies sponsorship from explicit and canonical signals", () => {
  assert.equal(
    classifySponsorship({ positive_paths: ["edge.node.sponsored_data"] })
      .is_sponsored,
    true,
  );
  assert.equal(
    classifySponsorship({ node_type: "MarketplaceAdStory" }).is_sponsored,
    true,
  );
  assert.equal(
    classifySponsorship({
      story_type: "POST",
      node_type: "MarketplaceFeedListingStoryObject",
    }).is_sponsored,
    false,
  );
  assert.equal(classifySponsorship({ story_type: "UNKNOWN" }).is_sponsored, null);
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
