#!/usr/bin/env node

import { writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const DEFAULT_VIEWPORT = { width: 1440, height: 900 };
const RADIUS_TOLERANCE_KM = 0.25;
const DEFAULT_DELAY_MIN_MS = 3_000;
const DEFAULT_DELAY_MAX_MS = 6_000;

export function wgs84GeodesicKm(originLatitude, originLongitude, latitude, longitude) {
  const radians = (degrees) => (degrees * Math.PI) / 180;
  const semiMajorAxisMeters = 6_378_137;
  const flattening = 1 / 298.257223563;
  const semiMinorAxisMeters = (1 - flattening) * semiMajorAxisMeters;
  const phi1 = radians(originLatitude);
  const phi2 = radians(latitude);
  const reducedLatitude1 = Math.atan((1 - flattening) * Math.tan(phi1));
  const reducedLatitude2 = Math.atan((1 - flattening) * Math.tan(phi2));
  const longitudeDifference = radians(longitude - originLongitude);
  let lambda = longitudeDifference;
  let previousLambda;
  let sinSigma;
  let cosSigma;
  let sigma;
  let sinAlpha;
  let cosSquaredAlpha;
  let cosTwoSigmaMidpoint;

  for (let iteration = 0; iteration < 200; iteration += 1) {
    const sinLambda = Math.sin(lambda);
    const cosLambda = Math.cos(lambda);
    const first = Math.cos(reducedLatitude2) * sinLambda;
    const second =
      Math.cos(reducedLatitude1) * Math.sin(reducedLatitude2) -
      Math.sin(reducedLatitude1) * Math.cos(reducedLatitude2) * cosLambda;
    sinSigma = Math.sqrt(first ** 2 + second ** 2);
    if (sinSigma === 0) return 0;
    cosSigma =
      Math.sin(reducedLatitude1) * Math.sin(reducedLatitude2) +
      Math.cos(reducedLatitude1) * Math.cos(reducedLatitude2) * cosLambda;
    sigma = Math.atan2(sinSigma, cosSigma);
    sinAlpha =
      (Math.cos(reducedLatitude1) * Math.cos(reducedLatitude2) * sinLambda) /
      sinSigma;
    cosSquaredAlpha = 1 - sinAlpha ** 2;
    cosTwoSigmaMidpoint =
      cosSquaredAlpha === 0
        ? 0
        : cosSigma -
          (2 * Math.sin(reducedLatitude1) * Math.sin(reducedLatitude2)) /
            cosSquaredAlpha;
    const correction =
      (flattening / 16) *
      cosSquaredAlpha *
      (4 + flattening * (4 - 3 * cosSquaredAlpha));
    previousLambda = lambda;
    lambda =
      longitudeDifference +
      (1 - correction) *
        flattening *
        sinAlpha *
        (sigma +
          correction *
            sinSigma *
            (cosTwoSigmaMidpoint +
              correction *
                cosSigma *
                (-1 + 2 * cosTwoSigmaMidpoint ** 2)));
    if (Math.abs(lambda - previousLambda) <= 1e-12) break;
    if (iteration === 199) {
      throw new Error("WGS84 geodesic calculation did not converge");
    }
  }

  const squaredU =
    (cosSquaredAlpha *
      (semiMajorAxisMeters ** 2 - semiMinorAxisMeters ** 2)) /
    semiMinorAxisMeters ** 2;
  const coefficientA =
    1 +
    (squaredU / 16_384) *
      (4096 + squaredU * (-768 + squaredU * (320 - 175 * squaredU)));
  const coefficientB =
    (squaredU / 1024) *
    (256 + squaredU * (-128 + squaredU * (74 - 47 * squaredU)));
  const sigmaCorrection =
    coefficientB *
    sinSigma *
    (cosTwoSigmaMidpoint +
      (coefficientB / 4) *
        (cosSigma * (-1 + 2 * cosTwoSigmaMidpoint ** 2) -
          (coefficientB / 6) *
            cosTwoSigmaMidpoint *
            (-3 + 4 * sinSigma ** 2) *
            (-3 + 4 * cosTwoSigmaMidpoint ** 2)));
  return (semiMinorAxisMeters * coefficientA * (sigma - sigmaCorrection)) / 1000;
}

export function finiteNumberOrNull(value) {
  if (value == null || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
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
  const urlMatchesResponse = close(urlRadiusKm, responseRadiusKm);
  const visualAvailable = Number.isFinite(visualRadiusKm);
  const visualMatchesResponse = visualAvailable
    ? close(visualRadiusKm, responseRadiusKm)
    : null;
  const status = !urlMatchesResponse
    ? "url_response_mismatch"
    : !visualAvailable
      ? "visual_unavailable"
      : !visualMatchesResponse
        ? "visual_mismatch"
        : "matched";
  return {
    tolerance_km: RADIUS_TOLERANCE_KM,
    status,
    visual_available: visualAvailable,
    url_matches_response: urlMatchesResponse,
    visual_matches_response: visualMatchesResponse,
    all_match: status === "matched",
  };
}

const LOCAL_HANDOFF_TYPES = new Set(["IN_PERSON", "DOOR_PICKUP", "PUBLIC_MEETUP"]);

export function classifyFulfillment(deliveryTypes, shippingOffered) {
  const types = Array.isArray(deliveryTypes) ? deliveryTypes : null;
  const localHandoffAvailable = types?.some((type) => LOCAL_HANDOFF_TYPES.has(type)) ?? null;
  const shippingAvailable =
    shippingOffered === true || types?.includes("SHIPPING_ONSITE") === true
      ? true
      : shippingOffered === false || types != null
        ? false
        : null;
  const nonlocalDeliveryAvailable = types?.includes("DOOR_DROPOFF") ?? null;
  let fulfillmentClass = "unknown";
  if (localHandoffAvailable === true && shippingAvailable === true) {
    fulfillmentClass = "local_and_shipping";
  } else if (localHandoffAvailable === true) {
    fulfillmentClass = "local_only";
  } else if (shippingAvailable === true) {
    fulfillmentClass = "shipping_only";
  } else if (nonlocalDeliveryAvailable === true) {
    fulfillmentClass = "nonlocal_delivery_only";
  }
  return {
    fulfillment_class: fulfillmentClass,
    local_handoff_available: localHandoffAvailable,
    shipping_available: shippingAvailable,
    nonlocal_delivery_available: nonlocalDeliveryAvailable,
  };
}

export function classifySponsorship(signals) {
  const positivePaths = signals?.positive_paths ?? [];
  const negativePaths = signals?.negative_paths ?? [];
  const storyType = signals?.story_type ?? null;
  const nodeType = signals?.node_type ?? null;
  if (signals?.dom_sponsored_label === true) {
    return { is_sponsored: true, sponsorship_status: "sponsored", evidence: ["dom_label"] };
  }
  if (positivePaths.length > 0) {
    return {
      is_sponsored: true,
      sponsorship_status: "sponsored",
      evidence: positivePaths.map((path) => `field:${path}`),
    };
  }
  if (
    /SPONSORED|PROMOTED|ADVERTISEMENT|ADSTORY|(?:^|[\s_])AD(?:$|[\s_])/i.test(
      `${storyType ?? ""} ${nodeType ?? ""}`,
    )
  ) {
    return {
      is_sponsored: true,
      sponsorship_status: "sponsored",
      evidence: ["story_or_node_type"],
    };
  }
  if (negativePaths.length > 0) {
    return {
      is_sponsored: false,
      sponsorship_status: "organic",
      evidence: negativePaths.map((path) => `field:${path}`),
    };
  }
  if (storyType === "POST" && nodeType === "MarketplaceFeedListingStoryObject") {
    return {
      is_sponsored: false,
      sponsorship_status: "organic",
      evidence: ["canonical_organic_story_shape"],
    };
  }
  return { is_sponsored: null, sponsorship_status: "unknown", evidence: [] };
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
  --allow-missing-visual-radius
                              Continue when the visible radius cannot be parsed.
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
    allowMissingVisualRadius: false,
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
    else if (argument === "--allow-missing-visual-radius") {
      options.allowMissingVisualRadius = true;
    }
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
    const domSponsoredListingIds = new Set();
    for (const anchor of Array.from(document.querySelectorAll('a[href*="/marketplace/item/"]'))) {
      const listingId = anchor.href.match(/\/marketplace\/item\/(\d+)/)?.[1];
      if (!listingId) continue;
      let candidate = anchor;
      for (let depth = 0; candidate && depth < 7; depth += 1) {
        const linkedListingCount = candidate.querySelectorAll?.(
          'a[href*="/marketplace/item/"]',
        ).length ?? 0;
        const text = `${candidate.getAttribute?.("aria-label") ?? ""}\n${candidate.innerText ?? ""}`;
        if (/(^|\n)Sponsored(\n|$)/i.test(text) && linkedListingCount <= 2) {
          domSponsoredListingIds.add(listingId);
          break;
        }
        if (linkedListingCount > 4) break;
        candidate = candidate.parentElement;
      }
    }

    const sponsorshipSignals = (edge, node, listing) => {
      const positivePaths = [];
      const negativePaths = [];
      const keyPattern = /^(?:is_?sponsored|sponsored_(?:data|metadata|label)|is_?promoted|paid_placement|ad_id|advertisement_id)$/i;
      const stack = [{ value: edge, path: "edge", depth: 0 }];
      while (stack.length > 0) {
        const current = stack.pop();
        if (!current.value || typeof current.value !== "object" || current.depth > 8) {
          continue;
        }
        for (const [key, value] of Object.entries(current.value)) {
          const path = `${current.path}.${key}`;
          if (keyPattern.test(key)) {
            const objectHasContent =
              value && typeof value === "object" && Object.keys(value).length > 0;
            const positive =
              value === true ||
              (typeof value === "string" && value.length > 0) ||
              (typeof value === "number" && value !== 0) ||
              objectHasContent;
            if (positive) positivePaths.push(path);
            else if (value === false) negativePaths.push(path);
          }
          if (value && typeof value === "object") {
            stack.push({ value, path, depth: current.depth + 1 });
          }
        }
      }
      return {
        positive_paths: [...new Set(positivePaths)],
        negative_paths: [...new Set(negativePaths)],
        dom_sponsored_label: domSponsoredListingIds.has(String(listing.id ?? "")),
        story_type: node.story_type ?? null,
        node_type: node.__typename ?? null,
      };
    };

    const feedUnits = (search?.feed_units?.edges ?? []).map((edge, index) => {
      const node = edge?.node ?? {};
      const listing = node?.listing ?? {};
      const reverseGeocode = listing?.location?.reverse_geocode ?? {};
      const signals = sponsorshipSignals(edge, node, listing);
      return {
        feed_rank: index + 1,
        has_listing: listing.id != null,
        listing_id: listing.id ?? null,
        story_type: node.story_type ?? null,
        node_type: node.__typename ?? null,
        sponsorship_signals: signals,
        listing:
          listing.id == null
            ? null
            : {
                rank: index + 1,
                listing_id: listing.id,
                name: listing.marketplace_listing_title ?? null,
                price_text:
                  listing?.listing_price?.formatted_amount ??
                  listing?.formatted_price?.text ??
                  null,
                price_amount: listing?.listing_price?.amount ?? null,
                currency: listing?.listing_price?.currency ?? null,
                city: reverseGeocode.city ?? null,
                state: reverseGeocode.state ?? null,
                delivery_types: listing.delivery_types ?? null,
                story_type: node.story_type ?? null,
                node_type: node.__typename ?? null,
                sponsorship_signals: signals,
              },
      };
    });
    const listings = feedUnits.flatMap((unit) => (unit.listing ? [unit.listing] : []));

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
      feed_units: feedUnits.map(({ listing, ...unit }) => unit),
      visible_radius_candidates: visibleRadiusCandidates,
      shows_login: /(^|\n)Log In(\n|$)/i.test(document.body.innerText),
    };
  });
}

