---
name: update-whatsnew
description: Prepare a Zodl release changelog. Reads the version from the zodl-production target, prepends a new release entry to every whatsNew*.json file (one per language), and prints the App Store changelog text for each language. Manual only — invoke with /update-whatsnew and paste the multi-language changelog.
disable-model-invocation: true
argument-hint: <paste the multi-language changelog (language blocks with Added/Changed/Fixed sections)>
---

# Update What's New + App Store changelog

Turn a freeform, multi-language release changelog into two things:

1. **Updated `whatsNew*.json` files** — one file per language, each with a new
   release entry prepended to the top of its `releases` array.
2. **App Store changelog text** — one ready-to-paste block per language, printed
   in the chat.

You do the part that needs judgment: reading the messy, multi-language input and
splitting it into clean structured sections. A bundled script
(`scripts/whatsnew.py`) does the mechanical part — inserting into the JSON and
rendering the App Store text — so the file edit is always valid JSON and a
minimal, review-friendly diff (existing entries are never reformatted).

This skill is manual only. Run it when a release is being cut.

## The input

The changelog arrives as the command argument (substituted below) or in the
user's message:

ARGUMENTS: $ARGUMENTS

It is one block per language. Each block starts with a language name
(`English`, `Español`, …) and contains sections — a short header line ending in
`:` (`Added:`, `Changed:`, `Fixed:`, `Removed:`, and their localized forms like
`Añadido:`, `Cambiado:`, `Corregido:`) followed by one or more items.

The shape is **not** rigid. Expect variation between releases: blank lines
between items, an optional leading `-`, `*`, `•`, or `–` on each item, extra
spacing. Read it for meaning rather than matching an exact pattern. If the
changelog isn't in the argument or the message, ask the user to paste it.

## Workflow

### 1. Read the release version

Read `MARKETING_VERSION` from the **zodl-production** target (this is what ships
to the App Store). It takes ~20s — that's normal:

```bash
xcodebuild -project secant.xcodeproj -target zodl-production \
  -showBuildSettings -configuration Release-AppStore 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}'
```

Fallback if `xcodebuild` is unavailable (every target is kept on the same
version, so this is reliable in practice, just not target-specific):

```bash
grep -m1 'MARKETING_VERSION' secant.xcodeproj/project.pbxproj | sed 's/.*= *//; s/;.*//'
```

### 2. Determine date and timestamp — once, shared by all languages

```bash
date +%d-%m-%Y   # e.g. 23-06-2026  (DD-MM-YYYY — matches recent entries)
date +%s         # e.g. 1782211565  (Unix epoch seconds)
```

Use the **same** version, date, and timestamp for every language — it's one
release.

### 3. Parse the changelog into one payload per language

For each language block, build a payload JSON file (write it to a temp path such
as `/tmp/whatsnew-<lang>.json` — using the file write tool avoids shell-escaping
problems with quotes, apostrophes, and accents):

```json
{
  "version": "<from step 1>",
  "date": "<from step 2>",
  "timestamp": <from step 2>,
  "sections": [
    { "title": "Added:", "bulletpoints": ["First item.", "Second item."] },
    { "title": "Changed:", "bulletpoints": ["..."] }
  ]
}
```

Rules:

- **Keep the section title verbatim**, including the trailing colon, in that
  language (`Added:`, `Añadido:`, …). Never translate — the input is already
  localized.
- **Preserve section order** as given.
- **One clean string per item.** Strip a leading bullet marker (`-`, `*`, `•`,
  `–`) and surrounding whitespace. Items are normally separated by blank lines.
- Map each language to its file (see the table below). If a block has no
  language header and there's only one block, ask the user which language it is
  rather than guessing.

### 4. Pre-flight — dry-run every target file

Before touching anything, dry-run each file so the whole operation is atomic:

```bash
python3 .claude/skills/update-whatsnew/scripts/whatsnew.py add \
  --file <whatsNew file> --payload <temp payload> --dry-run
```

- **Exit 3 = a version entry already exists.** Per policy: **stop and warn the
  user, and change nothing** — not this file and not the others. (This is the
  normal guard against re-running for a version that's already in the files.)
- **A language with no file yet** is a new language. Do **not** guess the
  filename. Ask the user to confirm the name (suggest `whatsNew_<code>.json`
  with the ISO 639-1 code, e.g. German → `whatsNew_de.json`), then plan to pass
  `--create` for that file in step 5.

Only continue once every dry-run is OK.

### 5. Apply — prepend the entries

```bash
python3 .claude/skills/update-whatsnew/scripts/whatsnew.py add \
  --file <whatsNew file> --payload <temp payload>
```

Add `--create` **only** for the new-language file the user confirmed in step 4.

### 6. Produce the App Store text

For each language:

```bash
python3 .claude/skills/update-whatsnew/scripts/whatsnew.py appstore \
  --payload <temp payload>
```

Present each language's output in its own labeled fenced code block so the user
can copy each one straight into App Store Connect.

### 7. Report

Summarize: the version, date, timestamp, and which files changed. Show the
inserted diff (`git diff -- secant/Resources/WhatsNew/`) so the user can confirm
only a new top entry was added and nothing else moved.

## Language → file mapping

| Language block | File |
|----------------|------|
| English | `secant/Resources/WhatsNew/whatsNew.json` |
| Español / Spanish | `secant/Resources/WhatsNew/whatsNew_es.json` |
| Any other language | `secant/Resources/WhatsNew/whatsNew_<ISO 639-1>.json` — **confirm the name with the user, then `--create`** |

English is the only language with no suffix. Every other language uses a
`_<code>` suffix.

## Invariants (why the script exists)

- **Newest entry on top; existing entries are never touched.** The script does a
  pure textual insert after the `"releases": [` line, so a release shows up as a
  small, obvious diff instead of a whole-file reformat.
- **Valid JSON, correct formatting, accents preserved** (8-space-indented entry,
  `ensure_ascii=False`). The script validates the result before writing.
- **One release = one shared version/date/timestamp across all languages.**
- Don't hand-edit the JSON files for this — let the script do it so every
  release is consistent.

## The helper script

`scripts/whatsnew.py` (Python 3, standard library only):

- `add --file F --payload P [--create] [--dry-run]` — prepend the release in `P`
  to `F`. Exits **3** without writing if that version already exists. `--create`
  makes a fresh `{ "releases": [] }` file for a new language. `--dry-run`
  validates and reports without writing.
- `appstore --payload P` — print the App Store changelog text for `P`.

Payload schema is shown in step 3; `date`/`timestamp` default to today/now if
omitted, but pass them explicitly so all languages match.
