#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";

import {
  finiteNumberOrNull,
  parseRadiusText,
  randomDelayMs,
  wgs84GeodesicKm,
} from "./facebook-radius-audit.mjs";

const DEFAULT_RADIUS_KM = 16;
const DEFAULT_DELAY_MIN_MS = 3_000;
const DEFAULT_DELAY_MAX_MS = 6_000;

function parseArguments(argv) {
  const options = {
    registry: new URL("./locations.json", import.meta.url),
    output: "location-verification.json",
    query: "dresser",
    radiusKm: DEFAULT_RADIUS_KM,
    delayMinMs: DEFAULT_DELAY_MIN_MS,
    delayMaxMs: DEFAULT_DELAY_MAX_MS,
    browserChannel: null,
    city: null,
    headless: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const next = () => {
      index += 1;
      if (index >= argv.length) throw new Error(`Missing value after ${argument}`);
      return argv[index];
    };
    if (argument === "--registry") options.registry = next();
    else if (argument === "--output") options.output = next();
    else if (argument === "--query") options.query = next();
    else if (argument === "--radius-km") options.radiusKm = Number(next());
    else if (argument === "--delay-min-ms") options.delayMinMs = Number(next());
    else if (argument === "--delay-max-ms") options.delayMaxMs = Number(next());
    else if (argument === "--browser-channel") options.browserChannel = next();
    else if (argument === "--city") options.city = next();
    else if (argument === "--headless") options.headless = true;
    else throw new Error(`Unknown argument: ${argument}`);
  }
  if (!Number.isFinite(options.radiusKm) || options.radiusKm <= 0) {
    throw new Error("--radius-km must be greater than zero");
  }
  if (
    !Number.isFinite(options.delayMinMs) ||
    !Number.isFinite(options.delayMaxMs) ||
    options.delayMinMs < 0 ||
    options.delayMaxMs < options.delayMinMs
  ) {
    throw new Error("Delay bounds are invalid");
  }
  return options;
}

async function extractTargeting(page) {
  await page.waitForFunction(
    () =>
      Array.from(document.scripts).some(
        (script) =>
          script.type === "application/json" &&
          (script.textContent ?? "").includes("marketplace_search"),
      ),
    null,
    { timeout: 30_000 },
  );
  await page
    .waitForFunction(
      () => /\d+(?:[.,]\d+)?\s*(?:km|mi)\b/i.test(document.body.innerText),
      null,
      { timeout: 10_000 },
    )
    .catch(() => {});
  return page.evaluate(() => {
    const queries = [];
    for (const script of Array.from(document.scripts)) {
      if (script.type !== "application/json" || !script.textContent) continue;
      let root;
      try {
        root = JSON.parse(script.textContent);
      } catch {
        continue;
      }
      const stack = [root];
      while (stack.length > 0) {
        const object = stack.pop();
        if (!object || typeof object !== "object") continue;
        if (object.queryName === "CometMarketplaceSearchContentContainerQuery") {
          queries.push({
            actorID: object.actorID,
            queryID: object.queryID,
            variables: object.variables,
          });
        }
        for (const value of Object.values(object)) {
          if (value && typeof value === "object") stack.push(value);
        }
      }
    }
    const query =
      queries.find(
        (candidate) =>
          candidate?.variables?.params?.browse_request_params?.filter_radius_km != null,
      ) ?? queries[0] ?? null;
    const visibleRadiusCandidates = Array.from(document.querySelectorAll("button"))
      .filter((button) => button.getClientRects().length > 0)
      .map((button) => (button.innerText ?? "").trim())
      .filter((text) => /\d+(?:[.,]\d+)?\s*(?:km|mi)\b/i.test(text));
    if (visibleRadiusCandidates.length === 0) {
      visibleRadiusCandidates.push(
        ...document.body.innerText
          .split(String.fromCharCode(10))
          .slice(0, 30)
          .filter((text) => /\d+(?:[.,]\d+)?\s*(?:km|mi)\b/i.test(text)),
      );
    }
    return {
      query,
      visible_radius_candidates: visibleRadiusCandidates,
      body_text: document.body.innerText,
      login_control_visible: /(^|\n)Log In(\n|$)/i.test(document.body.innerText),
    };
  });
}

