#!/usr/bin/env python3
"""Download a sample of classic Winamp skins and their reference screenshots
from the Winamp Skin Museum (https://skins.webamp.org) into .corpus/.

Screenshots are rendered by Webamp in a fixed "screenshot" state and serve as
golden images for SkinRenderer. Skins are user content, so the corpus is kept
out of git.

Usage: scripts/fetch_skin_corpus.py [--top N] [--sampled N] [--out DIR]
"""

import argparse
import json
import pathlib
import random
import sys
import time
import urllib.request

API = "https://api.webamp.org/graphql"
# The CDN rejects urllib's default User-Agent.
USER_AGENT = "hagtamp-corpus/1.0 (+https://github.com/captbaritone/webamp)"
# The API refuses to combine `sort` with `filter`: the museum order is used for
# the curated top, the APPROVED filter for the random sample.
TOP_QUERY = """query($first: Int, $offset: Int) {
  skins(first: $first, offset: $offset, sort: MUSEUM) {
    count
    nodes { md5 filename download_url screenshot_url }
  }
}"""
SAMPLE_QUERY = TOP_QUERY.replace("sort: MUSEUM", "filter: APPROVED")


def graphql(query, variables):
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(API, body, {"content-type": "application/json", "user-agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)["data"]["skins"]


def download(url, path):
    if path.exists() and path.stat().st_size > 0:
        return False
    req = urllib.request.Request(url, headers={"user-agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = resp.read()
    path.write_bytes(data)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--top", type=int, default=150, help="skins from the top of museum order")
    parser.add_argument("--sampled", type=int, default=150, help="skins sampled from the rest of the museum")
    parser.add_argument("--out", default=".corpus")
    parser.add_argument("--seed", type=int, default=91)
    args = parser.parse_args()

    out = pathlib.Path(args.out)
    (out / "skins").mkdir(parents=True, exist_ok=True)
    (out / "screenshots").mkdir(parents=True, exist_ok=True)

    nodes = []
    nodes += graphql(TOP_QUERY, {"first": args.top, "offset": 0})["nodes"]

    # Skins outside the curated top are more likely to be broken in interesting ways.
    total = graphql(SAMPLE_QUERY, {"first": 1, "offset": 0})["count"]
    rng = random.Random(args.seed)
    seen = {n["md5"] for n in nodes}
    for offset in sorted(rng.sample(range(total), args.sampled)):
        for node in graphql(SAMPLE_QUERY, {"first": 1, "offset": offset})["nodes"]:
            if node["md5"] not in seen:
                seen.add(node["md5"])
                nodes.append(node)

    manifest = []
    for i, node in enumerate(nodes):
        md5 = node["md5"]
        skin_path = out / "skins" / f"{md5}.wsz"
        shot_path = out / "screenshots" / f"{md5}.png"
        try:
            fetched = download(node["download_url"], skin_path)
            fetched |= download(node["screenshot_url"], shot_path)
        except Exception as e:  # noqa: BLE001 - keep going, report at the end
            print(f"[{i + 1}/{len(nodes)}] {md5} failed: {e}", file=sys.stderr)
            continue
        manifest.append({"md5": md5, "filename": node["filename"]})
        print(f"[{i + 1}/{len(nodes)}] {node['filename']}")
        if fetched:
            time.sleep(0.2)

    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"{len(manifest)} skins in {out}")


if __name__ == "__main__":
    main()
