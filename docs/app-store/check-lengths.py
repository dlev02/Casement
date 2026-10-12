#!/usr/bin/env python3
"""Counts the App Store metadata fields against Apple's limits.

Usage: python3 -I docs/app-store/check-lengths.py
Apple counts characters for name, subtitle, promotional text, and description, and bytes
(UTF-8) for keywords and review notes. This reads the canonical asc files plus the review notes.
"""
import json
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent
app_info = json.loads((root / "metadata/app-info/en-US.json").read_text())
version = json.loads((root / "metadata/version/1.0/en-US.json").read_text())

limits = [
    ("name", app_info["name"], 30, "chars"),
    ("subtitle", app_info["subtitle"], 30, "chars"),
    ("promotionalText", version["promotionalText"], 170, "chars"),
    ("description", version["description"], 4000, "chars"),
    ("keywords", version["keywords"], 100, "bytes"),
]

# Alternative subtitles and What's New live in metadata.md; keep them here so they're counted too.
extra = {
    "alt subtitle 1": "Your Mac & PC, privately",
    "alt subtitle 2": "Private access to Mac & PC",
    "whatsNew (1.0.1+)": "Welcome to Casement. Control your Mac or Windows PC from iPhone, iPad, Mac, and Apple Vision Pro, privately over your own Tailscale network.",
}
for label, text in extra.items():
    limit = 4000 if label.startswith("whatsNew") else 30
    limits.append((label, text, limit, "chars"))

notes_md = (root / "app-review.md").read_text()
match = re.search(r"<!-- notes:start -->\n```text\n(.*?)```\n<!-- notes:end -->", notes_md, re.S)
if match:
    limits.append(("review notes", match.group(1).rstrip("\n"), 4000, "bytes"))

failed = False
for label, text, limit, unit in limits:
    size = len(text.encode("utf-8")) if unit == "bytes" else len(text)
    ok = size <= limit
    failed |= not ok
    print(f"{'OK ' if ok else 'OVER'} {label:20} {size:5} / {limit} {unit}")

# Keyword hygiene: no spaces after commas, no repeats of name/subtitle words, no short or duplicate terms.
keywords = version["keywords"].split(",")
taken = set(re.findall(r"[a-z]+", (app_info["name"] + " " + app_info["subtitle"]).lower()))
problems = [k for k in keywords if k != k.strip()]
problems += [k for k in keywords if set(re.findall(r"[a-z]+", k.lower())) & taken]
problems += [k for k in keywords if len(k) < 3]
problems += [k for k in set(keywords) if keywords.count(k) > 1]
print("keyword issues:", problems or "none", f"({len(keywords)} terms)")
sys.exit(1 if failed or problems else 0)
