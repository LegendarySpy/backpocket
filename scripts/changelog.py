#!/usr/bin/env python3
"""Reads and stamps CHANGELOG.md for releases.

  changelog.py notes <version>   Release notes for <version>. Uses its section if it
                                 exists, otherwise the Unreleased section.
  changelog.py stamp <version>   Renames Unreleased to "<version> - <today>" and starts
                                 a new empty Unreleased section.
"""
import datetime
import pathlib
import re
import sys

PATH = pathlib.Path(__file__).resolve().parent.parent / "CHANGELOG.md"


def sections(text):
    """Heading title -> body, for every "## " section."""
    parts = re.split(r"^## (.+)$", text, flags=re.M)
    return {parts[i].strip(): parts[i + 1].strip() for i in range(1, len(parts), 2)}


def body_for(version, text):
    found = sections(text)
    for title, body in found.items():
        if title.split(" - ")[0].strip() == version:
            return body
    return found.get("Unreleased", "")


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("notes", "stamp"):
        sys.exit(__doc__)
    command, version = sys.argv[1], sys.argv[2]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        sys.exit(f"Version should look like 1.2.3, got {version!r}")
    text = PATH.read_text()

    if command == "notes":
        body = body_for(version, text)
        if not body:
            sys.exit(f"CHANGELOG.md has nothing under Unreleased or {version}. Add the changes first.")
        print(f"## What’s new in {version}\n\n{body}")
        return

    if any(title.split(" - ")[0].strip() == version for title in sections(text)):
        sys.exit(f"CHANGELOG.md already has a {version} section.")
    if not sections(text).get("Unreleased"):
        sys.exit("CHANGELOG.md has nothing under Unreleased.")
    today = datetime.date.today().isoformat()
    PATH.write_text(text.replace("## Unreleased", f"## Unreleased\n\n## {version} - {today}", 1))


if __name__ == "__main__":
    main()