function marketplaceSearchUrl(location, query, radiusKm) {
  const url = new URL(`https://www.facebook.com/marketplace/${location.url_key}/search/`);
  url.searchParams.set("query", query);
  url.searchParams.set("exact", "false");
  url.searchParams.set("radius", String(radiusKm));
  return url;
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const registry = JSON.parse(await readFile(options.registry, "utf8"));
  const locations = options.city
    ? registry.locations.filter(
        (location) => location.city.toLowerCase() === options.city.toLowerCase(),
      )
    : registry.locations;
  if (locations.length === 0) throw new Error(`No registry entry matched --city ${options.city}`);
  const { chromium } = await import("playwright");
  const browser = await chromium.launch({
    headless: options.headless,
    ...(options.browserChannel ? { channel: options.browserChannel } : {}),
  });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    locale: "en-CA",
  });
  const page = await context.newPage();
  const results = [];
  let stoppedForRateLimit = false;

  try {
    for (const [index, location] of locations.entries()) {
      const delayMs = randomDelayMs(options.delayMinMs, options.delayMaxMs);
      process.stderr.write(
        `[${index + 1}/${locations.length}] waiting ${delayMs} ms, then ${location.city}\n`,
      );
      await new Promise((resolve) => setTimeout(resolve, delayMs));
      const requestedUrl = marketplaceSearchUrl(location, options.query, options.radiusKm);
      let httpStatus = null;
      let error = null;
      let extracted = null;
      try {
        const response = await page.goto(requestedUrl.toString(), {
          waitUntil: "domcontentloaded",
          timeout: 30_000,
        });
        httpStatus = response?.status() ?? null;
        if (httpStatus === 403 || httpStatus === 429) {
          stoppedForRateLimit = true;
          throw new Error(`Facebook returned HTTP ${httpStatus}`);
        }
        extracted = await extractTargeting(page);
        if (/temporarily blocked|we limit how often you can|try again later/i.test(extracted.body_text)) {
          stoppedForRateLimit = true;
          throw new Error("Facebook displayed a temporary-block signal");
        }
      } catch (cause) {
        error = cause instanceof Error ? cause.message : String(cause);
      }

      const browse = extracted?.query?.variables?.params?.browse_request_params ?? {};
      const responseRadiusKm = finiteNumberOrNull(browse.filter_radius_km);
      const latitude = finiteNumberOrNull(browse.filter_location_latitude);
      const longitude = finiteNumberOrNull(browse.filter_location_longitude);
      const visibleRadius = (extracted?.visible_radius_candidates ?? [])
        .map(parseRadiusText)
        .find(Boolean);
      const centerErrorKm =
        latitude != null && longitude != null
          ? wgs84GeodesicKm(
              location.reference_latitude,
              location.reference_longitude,
              latitude,
              longitude,
            )
          : null;
      const actorIdIsZero = String(extracted?.query?.actorID ?? "") === "0";
      const verified =
        error == null &&
        actorIdIsZero &&
        extracted?.login_control_visible === true &&
        responseRadiusKm === options.radiusKm &&
        visibleRadius != null &&
        Math.abs(visibleRadius.kilometers - options.radiusKm) <= 0.25 &&
        centerErrorKm != null &&
        centerErrorKm <= 50;
      results.push({
        city: location.city,
        region: location.region,
        country: location.country,
        url_key: location.url_key,
        url_kind: location.url_kind,
        marketplace_path: `/marketplace/${location.url_key}/`,
        requested_url: requestedUrl.toString(),
        final_url: page.url(),
        http_status: httpStatus,
        request_delay_ms: delayMs,
        unauthenticated_actor_id_is_zero: actorIdIsZero,
        login_control_visible: extracted?.login_control_visible ?? null,
        visual_filter_text: visibleRadius?.text ?? null,
        visual_filter_km: visibleRadius?.kilometers ?? null,
        filter_radius_km: responseRadiusKm,
        filter_location_latitude: latitude,
        filter_location_longitude: longitude,
        reference_center_error_km:
          centerErrorKm == null ? null : Number(centerErrorKm.toFixed(2)),
        city_name_visible: new RegExp(`\\b${location.city.replaceAll(" ", "\\s+")}\\b`, "i").test(
          extracted?.body_text ?? "",
        ),
        verified,
        error,
      });
      if (stoppedForRateLimit) break;
    }
  } finally {
    await context.close();
    await browser.close();
  }

  const report = {
    schema_version: 1,
    captured_at: new Date().toISOString(),
    surface: "unauthenticated_desktop_web_search_only",
    input: {
      registry: String(options.registry),
      query: options.query,
      radius_km: options.radiusKm,
      delay_min_ms: options.delayMinMs,
      delay_max_ms: options.delayMaxMs,
    },
    summary: {
      status: stoppedForRateLimit ? "stopped_rate_limit" : "complete",
      requested_location_count: locations.length,
      checked_location_count: results.length,
      verified_location_count: results.filter((result) => result.verified).length,
      failed_location_count: results.filter((result) => !result.verified).length,
    },
    locations: results,
  };
  await writeFile(options.output, `${JSON.stringify(report, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify(report.summary, null, 2)}\n`);
  process.stdout.write(`JSON: ${options.output}\n`);
  if (report.summary.failed_location_count > 0 || stoppedForRateLimit) process.exitCode = 1;
}

await main();
