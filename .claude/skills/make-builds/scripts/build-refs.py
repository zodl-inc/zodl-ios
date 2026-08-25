#!/usr/bin/env python3
"""Render the `App:` / `SDK:` lines for a make-builds Slack reply.

Both lines name the commit that was built and any tag pointing at it, so a
release announcement says which tagged version it corresponds to instead of a
bare sha.

The SDK line is *discovered from the Xcode project*, never hardcoded: the wallet
SDK may be consumed either as a local Swift package (a sibling checkout, read
live) or as a pinned remote package. The two are reported in the same shape:

    <branch-or-version>@<sha8>[ (tag: X)][ (dirty)]

Usage:
    build-refs.py --ref release/3.10.1 --sha 54812f81 [--repo /path/to/repo]

Prints one or two lines to stdout, ready to paste into the reply. The SDK line
is omitted entirely when no SDK reference can be resolved; the reason goes to
stderr so the caller can mention it in the final report. Exit 2 = error.
"""

import argparse
import json
import os
import re
import subprocess
import sys

# Matches the wallet SDK by name whichever repo/package name it currently uses
# (zodl-swift-wallet-sdk, zcash-swift-wallet-sdk, ZcashLightClientKit, …), so a
# rename does not silently drop the SDK line.
SDK_PATTERN = re.compile(r"wallet[-_]?sdk|zcashlightclientkit", re.IGNORECASE)

RESOLVED_REL = "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


def git(args, cwd, must_succeed=False):
    """Run git, returning stripped stdout ('' on failure unless must_succeed)."""
    try:
        proc = subprocess.run(
            ["git"] + args,
            cwd=cwd,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        if must_succeed:
            die(f"could not run git: {exc}")
        return ""
    if proc.returncode != 0:
        if must_succeed:
            die(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
        return ""
    return proc.stdout.strip()


def die(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(2)


def note(message):
    print(f"note: {message}", file=sys.stderr)


def decorate(base, tags, dirty=False):
    """`branch@sha (tag: X) (dirty)` — tag group first, then the dirty marker."""
    out = base
    if len(tags) == 1:
        out += f" (tag: {tags[0]})"
    elif len(tags) > 1:
        out += f" (tags: {', '.join(tags)})"
    if dirty:
        out += " (dirty)"
    return out


def tags_at(repo, rev):
    out = git(["tag", "--points-at", rev], cwd=repo)
    return [line.strip() for line in out.splitlines() if line.strip()]


def find_xcodeproj(repo):
    entries = sorted(e for e in os.listdir(repo) if e.endswith(".xcodeproj"))
    if not entries:
        return None
    return os.path.join(repo, entries[0])


def local_package_paths(pbxproj_text):
    """relativePath values of every XCLocalSwiftPackageReference in the project."""
    section = re.search(
        r"/\* Begin XCLocalSwiftPackageReference section \*/(.*?)"
        r"/\* End XCLocalSwiftPackageReference section \*/",
        pbxproj_text,
        re.DOTALL,
    )
    if not section:
        return []
    return re.findall(r'relativePath\s*=\s*"?([^";]+)"?\s*;', section.group(1))


def sdk_from_local(repo, project, pbxproj_text):
    """SDK state from a local package reference — the live sibling checkout.

    Returns the rendered string, None if the project declares no local SDK
    package (so the caller should look for a remote pin), or False if it
    declares one that cannot be read. False must not fall back to a remote pin:
    the build consumes the local checkout, so a pin would describe code that was
    not built.
    """
    paths = local_package_paths(pbxproj_text)
    if not paths:
        return None

    matches = [p for p in paths if SDK_PATTERN.search(p)]
    if not matches and len(paths) == 1:
        # One local package and no name match: this project has historically had
        # exactly one, the SDK. Use it rather than dropping the line.
        matches = paths
    if not matches:
        # Local packages exist but none is the SDK — it may legitimately be a
        # remote pin, so let the caller look.
        note(f"no local package matched the SDK name (found: {', '.join(paths)})")
        return None
    if len(matches) > 1:
        note(f"several local packages matched the SDK name: {', '.join(matches)}")
        return False

    rel = matches[0]
    # relativePath is relative to the .xcodeproj's directory, which is the repo
    # root here — and the build worktree is a sibling, so it resolves the same.
    resolved = os.path.normpath(os.path.join(os.path.dirname(project), rel))
    if not os.path.isdir(resolved):
        note(f"local package {rel} does not exist at {resolved}")
        return False

    head = git(["rev-parse", "--short=8", "HEAD"], cwd=resolved)
    if not head:
        note(f"local package {rel} at {resolved} is not a git checkout")
        return False

    branch = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd=resolved)
    dirty = bool(git(["status", "--porcelain"], cwd=resolved))
    # Detached HEAD reports "HEAD" as the branch name — show just the sha.
    base = head if branch in ("", "HEAD") else f"{branch}@{head}"
    return decorate(base, tags_at(resolved, "HEAD"), dirty)


def sdk_from_remote(project):
    """SDK state from a pinned remote package in Package.resolved.

    A pin has no working copy, so there is nothing to tag-lookup and nothing to
    be dirty: the pinned `version` *is* the tag, and is rendered in the branch
    slot so the line keeps the same `<something>@<sha8>` shape.
    """
    resolved_path = os.path.join(project, RESOLVED_REL)
    if not os.path.isfile(resolved_path):
        return None
    try:
        with open(resolved_path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        note(f"could not read {resolved_path}: {exc}")
        return None

    pins = [
        pin
        for pin in data.get("pins", [])
        if SDK_PATTERN.search(pin.get("identity", ""))
        or SDK_PATTERN.search(pin.get("location", ""))
    ]
    if not pins:
        return None
    if len(pins) > 1:
        note(
            "several remote pins matched the SDK name: "
            + ", ".join(p.get("identity", "?") for p in pins)
        )
        return None

    state = pins[0].get("state", {})
    revision = (state.get("revision") or "")[:8]
    label = state.get("version") or state.get("branch") or ""
    if not revision and not label:
        note(f"pin {pins[0].get('identity', '?')} has no revision or version")
        return None
    return f"{label}@{revision}" if label and revision else (label or revision)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", required=True, help="ref as given to the lane")
    parser.add_argument("--sha", required=True, help="sha8 the lane reported building")
    parser.add_argument("--repo", default=None, help="repo root (default: this repo)")
    args = parser.parse_args()

    repo = args.repo or git(
        ["rev-parse", "--show-toplevel"], cwd=os.getcwd(), must_succeed=True
    )
    if not os.path.isdir(repo):
        die(f"repo root not found: {repo}")

    print(f"App: `{decorate(f'{args.ref}@{args.sha}', tags_at(repo, args.sha))}`")

    project = find_xcodeproj(repo)
    if project is None:
        note(f"no .xcodeproj in {repo} — SDK line omitted")
        return
    try:
        with open(os.path.join(project, "project.pbxproj"), encoding="utf-8") as handle:
            pbxproj_text = handle.read()
    except OSError as exc:
        note(f"could not read the project file: {exc} — SDK line omitted")
        return

    local = sdk_from_local(repo, project, pbxproj_text)
    if local is False:
        note("the local SDK package could not be read — SDK line omitted")
        return
    sdk = local or sdk_from_remote(project)
    if sdk is None:
        note("no SDK package reference resolved — SDK line omitted")
        return
    print(f"SDK: `{sdk}`")


if __name__ == "__main__":
    main()
