#!/usr/bin/env python3
"""Fail when an emoji appears in UI, documentation, or marketing assets.

The product uses Lucide SVG icons. Emoji are not allowed in these paths; a
release should not depend on how a particular OS renders a pictograph.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET_DIRS = ("docs", "assets")
TARGET_FILES = ("README.md", "index.html")
EXTENSIONS = (".md", ".html", ".vue", ".ts")
SKIP_DIRS = {"node_modules", ".git", "dist", "logs", "data"}

EMOJI = re.compile(
    "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U00002B00-\U00002BFF"
    "\U0001F1E6-\U0001F1FF\uFE0F\u200D]"
)


def iter_files():
    for rel in TARGET_FILES:
        path = os.path.join(ROOT, rel)
        if os.path.isfile(path):
            yield path
    for rel in TARGET_DIRS:
        base = os.path.join(ROOT, rel)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                if name.endswith(EXTENSIONS):
                    yield os.path.join(dirpath, name)


def main():
    failures = []
    for path in iter_files():
        try:
            text = open(path, "r", encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            if EMOJI.search(line):
                failures.append((os.path.relpath(path, ROOT), lineno, line.strip()[:160]))

    if failures:
        print("Emoji found. Use a Lucide icon or plain text instead:")
        for path, lineno, line in failures:
            print("  %s:%d  %s" % (path, lineno, line))
        return 1

    print("No emoji in UI, documentation, or marketing assets.")
    return 0


if __name__ == "__main__":
    sys.exit(main())