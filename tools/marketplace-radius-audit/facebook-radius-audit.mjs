#!/usr/bin/env node

import { writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const DEFAULT_VIEWPORT = { width: 1440, height: 900 };
const RADIUS_TOLERANCE_KM = 0.25;
const DEFAULT_DELAY_MIN_MS = 3_000;
const DEFAULT_DELAY_MAX_MS = 6_000;

export function haversineKm(originLatitude, originLongitude, latitude, longitude) {
  const radians = (degrees) => (degrees * Math.PI) / 180;
  const earthRadiusKm = 6371.0088;
  const latitudeDelta = radians(latitude - originLatitude);
  const longitudeDelta = radians(longitude - originLongitude);
  const originRadians = radians(originLatitude);
  const destinationRadians = radians(latitude);
  const a =
    Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(originRadians) *
      Math.cos(destinationRadians) *
      Math.sin(longitudeDelta / 2) ** 2;
  return 2 * earthRadiusKm * Math.asin(Math.sqrt(a));
}

export function parseRadiusText(text) {
  const normalized = String(text ?? "").replaceAll("\u00a0", " ");
  const match = normalized.match(/(\d+(?:[.,]\d+)?)\s*(km|mi)\b/i);
  if (!match) return null;
  const value = Number(match[1].replace(",", "."));
  const unit = match[2].toLowerCase();
  return {
    text: normalized.trim(),
    value,
    unit,
    kilometers: unit === "mi" ? value * 1.609344 : value,
  };
}

export function sanitizeText(value) {
  if (value == null) return null;
  return String(value)
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[redacted-email]")
    .replace(/https?:\/\/\S+/gi, "[redacted-url]")
    .replace(/(?<!\w)(?:\+?\d[\s().-]*){7,}\d(?!\w)/g, "[redacted-phone]")
    .trim();
}

export function compareRadii({ urlRadiusKm, responseRadiusKm, visualRadiusKm }) {
  const close = (left, right) =>
    Number.isFinite(left) &&
    Number.isFinite(right) &&
    Math.abs(left - right) <= RADIUS_TOLERANCE_KM;
  return {
    tolerance_km: RADIUS_TOLERANCE_KM,
    url_matches_response: close(urlRadiusKm, responseRadiusKm),
    visual_matches_response: close(visualRadiusKm, responseRadiusKm),
    all_match:
      close(urlRadiusKm, responseRadiusKm) &&
      close(visualRadiusKm, responseRadiusKm),
  };
}

export function randomDelayMs(minimum, maximum, random = Math.random) {
  if (!Number.isFinite(minimum) || !Number.isFinite(maximum) || minimum < 0) {
    throw new Error("Delay bounds must be non-negative finite numbers");
  }
  if (maximum < minimum) throw new Error("Maximum delay must be at least the minimum");
  return Math.floor(minimum + random() * (maximum - minimum + 1));
}

function round(value, digits = 2) {
  if (!Number.isFinite(value)) return null;
  return Number(value.toFixed(digits));
}

function usage() {
  return `
Usage:
  pnpm run audit --url <facebook-marketplace-search-url> [options]

Options:
  --url <url>                 Required Marketplace search URL.
  --output <path>             JSON report path (default: marketplace-radius-audit.json).
  --csv <path>                Optional flat CSV report.
  --max-results <n>           Maximum initial results to audit (default: 24).
  --delay-min-ms <n>          Minimum delay before each item page (default: 3000).
  --delay-max-ms <n>          Maximum delay before each item page (default: 6000).
  --timeout-ms <n>            Navigation/data timeout (default: 30000).
  --locale <locale>           Browser locale (default: en-CA).
  --browser-channel <name>    Playwright browser channel, e.g. chrome.
  --headless                  Run without showing Chromium.
  --allow-radius-mismatch     Continue when URL, visual, and GraphQL radii differ.
  --help                      Show this message.
`;
}

function parseArguments(argv) {
  const options = {
    url: null,
    output: "marketplace-radius-audit.json",
    csv: null,
    maxResults: 24,
    delayMinMs: DEFAULT_DELAY_MIN_MS,
    delayMaxMs: DEFAULT_DELAY_MAX_MS,
    timeoutMs: 30_000,
    locale: "en-CA",
    browserChannel: null,
    headless: false,
    allowRadiusMismatch: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const next = () => {
      index += 1;
      if (index >= argv.length) throw new Error(`Missing value after ${argument}`);
      return argv[index];
    };
    if (argument === "--url") options.url = next();
    else if (argument === "--output") options.output = next();
    else if (argument === "--csv") options.csv = next();
    else if (argument === "--max-results") options.maxResults = Number(next());
    else if (argument === "--delay-min-ms") options.delayMinMs = Number(next());
    else if (argument === "--delay-max-ms") options.delayMaxMs = Number(next());
    else if (argument === "--timeout-ms") options.timeoutMs = Number(next());
    else if (argument === "--locale") options.locale = next();
    else if (argument === "--browser-channel") options.browserChannel = next();
    else if (argument === "--headless") options.headless = true;
    else if (argument === "--allow-radius-mismatch") options.allowRadiusMismatch = true;
    else if (argument === "--help" || argument === "-h") options.help = true;
    else throw new Error(`Unknown argument: ${argument}`);
  }

  if (options.help) return options;
  if (!options.url) throw new Error("--url is required");
  if (!Number.isInteger(options.maxResults) || options.maxResults < 1) {
    throw new Error("--max-results must be a positive integer");
  }
  if (!Number.isFinite(options.delayMinMs) || options.delayMinMs < 0) {
    throw new Error("--delay-min-ms must be zero or greater");
  }
  if (!Number.isFinite(options.delayMaxMs) || options.delayMaxMs < 0) {
    throw new Error("--delay-max-ms must be zero or greater");
  }
  if (options.delayMaxMs < options.delayMinMs) {
    throw new Error("--delay-max-ms must be at least --delay-min-ms");
  }
  return options;
}

async function waitForSearchPayload(page, timeoutMs) {
  await page.waitForFunction(
    () =>
      Array.from(document.scripts).some(
        (script) =>
          script.type === "application/json" &&
          (script.textContent ?? "").includes("marketplace_search"),
      ),
    null,
    { timeout: timeoutMs },
  );
}

async function extractSearchPage(page) {
  return page.evaluate(() => {
    const parsedScripts = [];
    for (const script of Array.from(document.scripts)) {
      if (script.type !== "application/json" || !script.textContent) continue;
      try {
        parsedScripts.push(JSON.parse(script.textContent));
      } catch {
        // Facebook also emits non-JSON scripts. Ignore only parse failures.
      }
    }

    const queries = [];
    const searches = [];
    for (const root of parsedScripts) {
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
        if (Object.prototype.hasOwnProperty.call(object, "marketplace_search")) {
          searches.push(object.marketplace_search);
        }
        for (const value of Object.values(object)) {
          if (value && typeof value === "object") stack.push(value);
        }
      }
    }

    const search =
      searches.find((candidate) => candidate?.feed_units?.edges?.length > 0) ??
      searches[0] ??
      null;
    const listings = (search?.feed_units?.edges ?? [])
      .map((edge, index) => {
        const node = edge?.node ?? {};
        const listing = node?.listing ?? {};
        const reverseGeocode = listing?.location?.reverse_geocode ?? {};
        return {
          rank: index + 1,
          listing_id: listing.id ?? null,
          name: listing.marketplace_listing_title ?? null,
          price_text:
            listing?.listing_price?.formatted_amount ??
            listing?.formatted_price?.text ??
            null,
          price_amount: listing?.listing_price?.amount ?? null,
          currency: listing?.listing_price?.currency ?? null,
          city: reverseGeocode.city ?? null,
          state: reverseGeocode.state ?? null,
          delivery_types: listing.delivery_types ?? [],
          story_type: node.story_type ?? null,
          node_type: node.__typename ?? null,
        };
      })
      .filter((listing) => listing.listing_id);

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
      query:
        queries.find(
          (query) =>
            query?.variables?.params?.browse_request_params?.filter_radius_km != null,
        ) ??
        queries[0] ??
        null,
      listings,
      visible_radius_candidates: visibleRadiusCandidates,
      shows_login: /(^|\n)Log In(\n|$)/i.test(document.body.innerText),
    };
  });
}

