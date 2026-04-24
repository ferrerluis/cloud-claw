#!/usr/bin/env python3
"""Resolve a DigitalOcean volume name to its volume ID."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from typing import Any


API_ROOT = "https://api.digitalocean.com/v2/volumes"


def fail(message: str) -> int:
    print(f"error: {message}", file=sys.stderr)
    return 1


def fetch_page(token: str, url: str) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(request) as response:
        payload = json.load(response)
    if not isinstance(payload, dict):
        raise ValueError("DigitalOcean API returned a non-object response")
    return payload


def collect_volumes(token: str) -> list[dict[str, Any]]:
    url = f"{API_ROOT}?per_page=200"
    volumes: list[dict[str, Any]] = []
    while url:
        payload = fetch_page(token, url)
        page_items = payload.get("volumes", [])
        if not isinstance(page_items, list):
            raise ValueError("DigitalOcean API returned an invalid volumes list")
        volumes.extend(item for item in page_items if isinstance(item, dict))
        links = payload.get("links", {})
        pages = links.get("pages", {}) if isinstance(links, dict) else {}
        next_url = pages.get("next") if isinstance(pages, dict) else None
        url = next_url if isinstance(next_url, str) and next_url else ""
    return volumes


def select_volume(volumes: list[dict[str, Any]], name: str, region: str | None) -> dict[str, Any]:
    matches = [item for item in volumes if item.get("name") == name]
    if region:
        filtered: list[dict[str, Any]] = []
        for item in matches:
            region_info = item.get("region")
            if isinstance(region_info, dict) and region_info.get("slug") == region:
                filtered.append(item)
        matches = filtered

    if not matches:
        region_note = f" in region {region}" if region else ""
        raise ValueError(f"no DigitalOcean volume named {name!r}{region_note} was found")
    if len(matches) > 1:
        raise ValueError(
            f"multiple DigitalOcean volumes named {name!r} matched; rerun with --region to disambiguate"
        )
    return matches[0]


def format_volume(volume: dict[str, Any]) -> dict[str, str]:
    region = volume.get("region", {})
    region_slug = region.get("slug", "") if isinstance(region, dict) else ""
    return {
        "id": str(volume.get("id", "")),
        "name": str(volume.get("name", "")),
        "region": region_slug,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True, help="DigitalOcean volume name to look up")
    parser.add_argument("--token", help="DigitalOcean API token (defaults to DIGITALOCEAN_TOKEN)")
    parser.add_argument("--region", help="Optional region slug to disambiguate duplicate volume names")
    parser.add_argument(
        "--field",
        choices=["id", "name", "region", "json"],
        default="json",
        help="Output format (default: json)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    token = args.token or os.environ.get("DIGITALOCEAN_TOKEN", "")
    if not token:
        return fail("DigitalOcean token is required; pass --token or set DIGITALOCEAN_TOKEN")

    try:
        volume = select_volume(collect_volumes(token), args.name, args.region)
    except Exception as exc:  # noqa: BLE001 - CLI helper should turn lookup failures into clean stderr
        return fail(str(exc))

    formatted = format_volume(volume)
    if args.field == "json":
        print(json.dumps(formatted, sort_keys=True))
    else:
        print(formatted[args.field])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
