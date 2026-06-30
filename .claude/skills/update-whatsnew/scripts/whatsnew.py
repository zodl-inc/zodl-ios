#!/usr/bin/env python3
"""Helper for the `update-whatsnew` skill.

Handles the deterministic, error-prone parts of preparing a release changelog so
the model only has to do the part it is good at: turning the freeform,
multi-language changelog into structured sections. Keeping the file edit in a
script (rather than hand-editing JSON) guarantees valid output and a minimal,
review-friendly diff every single time.

Subcommands
-----------
add       Prepend a new release entry to the top of a whatsNew file's `releases`
          array. The edit is a pure textual insert: every existing line is left
          byte-for-byte unchanged and only the new lines are added, so the
          release diff stays clean. Aborts WITHOUT writing if an entry for the
          same version already exists (the skill's "stop and warn" policy).
appstore  Print the App Store changelog text for a payload (one language).

Payload schema (JSON, one object per language)
----------------------------------------------
{
  "version":   "3.8.0",
  "date":      "30-06-2026",       # DD-MM-YYYY  (optional -> today, local time)
  "timestamp": 1782211565,          # Unix epoch seconds (optional -> now)
  "sections": [
    {"title": "Added:",   "bulletpoints": ["First item.", "Second item."]},
    {"title": "Changed:", "bulletpoints": ["..."]}
  ]
}

The `title` is taken verbatim from the input for that language (e.g. "Added:" in
English, "Añadido:" in Spanish) — this script never translates anything.
"""

import argparse
import datetime
import json
import sys
import time

RELEASES_HEADER = '"releases": ['


def fail(msg, code=2):
    sys.stderr.write(f"error: {msg}\n")
    sys.exit(code)


def load_payload(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            payload = json.load(f)
    except FileNotFoundError:
        fail(f"payload file not found: {path!r}")
    except json.JSONDecodeError as exc:
        fail(f"payload {path!r} is not valid JSON: {exc}")

    if not payload.get("version"):
        fail(f"payload {path!r} is missing a non-empty \"version\"")
    sections = payload.get("sections")
    if not isinstance(sections, list) or not sections:
        fail(f"payload {path!r} must have a non-empty \"sections\" array")
    for i, section in enumerate(sections):
        if not section.get("title"):
            fail(f"section #{i} in {path!r} is missing a \"title\"")
        bullets = section.get("bulletpoints")
        if not isinstance(bullets, list) or not bullets:
            fail(f"section {section.get('title')!r} in {path!r} has no bulletpoints")

    # Default date/timestamp to "today / now" so a caller can omit them, but the
    # skill is expected to pass identical explicit values across every language
    # of the same release.
    if not payload.get("date"):
        payload["date"] = datetime.datetime.now().strftime("%d-%m-%Y")
    if payload.get("timestamp") in (None, ""):
        payload["timestamp"] = int(time.time())
    return payload


def release_object(payload):
    """Build the release dict with keys in the canonical on-disk order."""
    return {
        "version": payload["version"],
        "date": payload["date"],
        "timestamp": int(payload["timestamp"]),
        "sections": [
            {"title": s["title"], "bulletpoints": list(s["bulletpoints"])}
            for s in payload["sections"]
        ],
    }


def render_block(payload, indent=8):
    """Render the release object as text, indented to match the file (8 spaces).

    json.dumps(indent=4) gives 4-space steps; prefixing every line with 8 spaces
    lands the object brace at column 8 and its fields at 12, which is exactly how
    the existing entries are laid out. ensure_ascii=False keeps accented
    characters literal (matching the Spanish file)."""
    pretty = json.dumps(release_object(payload), ensure_ascii=False, indent=4)
    pad = " " * indent
    return [pad + line for line in pretty.split("\n")]


def skeleton():
    return '{\n    "releases": [\n    ]\n}\n'


def cmd_add(args):
    payload = load_payload(args.payload)
    version = payload["version"]

    try:
        with open(args.file, "r", encoding="utf-8") as f:
            text = f.read()
        existed = True
    except FileNotFoundError:
        if not args.create:
            fail(f"{args.file!r} does not exist. For a new language, confirm the "
                 f"filename first, then pass --create.")
        text = skeleton()
        existed = False

    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        fail(f"{args.file!r} is not valid JSON: {exc}")

    releases = data.get("releases")
    if not isinstance(releases, list):
        fail(f"{args.file!r} has no top-level \"releases\" array")

    if any(r.get("version") == version for r in releases):
        sys.stderr.write(
            f"version {version} already has an entry in {args.file} — not "
            f"modifying it. (Re-run policy: stop and warn.)\n"
        )
        sys.exit(3)

    lines = text.split("\n")
    header_idx = next(
        (i for i, line in enumerate(lines) if line.strip() == RELEASES_HEADER),
        None,
    )
    if header_idx is None:
        fail(f"could not find a `{RELEASES_HEADER}` line in {args.file!r}")

    block_lines = render_block(payload)
    if releases:  # not the first entry -> needs a comma before the next one
        block_lines[-1] += ","

    if args.dry_run:
        verb = "create + add" if not existed else "add"
        print(f"OK: would {verb} version {version} to {args.file} "
              f"(date {payload['date']}, timestamp {payload['timestamp']}, "
              f"{len(payload['sections'])} section(s)).")
        return

    new_text = "\n".join(lines[:header_idx + 1] + block_lines + lines[header_idx + 1:])

    try:
        json.loads(new_text)
    except json.JSONDecodeError as exc:
        fail(f"internal error: insertion produced invalid JSON ({exc}); "
             f"{args.file} left unchanged")

    with open(args.file, "w", encoding="utf-8") as f:
        f.write(new_text)

    verb = "Created and added" if not existed else "Added"
    print(f"{verb} version {version} to {args.file} "
          f"(date {payload['date']}, timestamp {payload['timestamp']}).")


def cmd_appstore(args):
    payload = load_payload(args.payload)
    blocks = []
    for section in payload["sections"]:
        block = [section["title"]] + [f"* {bp}" for bp in section["bulletpoints"]]
        blocks.append("\n".join(block))
    print("\n\n".join(blocks))


def main():
    parser = argparse.ArgumentParser(description="update-whatsnew helper")
    sub = parser.add_subparsers(dest="command", required=True)

    p_add = sub.add_parser("add", help="prepend a release entry to a whatsNew file")
    p_add.add_argument("--file", required=True, help="path to whatsNew*.json")
    p_add.add_argument("--payload", required=True, help="path to the language payload JSON")
    p_add.add_argument("--create", action="store_true",
                       help="create the file (new language) if it does not exist")
    p_add.add_argument("--dry-run", action="store_true",
                       help="validate and report what would happen, but do not write")
    p_add.set_defaults(func=cmd_add)

    p_as = sub.add_parser("appstore", help="print the App Store changelog text")
    p_as.add_argument("--payload", required=True, help="path to the language payload JSON")
    p_as.set_defaults(func=cmd_appstore)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