async function waitForItemPayload(page, listingId, timeoutMs) {
  await page
    .waitForFunction(
      (targetId) =>
        Array.from(document.scripts).some((script) => {
          const text = script.textContent ?? "";
          return text.includes(`\"id\":\"${targetId}\"`) && text.includes("item_location");
        }),
      listingId,
      { timeout: timeoutMs },
    )
    .catch(() => {});
}

async function extractItemPage(page, listingId) {
  return page.evaluate((targetId) => {
    const parsedScripts = [];
    for (const script of Array.from(document.scripts)) {
      if (script.type !== "application/json" || !script.textContent) continue;
      try {
        parsedScripts.push(JSON.parse(script.textContent));
      } catch {
        // Ignore non-JSON script bodies.
      }
    }

    const matches = [];
    for (const root of parsedScripts) {
      const stack = [root];
      while (stack.length > 0) {
        const object = stack.pop();
        if (!object || typeof object !== "object") continue;
        if (
          String(object.id ?? "") === targetId &&
          (object.item_location ||
            object?.location?.latitude != null ||
            object.marketplace_listing_title)
        ) {
          matches.push({
            item_location: object.item_location ?? null,
            location: object.location ?? null,
            shipping_offered: object.shipping_offered ?? null,
            delivery_types: object.delivery_types ?? null,
          });
        }
        for (const value of Object.values(object)) {
          if (value && typeof value === "object") stack.push(value);
        }
      }
    }

    const best =
      matches.find((match) => match?.item_location?.latitude != null) ??
      matches.find((match) => match?.location?.latitude != null) ??
      null;
    const coordinates = best?.item_location ?? best?.location ?? null;
    const locationLine = document.body.innerText
      .split(String.fromCharCode(10))
      .find((line) => line.includes("Location is approximate"));

    return {
      approximate_latitude: coordinates?.latitude ?? null,
      approximate_longitude: coordinates?.longitude ?? null,
      location_is_approximate: Boolean(locationLine),
      detail_location_label: locationLine?.split(" · ")[0]?.trim() ?? null,
      shipping_offered: best?.shipping_offered ?? null,
      delivery_types: best?.delivery_types ?? null,
    };
  }, listingId);
}

