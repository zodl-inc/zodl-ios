#!/usr/bin/env python3
"""Helper for the `update-whatsnew` skill.

Handles the deterministic, error-prone parts of preparing a release changelog so
the model only has to do the part it is good at: turning the freeform,
multi-language changelog into structured sections. Keeping the file edit in a
script (rather than hand-editing JSON) guarantees valid output and a minimal,
review-friendly diff every single time.

Subcommands
-----------
add       Write the release entry into a whatsNew file. If the version is not in
          the file yet it is prepended to the top of the `releases` array; if an
          entry for that version already exists it is REPLACED in place. Either
          way the edit is a pure textual splice: every other line stays
          byte-for-byte unchanged, so the release diff stays clean. On a replace
          the existing entry's `date`/`timestamp` are kept (pass --refresh-date
          to take them from the payload instead), and re-rendering an entry whose
          content did not change produces no write at all.
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

# Exit code used when the file cannot be updated at all (bad input, bad file).
EXIT_ERROR = 2


def fail(msg, code=EXIT_ERROR):
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


def render_lines(payload, indent=8):
    """Render the release object as text lines indented to match the file.

    json.dumps(indent=4) gives 4-space steps; prefixing every line with 8 spaces
    lands the object brace at column 8 and its fields at 12, which is exactly how
    the existing entries are laid out. ensure_ascii=False keeps accented
    characters literal (matching the Spanish file)."""
    pretty = json.dumps(release_object(payload), ensure_ascii=False, indent=4)
    pad = " " * indent
    return [pad + line for line in pretty.split("\n")]


def render_spliced(payload, indent=8):
    """Same rendering, but with the opening brace's indent left off.

    Used when replacing an entry in place: the file already holds the whitespace
    that precedes the entry's `{`, so re-emitting it would double the indent."""
    lines = render_lines(payload, indent)
    lines[0] = lines[0][indent:]
    return "\n".join(lines)


def skeleton():
    return '{\n    "releases": [\n    ]\n}\n'


def array_bracket_pos(text, path):
    """Character offset of the `[` that opens the top-level `releases` array."""
    header = text.find(RELEASES_HEADER)
    if header == -1:
        fail(f"could not find a `{RELEASES_HEADER}` line in {path!r}")
    return header + len(RELEASES_HEADER) - 1


def element_spans(text, bracket_pos):
    """Character spans of each element of the array whose `[` is at bracket_pos.

    Returns a list of (start, end) offsets, end exclusive, where start is the
    element's first character and end is just past its last — so the comma and
    newline that follow an element are NOT part of its span and survive a splice
    untouched. String contents are skipped, so braces inside a bullet's text
    cannot throw the depth count off."""
    spans = []
    depth = 0
    start = None
    in_string = False
    escaped = False
    i = bracket_pos + 1
    while i < len(text):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
                if depth == 0 and start is not None:
                    # A bare string element (not used by these files, but keep
                    # the scanner honest rather than silently mis-parsing).
                    spans.append((start, i + 1))
                    start = None
            i += 1
            continue
        if ch == '"':
            in_string = True
            if depth == 0 and start is None:
                start = i
        elif ch in "{[":
            if depth == 0 and start is None:
                start = i
            depth += 1
        elif ch in "}]":
            if depth == 0:
                break  # the `]` closing the releases array
            depth -= 1
            if depth == 0 and start is not None:
                spans.append((start, i + 1))
                start = None
        i += 1
    return spans


def insert_text(text, payload, path, needs_comma):
    """Prepend the entry right after the `"releases": [` line."""
    lines = text.split("\n")
    header_idx = next(
        (i for i, line in enumerate(lines) if line.strip() == RELEASES_HEADER),
        None,
    )
    if header_idx is None:
        fail(f"could not find a `{RELEASES_HEADER}` line in {path!r}")

    block = render_lines(payload)
    if needs_comma:  # not the only entry -> needs a comma before the next one
        block[-1] += ","
    return "\n".join(lines[:header_idx + 1] + block + lines[header_idx + 1:])


def replace_text(text, payload, path, releases, idx):
    """Splice the entry at index `idx` in place, leaving every other byte alone.

    Returns (new_text, old_entry_text, new_entry_text)."""
    spans = element_spans(text, array_bracket_pos(text, path))
    if len(spans) != len(releases):
        fail(f"internal error: found {len(spans)} release blocks in {path!r} but "
             f"the parsed JSON has {len(releases)}; {path} left unchanged")
    start, end = spans[idx]
    entry_text = render_spliced(payload)
    return text[:start] + entry_text + text[end:], text[start:end], entry_text


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

    idx = next(
        (i for i, r in enumerate(releases) if r.get("version") == version),
        None,
    )

    notes = []
    if idx is None:
        action = "create + add" if not existed else "add"
        new_text = insert_text(text, payload, args.file, bool(releases))
        unchanged = False
    else:
        action = "replace"
        # An existing entry keeps the date/timestamp it was first written with,
        # so amending a release's notes doesn't make it look re-released. The
        # payload's values are used only when --refresh-date is passed.
        existing = releases[idx]
        if args.refresh_date:
            notes.append(f"date/timestamp refreshed to {payload['date']} / "
                         f"{payload['timestamp']}")
        else:
            if existing.get("date"):
                payload["date"] = existing["date"]
            if existing.get("timestamp") not in (None, ""):
                payload["timestamp"] = existing["timestamp"]
            notes.append(f"kept existing date/timestamp {payload['date']} / "
                         f"{payload['timestamp']}")
        if idx != 0:
            notes.append(f"NOTE: it is entry #{idx + 1}, not the newest — "
                         f"replaced in place, not moved to the top")
        new_text, old_entry, new_entry = replace_text(
            text, payload, args.file, releases, idx
        )
        unchanged = old_entry == new_entry

    suffix = f" ({'; '.join(notes)})" if notes else ""

    if unchanged:
        print(f"Unchanged: version {version} in {args.file} already matches the "
              f"payload — nothing written.{suffix}")
        return

    if args.dry_run:
        print(f"OK: would {action} version {version} in {args.file} "
              f"(date {payload['date']}, timestamp {payload['timestamp']}, "
              f"{len(payload['sections'])} section(s)).{suffix}")
        return

    try:
        json.loads(new_text)
    except json.JSONDecodeError as exc:
        fail(f"internal error: {action} produced invalid JSON ({exc}); "
             f"{args.file} left unchanged")

    with open(args.file, "w", encoding="utf-8") as f:
        f.write(new_text)

    verb = {
        "create + add": "Created and added",
        "add": "Added",
        "replace": "Replaced",
    }[action]
    print(f"{verb} version {version} in {args.file} "
          f"(date {payload['date']}, timestamp {payload['timestamp']}).{suffix}")


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

    p_add = sub.add_parser("add", help="add or replace a release entry in a whatsNew file")
    p_add.add_argument("--file", required=True, help="path to whatsNew*.json")
    p_add.add_argument("--payload", required=True, help="path to the language payload JSON")
    p_add.add_argument("--create", action="store_true",
                       help="create the file (new language) if it does not exist")
    p_add.add_argument("--refresh-date", action="store_true",
                       help="when replacing, use the payload's date/timestamp "
                            "instead of keeping the existing entry's")
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
