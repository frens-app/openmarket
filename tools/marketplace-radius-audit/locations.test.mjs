import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const registry = JSON.parse(
  await readFile(new URL("./locations.json", import.meta.url), "utf8"),
);

test("location registry has unique canonical URL keys", () => {
  assert.equal(registry.schema_version, 1);
  assert.equal(registry.locations.length, 15);
  assert.equal(
    new Set(registry.locations.map((location) => location.city)).size,
    registry.locations.length,
  );
  assert.equal(
    new Set(registry.locations.map((location) => location.url_key)).size,
    registry.locations.length,
  );
  for (const location of registry.locations) {
    assert.match(location.url_key, /^(?:[a-z]+|\d+)$/);
    assert.equal(location.url_kind, "slug");
    assert.ok(Number.isFinite(location.reference_latitude));
    assert.ok(Number.isFinite(location.reference_longitude));
    assert.ok(Number.isFinite(location.facebook_filter_latitude));
    assert.ok(Number.isFinite(location.facebook_filter_longitude));
    assert.equal(location.marketplace_path, `/marketplace/${location.url_key}/`);
    assert.equal(location.verification_status, "verified");
  }
});

test("location registry preserves Facebook's non-obvious aliases", () => {
  const keys = Object.fromEntries(
    registry.locations.map((location) => [location.city, location.url_key]),
  );
  assert.equal(keys["New York"], "nyc");
  assert.equal(keys["Los Angeles"], "la");
  assert.equal(keys.Philadelphia, "philly");
  assert.equal(keys["San Francisco"], "sanfrancisco");
});
