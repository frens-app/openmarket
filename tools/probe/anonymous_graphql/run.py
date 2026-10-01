#!/usr/bin/env python3
"""Bounded, cookie-free Marketplace query probe; prints aggregate results only."""
import argparse
import json
import pathlib
import time
import urllib.parse
import urllib.request


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def decode(raw):
    text = raw.decode("utf-8").removeprefix("for (;;);").strip()
    try:
        records = [json.loads(text)]
    except json.JSONDecodeError:
        records = [json.loads(line) for line in text.splitlines() if line.strip()]
    cards, info, errors = {}, None, []
    for record in records:
        if record.get("error"):
            errors.append(record["error"])
        errors.extend(record.get("errors") or [])
        for obj in walk(record):
            # The probe only runs feed queries. Do not reuse this recursive
            # collection on item pages: their related rail also has listings.
            if obj.get("id") and obj.get("marketplace_listing_title"):
                cards[obj["id"]] = obj
            if obj.get("__typename") == "MarketplaceFeedGeneralListingObject":
                listing = obj.get("listing") or {}
                entity = obj.get("entity") or {}
                data = obj.get("data") or {}
                if listing.get("id"):
                    cards[listing["id"]] = {
                        "id": listing["id"],
                        "marketplace_listing_title": data.get("title"),
                        "creation_time": listing.get("creation_time"),
                        "listing_price": data.get("price"),
                        "location": entity.get("location"),
                        "primary_listing_photo": obj.get("photo"),
                    }
            if isinstance(obj.get("page_info"), dict):
                info = obj["page_info"]
    return cards, info, errors, len(records)


def summarize(raw, seen):
    cards, info, errors, records = decode(raw)
    fields = ("id", "marketplace_listing_title", "creation_time", "listing_price",
              "location", "delivery_types", "is_sold", "primary_listing_photo")
    summary = {
        "bytes": len(raw), "records": records, "listings": len(cards),
        "new_ids": len(cards.keys() - seen),
        "duplicate_ids": len(cards.keys() & seen),
        "has_next_page": (info or {}).get("has_next_page"),
        "errors": errors,
        "field_coverage": {
            key: sum(card.get(key) is not None for card in cards.values())
            for key in fields
        },
    }
    return summary, cards, info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("surface", choices=("search", "browse"))
    parser.add_argument("--pages", type=int, choices=range(1, 6), default=2)
    parser.add_argument("--doc-id", help="Override the observed private query ID")
    parser.add_argument("--response-file", type=pathlib.Path,
                        help="Parse a saved response without making requests")
    args = parser.parse_args()
    if args.response_file:
        print(json.dumps(summarize(args.response_file.read_bytes(), set())[0], indent=2))
        return

    config = json.loads(pathlib.Path(__file__).with_name(args.surface + ".json").read_text())
    variables = config["variables"]
    seen, cursors, empty_pages = set(), set(), 0
    # No cookie processor: neither incoming Set-Cookie nor existing browser
    # cookies can become credentials on a subsequent request.
    opener = urllib.request.build_opener()
    for page in range(args.pages):
        fields = {
            "__user": "0", "av": "0", "__a": "1", "__comet_req": "15",
            "fb_api_caller_class": "RelayModern",
            "fb_api_req_friendly_name": config["operation"],
            "server_timestamps": "true",
            "doc_id": args.doc_id or config["doc_id"],
            "variables": json.dumps(variables),
        }
        request = urllib.request.Request(
            "https://www.facebook.com/api/graphql/",
            data=urllib.parse.urlencode(fields).encode(),
            headers={"User-Agent": "OpenMarket/0.0.1 (iOS)",
                     "Content-Type": "application/x-www-form-urlencoded",
                     "Accept": "application/json"},
        )
        started = time.perf_counter()
        # HTTP failures, including 403/429, terminate without retrying.
        with opener.open(request, timeout=10) as response:
            raw, status = response.read(), response.status
        network_ms = (time.perf_counter() - started) * 1000
        decode_started = time.perf_counter()
        summary, cards, info = summarize(raw, seen)
        summary.update(page=page, status=status, network_ms=round(network_ms, 2),
                       decode_ms=round((time.perf_counter() - decode_started) * 1000, 2))
        cursor = (info or {}).get("end_cursor")
        summary["cursor_changed"] = cursor != variables["cursor"]
        print(json.dumps(summary), flush=True)
        if summary["errors"]:
            raise RuntimeError("GraphQL returned errors; probe stopped")
        if info is None:
            raise RuntimeError("No feed page_info; response is not a verified page")
        if not info.get("has_next_page"):
            break
        if not cursor or cursor == variables["cursor"] or cursor in cursors:
            raise RuntimeError("Pagination cursor missing, repeated, or cyclic")
        empty_pages = empty_pages + 1 if summary["new_ids"] == 0 else 0
        if empty_pages >= 2:
            raise RuntimeError("Two pages without new cards; paused, not proven exhausted")
        seen.update(cards)
        cursors.add(cursor)
        variables["cursor"] = cursor
        if page + 1 < args.pages:
            time.sleep(0.5)


if __name__ == "__main__":
    main()