async function detectBlockingPage(page) {
  return page.evaluate(() => {
    const text = document.body.innerText;
    const reason = [
      /temporarily blocked/i,
      /you['’]re misusing this feature by going too fast/i,
      /we limit how often you can/i,
      /try again later/i,
    ].find((pattern) => pattern.test(text));
    return reason ? reason.source : null;
  });
}

function listingItemUrl(listingId) {
  return `https://www.facebook.com/marketplace/item/${listingId}/`;
}

function csvEscape(value) {
  if (value == null) return "";
  const text = Array.isArray(value) ? value.join("|") : String(value);
  return `"${text.replaceAll('"', '""')}"`;
}

function reportToCsv(report) {
  const columns = [
    "rank",
    "listing_id",
    "name",
    "price_text",
    "price_amount",
    "currency",
    "city",
    "state",
    "approximate_latitude",
    "approximate_longitude",
    "distance_km",
    "distance_miles",
    "outside_filter_radius",
    "distance_over_radius_km",
    "delivery_types",
    "shipping_offered",
    "location_is_approximate",
    "error",
  ];
  const rows = report.listings.map((listing) => {
    const response = listing.response;
    const derived = listing.derived;
    return columns.map((column) => {
      if (column in response) return csvEscape(response[column]);
      if (column in derived) return csvEscape(derived[column]);
      return csvEscape(listing[column]);
    });
  });
  return [columns.map(csvEscape), ...rows].map((row) => row.join(",")).join("\n");
}

async function runAudit(options) {
  const inputUrl = new URL(options.url);
  if (!/^(?:www\.)?facebook\.com$/i.test(inputUrl.hostname)) {
    throw new Error("--url must use www.facebook.com");
  }
  if (!inputUrl.pathname.includes("/marketplace/") || !inputUrl.pathname.includes("/search/")) {
    throw new Error("--url must be a Facebook Marketplace search URL");
  }
  const urlRadiusKm = Number(inputUrl.searchParams.get("radius"));
  if (!Number.isFinite(urlRadiusKm)) {
    throw new Error("The search URL must include a numeric radius parameter");
  }

  const { chromium } = await import("playwright");
  const browser = await chromium.launch({
    headless: options.headless,
    ...(options.browserChannel ? { channel: options.browserChannel } : {}),
  });
  const context = await browser.newContext({
    viewport: DEFAULT_VIEWPORT,
    locale: options.locale,
  });
  const searchPage = await context.newPage();
  const report = {
    schema_version: 1,
    captured_at: new Date().toISOString(),
    surface: "unauthenticated_desktop_web",
    input: {
      url: inputUrl.toString(),
      url_radius_km: urlRadiusKm,
      max_results: options.maxResults,
      locale: options.locale,
      browser_channel: options.browserChannel ?? "bundled-chromium",
      viewport: DEFAULT_VIEWPORT,
      delay_min_ms: options.delayMinMs,
      delay_max_ms: options.delayMaxMs,
    },
    validation: null,
    response_metadata: null,
    methodology: {
      result_scope: "initial search response only; no pagination",
      item_location_source: "item detail GraphQL item_location/location fields",
      distance_method: "Haversine straight-line distance to Facebook's approximate pin",
      distance_warning:
        "Driving distance will usually be longer. Facebook explicitly labels item pins approximate.",
      pii_policy:
        "No seller, profile, description, image, address, cookie, or account data is collected. Email, URL, and phone-like strings are redacted from requested listing text fields.",
      rate_limit_policy: {
        concurrency: 1,
        randomized_delay_before_each_item_request: true,
        delay_min_ms: options.delayMinMs,
        delay_max_ms: options.delayMaxMs,
        abort_http_statuses: [403, 429],
        retries_after_rate_limit: 0,
      },
    },
    summary: null,
    listings: [],
  };

  try {
    await searchPage.goto(inputUrl.toString(), {
      waitUntil: "domcontentloaded",
      timeout: options.timeoutMs,
    });
    await waitForSearchPayload(searchPage, options.timeoutMs);
    const search = await extractSearchPage(searchPage);
    if (!search.query) throw new Error("Marketplace search GraphQL metadata was not found");

    const actorIdIsZero = String(search.query.actorID ?? "") === "0";
    if (!actorIdIsZero || !search.shows_login) {
      throw new Error(
        "The browser does not look unauthenticated (expected actorID 0 and a visible Log In control)",
      );
    }

    const browseParameters = search.query.variables?.params?.browse_request_params ?? {};
    const responseRadiusKm = Number(browseParameters.filter_radius_km);
    const sourceLatitude = Number(browseParameters.filter_location_latitude);
    const sourceLongitude = Number(browseParameters.filter_location_longitude);
    const visibleRadius = search.visible_radius_candidates
      .map(parseRadiusText)
      .find(Boolean);
    const radiusChecks = compareRadii({
      urlRadiusKm,
      responseRadiusKm,
      visualRadiusKm: visibleRadius?.kilometers,
    });

    report.validation = {
      unauthenticated_actor_id_is_zero: actorIdIsZero,
      login_control_visible: search.shows_login,
      visible_filter_text: visibleRadius?.text ?? null,
      visible_filter_value: visibleRadius?.value ?? null,
      visible_filter_unit: visibleRadius?.unit ?? null,
      visible_filter_km: round(visibleRadius?.kilometers, 3),
      radius_checks: radiusChecks,
    };
    report.response_metadata = {
      query_name: "CometMarketplaceSearchContentContainerQuery",
      query_id: search.query.queryID ?? null,
      filter_radius_km: responseRadiusKm,
      filter_location_latitude: sourceLatitude,
      filter_location_longitude: sourceLongitude,
      buy_location_latitude: search.query.variables?.buyLocation?.latitude ?? null,
      buy_location_longitude: search.query.variables?.buyLocation?.longitude ?? null,
      requested_result_count: search.query.variables?.count ?? null,
      returned_initial_result_count: search.listings.length,
    };

    if (!radiusChecks.all_match && !options.allowRadiusMismatch) {
      report.summary = {
        status: "stopped_radius_mismatch",
        returned_initial_result_count: search.listings.length,
        audited_result_count: 0,
      };
      await writeFile(options.output, `${JSON.stringify(report, null, 2)}\n`);
      throw new Error(
        `Radius mismatch: URL=${urlRadiusKm} km, visual=${round(visibleRadius?.kilometers, 3)} km, GraphQL=${responseRadiusKm} km. Partial report written to ${options.output}`,
      );
    }
    if (!Number.isFinite(sourceLatitude) || !Number.isFinite(sourceLongitude)) {
      throw new Error("GraphQL filter location coordinates were missing");
    }

    const selectedListings = search.listings.slice(0, options.maxResults);
    const detailPage = await context.newPage();
    let stoppedForRateLimit = false;
    for (const [index, listing] of selectedListings.entries()) {
      const cleaned = {
        ...listing,
        name: sanitizeText(listing.name),
        price_text: sanitizeText(listing.price_text),
        city: sanitizeText(listing.city),
        state: sanitizeText(listing.state),
      };
      const requestDelayMs = randomDelayMs(options.delayMinMs, options.delayMaxMs);
      process.stderr.write(
        `[${index + 1}/${selectedListings.length}] waiting ${requestDelayMs} ms, then ${cleaned.city ?? "Unknown city"} — ${cleaned.name ?? cleaned.listing_id}\n`,
      );
      await new Promise((resolve) => setTimeout(resolve, requestDelayMs));

      let detail = null;
      let error = null;
      let httpStatus = null;
      try {
        const navigationResponse = await detailPage.goto(listingItemUrl(cleaned.listing_id), {
          waitUntil: "domcontentloaded",
          timeout: options.timeoutMs,
        });
        httpStatus = navigationResponse?.status() ?? null;
        if (httpStatus === 403 || httpStatus === 429) {
          stoppedForRateLimit = true;
          throw new Error(
            `Facebook returned HTTP ${httpStatus}; stopped without retrying to protect the browser session`,
          );
        }
        const blockingReason = await detectBlockingPage(detailPage);
        if (blockingReason) {
          stoppedForRateLimit = true;
          throw new Error(
            `Facebook displayed a rate-limit/interstitial signal (${blockingReason}); stopped without retrying`,
          );
        }
        await waitForItemPayload(detailPage, cleaned.listing_id, options.timeoutMs);
        detail = await extractItemPage(detailPage, cleaned.listing_id);
      } catch (cause) {
        error = cause instanceof Error ? cause.message : String(cause);
      }

      const latitude = Number(detail?.approximate_latitude);
      const longitude = Number(detail?.approximate_longitude);
      const hasCoordinates = Number.isFinite(latitude) && Number.isFinite(longitude);
      const distanceKm = hasCoordinates
        ? haversineKm(sourceLatitude, sourceLongitude, latitude, longitude)
        : null;
      report.listings.push({
        rank: cleaned.rank,
        listing_id: cleaned.listing_id,
        item_url: listingItemUrl(cleaned.listing_id),
        audit: {
          request_delay_ms: requestDelayMs,
          http_status: httpStatus,
        },
        response: {
          name: cleaned.name,
          price_text: cleaned.price_text,
          price_amount: cleaned.price_amount,
          currency: cleaned.currency,
          city: cleaned.city,
          state: cleaned.state,
          delivery_types: detail?.delivery_types ?? cleaned.delivery_types,
          shipping_offered: detail?.shipping_offered ?? null,
          approximate_latitude: hasCoordinates ? latitude : null,
          approximate_longitude: hasCoordinates ? longitude : null,
          location_is_approximate: detail?.location_is_approximate ?? null,
          detail_location_label: sanitizeText(detail?.detail_location_label),
          story_type: cleaned.story_type,
          node_type: cleaned.node_type,
        },
        derived: {
          distance_km: round(distanceKm),
          distance_miles: round(distanceKm == null ? null : distanceKm * 0.621371),
          outside_filter_radius:
            distanceKm == null ? null : distanceKm > responseRadiusKm,
          distance_over_radius_km:
            distanceKm == null ? null : round(Math.max(0, distanceKm - responseRadiusKm)),
        },
        error,
      });
      if (stoppedForRateLimit) break;
    }

    const measured = report.listings.filter(
      (listing) => listing.derived.distance_km != null,
    );
    report.summary = {
      status: stoppedForRateLimit ? "stopped_rate_limit" : "complete",
      returned_initial_result_count: search.listings.length,
      audited_result_count: report.listings.length,
      skipped_after_stop_count: selectedListings.length - report.listings.length,
      measured_result_count: measured.length,
      missing_coordinate_count: report.listings.length - measured.length,
      outside_filter_radius_count: measured.filter(
        (listing) => listing.derived.outside_filter_radius,
      ).length,
    };

    await writeFile(options.output, `${JSON.stringify(report, null, 2)}\n`);
    if (options.csv) await writeFile(options.csv, `${reportToCsv(report)}\n`);
    process.stdout.write(`${JSON.stringify(report.summary, null, 2)}\n`);
    process.stdout.write(`JSON: ${options.output}\n`);
    if (options.csv) process.stdout.write(`CSV: ${options.csv}\n`);
    return report;
  } finally {
    await context.close();
    await browser.close();
  }
}

async function main() {
  try {
    const options = parseArguments(process.argv.slice(2));
    if (options.help) {
      process.stdout.write(usage());
      return;
    }
    await runAudit(options);
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
