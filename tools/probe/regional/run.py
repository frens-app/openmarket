#!/usr/bin/env python3
"""Bounded, cookie-free regional feed probe. Saves prices, never account data."""
import argparse
import datetime
import importlib.util
import json
import pathlib
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("feed_probe", ROOT.parent / "anonymous_graphql/run.py")
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)

MARKETS = [
    ("FR", "Paris", 48.8566, 2.3522), ("IT", "Rome", 41.9028, 12.4964),
    ("DE", "Berlin", 52.5200, 13.4050), ("MX", "Mexico City", 19.4326, -99.1332),
    ("PH", "Manila", 14.5995, 120.9842), ("BR", "São Paulo", -23.5505, -46.6333),
    ("IN", "Mumbai", 19.0760, 72.8777), ("ID", "Jakarta", -6.2088, 106.8456),
    ("VN", "Ho Chi Minh City", 10.8231, 106.6297), ("BD", "Dhaka", 23.8103, 90.4125),
    ("PK", "Karachi", 24.8607, 67.0011), ("EG", "Cairo", 30.0444, 31.2357),
    ("TH", "Bangkok", 13.7563, 100.5018), ("NG", "Lagos", 6.5244, 3.3792),
    ("CO", "Bogotá", 4.7110, -74.0721), ("TR", "Istanbul", 41.0082, 28.9784),
    ("AR", "Buenos Aires", -34.6037, -58.3816),
    ("ZA", "Johannesburg", -26.2041, 28.0473), ("DZ", "Algiers", 36.7538, 3.0588),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--raw-dir", type=pathlib.Path)
    args = parser.parse_args()
    if args.raw_dir:
        args.raw_dir.mkdir(parents=True, exist_ok=True)
    report = {"date": datetime.date.today().isoformat(), "method": "Cookie-free search (two pages) and Discover (one page), city coordinates, English query desk. No signed-in, detail, or UI verification implied.", "markets": []}
    opener = urllib.request.build_opener()
    for country, city, lat, lon in MARKETS:
        market = {"country": country, "city": city, "pages": []}
        report["markets"].append(market)
        for surface in ["search", "browse"]:
            config = json.loads((ROOT.parent / "anonymous_graphql" / (surface + ".json")).read_text())
            variables = config["variables"]
            if surface == "search":
                variables["params"]["browse_request_params"].update(
                    filter_location_latitude=lat, filter_location_longitude=lon,
                    commerce_enable_shipping=False)
            else:
                variables["buyLocation"] = {"latitude": lat, "longitude": lon}
            seen = set()
            for page in range(2 if surface == "search" else 1):
                fields = {"__user": "0", "av": "0", "__a": "1", "__comet_req": "15",
                          "fb_api_caller_class": "RelayModern", "fb_api_req_friendly_name": config["operation"],
                          "server_timestamps": "true", "doc_id": config["doc_id"], "variables": json.dumps(variables)}
                request = urllib.request.Request("https://www.facebook.com/api/graphql/",
                    data=urllib.parse.urlencode(fields).encode(),
                    headers={"User-Agent": "OpenMarket/0.0.1 (iOS)",
                             "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"})
                with opener.open(request, timeout=20) as response:
                    raw = response.read()
                if args.raw_dir:
                    (args.raw_dir / f"{country}-{surface}-{page}.json").write_bytes(raw)
                summary, cards, info = feed.summarize(raw, seen)
                summary.update(surface=surface, page=page,
                    prices=list({json.dumps(c.get("listing_price"), sort_keys=True): c.get("listing_price") for c in cards.values()}.values())[:3])
                general = [o["data"]["price"] for line in raw.decode().removeprefix("for (;;);").splitlines()
                           for o in feed.walk(json.loads(line))
                           if o.get("__typename") == "MarketplaceFeedGeneralListingObject"]
                if general:
                    summary["general_listing_prices"] = general[:3]
                market["pages"].append(summary)
                args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
                print(json.dumps({"country": country, "surface": surface, "page": page,
                                  "listings": len(cards), "errors": summary["errors"],
                                  "price_samples": summary["prices"][:3]}, ensure_ascii=False), flush=True)
                if summary["errors"]:
                    raise RuntimeError("GraphQL error; stopped without retry")
                if not info or not info.get("has_next_page"):
                    break
                cursor = info.get("end_cursor")
                if not cursor or cursor == variables["cursor"]:
                    raise RuntimeError("Missing or repeated cursor")
                variables["cursor"] = cursor
                seen.update(cards)
                time.sleep(0.5)
            time.sleep(0.5)


if __name__ == "__main__":
    main()