async function waitForItemPayload(page, listingId, timeoutMs) {
  const startedAt = Date.now();
  try {
    await page.waitForFunction(
      (targetId) =>
        Array.from(document.scripts).some((script) => {
          const text = script.textContent ?? "";
          return (
            text.includes(`\"id\":\"${targetId}\"`) &&
            (text.includes("marketplace_listing_title") ||
              text.includes("location_text") ||
              text.includes("item_location"))
          );
        }),
      listingId,
      { timeout: timeoutMs },
    );
    return { status: "resolved", duration_ms: Date.now() - startedAt, error: null };
  } catch (cause) {
    const isTimeout = cause instanceof Error && cause.name === "TimeoutError";
    return {
      status: isTimeout ? "timeout" : "error",
      duration_ms: Date.now() - startedAt,
      error: isTimeout ? null : cause instanceof Error ? cause.message : String(cause),
    };
  }
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
            item_location_field_present: Object.prototype.hasOwnProperty.call(
              object,
              "item_location",
            ),
            location_field_present: Object.prototype.hasOwnProperty.call(object, "location"),
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

    const coordinateMatch =
      matches.find((match) => match?.item_location?.latitude != null) ??
      matches.find((match) => match?.location?.latitude != null) ??
      null;
    const fulfillmentMatch =
      matches.find(
        (match) => match.delivery_types != null || match.shipping_offered != null,
      ) ?? coordinateMatch;
    const coordinates = coordinateMatch?.item_location ?? coordinateMatch?.location ?? null;
    const coordinateFieldPresent = matches.some(
      (match) => match.item_location_field_present || match.location_field_present,
    );
    const latitude = coordinates?.latitude;
    const longitude = coordinates?.longitude;
    const coordinatesValid =
      latitude != null &&
      longitude != null &&
      latitude !== "" &&
      longitude !== "" &&
      Number.isFinite(Number(latitude)) &&
      Number.isFinite(Number(longitude));
    const locationLine = document.body.innerText
      .split(String.fromCharCode(10))
      .find((line) => line.includes("Location is approximate"));

    return {
      target_listing_match_found: matches.length > 0,
      target_listing_match_count: matches.length,
      coordinate_field_present: coordinateFieldPresent,
      coordinate_status: coordinatesValid
        ? "present"
        : coordinateFieldPresent
          ? "invalid_or_empty"
          : "absent",
      approximate_latitude: coordinatesValid ? Number(latitude) : null,
      approximate_longitude: coordinatesValid ? Number(longitude) : null,
      location_is_approximate: Boolean(locationLine),
      detail_location_label: locationLine?.split(" · ")[0]?.trim() ?? null,
      shipping_offered: fulfillmentMatch?.shipping_offered ?? null,
      delivery_types: fulfillmentMatch?.delivery_types ?? null,
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
    "is_sponsored",
    "sponsorship_status",
    "delivery_types",
    "shipping_offered",
    "fulfillment_class",
    "local_handoff_available",
    "shipping_available",
    "coordinate_status",
    "payload_wait_status",
    "location_is_approximate",
    "error",
  ];
  const rows = report.listings.map((listing) => {
    const response = listing.response;
    const derived = listing.derived;
    return columns.map((column) => {
      if (column in response) return csvEscape(response[column]);
      if (column in derived) return csvEscape(derived[column]);
      if (column === "coordinate_status") return csvEscape(listing.audit.coordinate_status);
      if (column === "payload_wait_status") {
        return csvEscape(listing.audit.payload_wait?.status);
      }
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
  const urlRadiusKm = finiteNumberOrNull(inputUrl.searchParams.get("radius"));
  if (urlRadiusKm == null) {
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
    schema_version: 2,
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
      allow_radius_mismatch: options.allowRadiusMismatch,
      allow_missing_visual_radius: options.allowMissingVisualRadius,
    },
    validation: null,
    response_metadata: null,
    methodology: {
      result_scope: "initial search response only; no pagination",
      item_location_source: "item detail GraphQL item_location/location fields",
      distance_method:
        "WGS84 ellipsoidal geodesic distance (Vincenty inverse) to Facebook's approximate pin",
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
    search.listings = search.listings.map((listing) => ({
      ...listing,
      ...classifySponsorship(listing.sponsorship_signals),
    }));
    search.feed_units = search.feed_units.map((unit) => ({
      ...unit,
      ...classifySponsorship(unit.sponsorship_signals),
    }));

    const actorIdIsZero = String(search.query.actorID ?? "") === "0";
    if (!actorIdIsZero || !search.shows_login) {
      throw new Error(
        "The browser does not look unauthenticated (expected actorID 0 and a visible Log In control)",
      );
    }

    const browseParameters = search.query.variables?.params?.browse_request_params ?? {};
    const responseRadiusKm = finiteNumberOrNull(browseParameters.filter_radius_km);
    const sourceLatitude = finiteNumberOrNull(browseParameters.filter_location_latitude);
    const sourceLongitude = finiteNumberOrNull(browseParameters.filter_location_longitude);
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
      returned_initial_feed_unit_count: search.feed_units.length,
      returned_initial_result_count: search.listings.length,
      listing_feed_unit_count: search.feed_units.filter((unit) => unit.has_listing).length,
      nonlisting_feed_unit_count: search.feed_units.filter((unit) => !unit.has_listing).length,
      sponsored_feed_unit_count: search.feed_units.filter(
        (unit) => unit.is_sponsored === true,
      ).length,
      organic_feed_unit_count: search.feed_units.filter(
        (unit) => unit.is_sponsored === false,
      ).length,
      unknown_sponsorship_feed_unit_count: search.feed_units.filter(
        (unit) => unit.is_sponsored == null,
      ).length,
      feed_units: search.feed_units.map((unit) => ({
        feed_rank: unit.feed_rank,
        has_listing: unit.has_listing,
        listing_id: unit.listing_id,
        story_type: unit.story_type,
        node_type: unit.node_type,
        is_sponsored: unit.is_sponsored,
        sponsorship_status: unit.sponsorship_status,
        sponsorship_evidence: unit.evidence,
      })),
    };

    const radiusMismatch =
      radiusChecks.status === "url_response_mismatch" ||
      radiusChecks.status === "visual_mismatch";
    if (radiusMismatch && !options.allowRadiusMismatch) {
      report.summary = {
        status: "stopped_radius_mismatch",
        radius_validation_status: radiusChecks.status,
        returned_initial_result_count: search.listings.length,
        audited_result_count: 0,
      };
      await writeFile(options.output, `${JSON.stringify(report, null, 2)}\n`);
      throw new Error(
        `Radius mismatch: URL=${urlRadiusKm} km, visual=${round(visibleRadius?.kilometers, 3)} km, GraphQL=${responseRadiusKm} km. Partial report written to ${options.output}`,
      );
    }
    if (!radiusChecks.visual_available && !options.allowMissingVisualRadius) {
      report.summary = {
        status: "stopped_visual_radius_unavailable",
        radius_validation_status: radiusChecks.status,
        returned_initial_result_count: search.listings.length,
        audited_result_count: 0,
      };
      await writeFile(options.output, `${JSON.stringify(report, null, 2)}\n`);
      throw new Error(
        `Visible radius could not be parsed while URL and GraphQL both reported ${responseRadiusKm} km. Partial report written to ${options.output}`,
      );
    }
    if (responseRadiusKm == null) {
      throw new Error("GraphQL filter radius was missing");
    }
    if (sourceLatitude == null || sourceLongitude == null) {
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
      let payloadWait = { status: "not_started", duration_ms: null, error: null };
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
        payloadWait = await waitForItemPayload(
          detailPage,
          cleaned.listing_id,
          options.timeoutMs,
        );
        detail = await extractItemPage(detailPage, cleaned.listing_id);
      } catch (cause) {
        error = cause instanceof Error ? cause.message : String(cause);
      }

      const latitude = finiteNumberOrNull(detail?.approximate_latitude);
      const longitude = finiteNumberOrNull(detail?.approximate_longitude);
      const hasCoordinates = latitude != null && longitude != null;
      const distanceKm = hasCoordinates
        ? wgs84GeodesicKm(sourceLatitude, sourceLongitude, latitude, longitude)
        : null;
      const deliveryTypes =
        detail?.delivery_types != null ? detail.delivery_types : cleaned.delivery_types;
      const deliveryTypesSource =
        detail?.delivery_types != null
          ? "detail"
          : cleaned.delivery_types != null
            ? "search"
            : "missing";
      const shippingOffered = detail?.shipping_offered ?? null;
      const fulfillment = classifyFulfillment(deliveryTypes, shippingOffered);
      const coordinateStatus = hasCoordinates
        ? "present"
        : detail?.coordinate_status ?? (error ? "navigation_or_extraction_error" : "unknown");
      report.listings.push({
        rank: cleaned.rank,
        listing_id: cleaned.listing_id,
        item_url: listingItemUrl(cleaned.listing_id),
        audit: {
          request_delay_ms: requestDelayMs,
          http_status: httpStatus,
          payload_wait: payloadWait,
          target_listing_match_found: detail?.target_listing_match_found ?? null,
          target_listing_match_count: detail?.target_listing_match_count ?? null,
          coordinate_field_present: detail?.coordinate_field_present ?? null,
          coordinate_status: coordinateStatus,
          delivery_types_source: deliveryTypesSource,
        },
        response: {
          name: cleaned.name,
          price_text: cleaned.price_text,
          price_amount: cleaned.price_amount,
          currency: cleaned.currency,
          city: cleaned.city,
          state: cleaned.state,
          is_sponsored: cleaned.is_sponsored,
          sponsorship_status: cleaned.sponsorship_status,
          sponsorship_evidence: cleaned.evidence,
          delivery_types: deliveryTypes,
          shipping_offered: shippingOffered,
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
          ...fulfillment,
        },
        error,
      });
      if (stoppedForRateLimit) break;
    }

    const measured = report.listings.filter(
      (listing) => listing.derived.distance_km != null,
    );
    const countBy = (items, selector) =>
      Object.fromEntries(
        [...items.reduce((counts, item) => {
          const key = String(selector(item));
          counts.set(key, (counts.get(key) ?? 0) + 1);
          return counts;
        }, new Map())].sort(([left], [right]) => left.localeCompare(right)),
      );
    const missingCoordinates = report.listings.filter(
      (listing) => listing.audit.coordinate_status !== "present",
    );
    const deliveryTypeGroups = new Map();
    for (const listing of report.listings) {
      const deliveryTypes = listing.response.delivery_types;
      const key =
        deliveryTypes == null
          ? "MISSING"
          : deliveryTypes.length === 0
            ? "EMPTY"
            : [...deliveryTypes].sort().join("|");
      const group = deliveryTypeGroups.get(key) ?? { audited_count: 0, missing_count: 0 };
      group.audited_count += 1;
      if (listing.audit.coordinate_status !== "present") group.missing_count += 1;
      deliveryTypeGroups.set(key, group);
    }
    report.summary = {
      status: stoppedForRateLimit ? "stopped_rate_limit" : "complete",
      radius_validation_status: radiusChecks.status,
      returned_initial_result_count: search.listings.length,
      returned_initial_feed_unit_count: search.feed_units.length,
      audited_result_count: report.listings.length,
      skipped_after_stop_count: selectedListings.length - report.listings.length,
      measured_result_count: measured.length,
      missing_coordinate_count: missingCoordinates.length,
      coordinate_status_counts: countBy(
        report.listings,
        (listing) => listing.audit.coordinate_status,
      ),
      payload_wait_status_counts: countBy(
        report.listings,
        (listing) => listing.audit.payload_wait.status,
      ),
      missing_coordinate_by_delivery_types: Object.fromEntries(
        [...deliveryTypeGroups.entries()].map(([key, group]) => [
          key,
          {
            ...group,
            missing_rate:
              group.audited_count === 0
                ? null
                : round(group.missing_count / group.audited_count, 4),
          },
        ]),
      ),
      fulfillment_class_counts: countBy(
        report.listings,
        (listing) => listing.derived.fulfillment_class,
      ),
      sponsorship_status_counts: countBy(
        report.listings,
        (listing) => listing.response.sponsorship_status,
      ),
      organic_local_handoff_count: report.listings.filter(
        (listing) =>
          listing.response.is_sponsored === false &&
          listing.derived.local_handoff_available === true,
      ).length,
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
