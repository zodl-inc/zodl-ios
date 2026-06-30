#!/usr/bin/env python3
"""Helper for the `update-app-version` skill.

Sets MARKETING_VERSION (the App Store "marketing" version, e.g. 3.8.0) and
CURRENT_PROJECT_VERSION (the build number, e.g. 5) for every **non-test** target
in an Xcode project, across all of that target's build configurations.

Why a script (rather than hand-editing the pbxproj or shelling out to agvtool):

- **Correct target selection.** It reads the project's object graph with
  `plutil` (read-only, to stdout) to find which build configurations belong to
  non-test targets, so test bundles (unit/UI tests) are never touched and the
  set is future-proof if targets are added.
- **Minimal, review-friendly diff.** The edit is a pure textual replacement of
  just the `MARKETING_VERSION = ...;` / `CURRENT_PROJECT_VERSION = ...;` value
  lines inside those configurations. Every other byte of the pbxproj is left
  exactly as it was, so a version bump shows up as a handful of changed lines
  instead of a whole-file reformat.
- **Atomic and validated.** Either every targeted configuration is updated or
  nothing is written. The new file is `plutil -lint`-checked before it replaces
  the original, so a corrupt pbxproj can never land.

Subcommands
-----------
set   --marketing X --build N [--dry-run] [--project PATH]
      Set both versions for every non-test target. Aborts WITHOUT writing if a
      non-test configuration is missing one of the keys (anomaly to look at) or
      if the inputs are malformed.
show  [--project PATH]
      Print the current MARKETING_VERSION / CURRENT_PROJECT_VERSION for every
      non-test target configuration (used to read back / verify a change).

Exit codes
----------
0  success
2  usage / input / project-structure error
4  a non-test configuration is missing one of the version keys (nothing written)
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

PBXPROJ_RELATIVE = "project.pbxproj"

# Product types whose targets are test bundles — these are the targets we skip.
TEST_PRODUCT_TYPES = {
    "com.apple.product-type.bundle.unit-test",
    "com.apple.product-type.bundle.ui-testing",
}

MARKETING_KEY = "MARKETING_VERSION"
BUILD_KEY = "CURRENT_PROJECT_VERSION"

# Apple allows a marketing version of one to three dot-separated integers
# (e.g. "3", "3.8", "3.8.0"). The build number is a plain integer here.
MARKETING_RE = re.compile(r"^\d+(\.\d+){0,2}$")
BUILD_RE = re.compile(r"^\d+$")


def fail(msg, code=2):
    sys.stderr.write(f"error: {msg}\n")
    sys.exit(code)


def pbxproj_path(project):
    """Resolve the project argument to its project.pbxproj file."""
    if project.endswith(PBXPROJ_RELATIVE):
        path = project
    elif project.endswith(".xcodeproj"):
        path = os.path.join(project, PBXPROJ_RELATIVE)
    else:
        path = os.path.join(f"{project}.xcodeproj", PBXPROJ_RELATIVE)
    if not os.path.isfile(path):
        fail(f"could not find {PBXPROJ_RELATIVE} at {path!r}")
    return path


def load_graph(path):
    """Parse the pbxproj object graph as JSON, read-only, via plutil."""
    proc = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", path],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        fail(f"plutil could not read {path!r}: {proc.stderr.strip()}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        fail(f"plutil produced invalid JSON for {path!r}: {exc}")


def is_test_target(target):
    ptype = target.get("productType", "")
    return ptype in TEST_PRODUCT_TYPES or "test" in ptype.lower()


def non_test_configs(graph):
    """Map each non-test target's build-configuration UUID -> (target, config).

    Walks PBXNativeTarget -> buildConfigurationList -> buildConfigurations so the
    selection follows the project's real structure rather than guessing.
    """
    objs = graph.get("objects")
    if not isinstance(objs, dict):
        fail("project graph has no \"objects\" dictionary")

    configs = {}
    for target in objs.values():
        if target.get("isa") != "PBXNativeTarget" or is_test_target(target):
            continue
        name = target.get("name", "<unnamed target>")
        cfg_list = objs.get(target.get("buildConfigurationList"))
        if not cfg_list:
            continue
        for cfg_id in cfg_list.get("buildConfigurations", []):
            cfg = objs.get(cfg_id, {})
            configs[cfg_id] = (name, cfg.get("name", "<unnamed config>"))
    if not configs:
        fail("no non-test targets found in the project")
    return configs


def find_config_block(lines, uuid):
    """Return (start_idx, end_idx) of the XCBuildConfiguration object `uuid`.

    The start is the object's definition line (`<uuid> /* name */ = {`), not a
    reference to it elsewhere; the end is the object's own closing brace, found
    by matching the start line's indentation + `};` (the nested buildSettings
    dict closes at a deeper indent, so it is not mistaken for the end).
    """
    start_idx = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith(f"{uuid} ") and stripped.endswith("= {"):
            start_idx = i
            break
    if start_idx is None:
        fail(f"could not find configuration object {uuid} in the pbxproj")

    start_line = lines[start_idx]
    indent = start_line[: len(start_line) - len(start_line.lstrip("\t "))]
    closing = f"{indent}}};"
    for j in range(start_idx + 1, len(lines)):
        if lines[j] == closing:
            return start_idx, j
    fail(f"could not find the end of configuration object {uuid} in the pbxproj")


def replace_key_in_block(lines, start_idx, end_idx, key, new_value):
    """Replace `key = ...;` within [start_idx, end_idx]. Returns the old value
    (str) or None if the key was not present in the block."""
    pattern = re.compile(rf"^(\s*){re.escape(key)} = (.+);\s*$")
    for i in range(start_idx, end_idx + 1):
        m = pattern.match(lines[i])
        if m:
            old = m.group(2)
            lines[i] = f"{m.group(1)}{key} = {new_value};"
            return old
    return None


def cmd_show(args):
    path = pbxproj_path(args.project)
    graph = load_graph(path)
    configs = non_test_configs(graph)
    objs = graph["objects"]
    rows = []
    for cfg_id, (target, cfg_name) in configs.items():
        bs = objs[cfg_id].get("buildSettings", {})
        rows.append((target, cfg_name,
                     bs.get(MARKETING_KEY, "<missing>"),
                     bs.get(BUILD_KEY, "<missing>")))
    rows.sort()
    width = max(len(f"{t} / {c}") for t, c, _, _ in rows)
    print(f"{'TARGET / CONFIGURATION'.ljust(width)}  {MARKETING_KEY}  {BUILD_KEY}")
    for target, cfg_name, mv, cpv in rows:
        print(f"{f'{target} / {cfg_name}'.ljust(width)}  {mv}  {cpv}")


def cmd_set(args):
    marketing = args.marketing.strip()
    build = args.build.strip()
    if not MARKETING_RE.match(marketing):
        fail(f"marketing version {marketing!r} is not 1-3 dot-separated integers "
             f"(e.g. 3.8.0)")
    if not BUILD_RE.match(build):
        fail(f"build number {build!r} is not a non-negative integer (e.g. 5)")

    path = pbxproj_path(args.project)
    graph = load_graph(path)
    configs = non_test_configs(graph)
    objs = graph["objects"]

    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    lines = text.split("\n")

    # Pre-flight: confirm every targeted configuration carries both keys, and
    # collect old values, before changing anything (atomic-or-nothing).
    missing = []
    old_marketing = set()
    old_build = set()
    for cfg_id, (target, cfg_name) in configs.items():
        bs = objs[cfg_id].get("buildSettings", {})
        if MARKETING_KEY not in bs:
            missing.append((target, cfg_name, MARKETING_KEY))
        else:
            old_marketing.add(str(bs[MARKETING_KEY]))
        if BUILD_KEY not in bs:
            missing.append((target, cfg_name, BUILD_KEY))
        else:
            old_build.add(str(bs[BUILD_KEY]))
    if missing:
        detail = "\n".join(f"  - {t} / {c}: missing {k}" for t, c, k in missing)
        fail("some non-test configurations are missing a version key; nothing "
             f"was changed. Add the key in Xcode first, then re-run.\n{detail}",
             code=4)

    targets = sorted({t for t, _ in configs.values()})
    n = len(configs)
    print(f"{'DRY RUN — ' if args.dry_run else ''}"
          f"Setting versions for {len(targets)} non-test target(s) "
          f"({n} configuration(s)): {', '.join(targets)}")
    print(f"  {MARKETING_KEY}:       {' / '.join(sorted(old_marketing))} -> {marketing}")
    print(f"  {BUILD_KEY}: {' / '.join(sorted(old_build))} -> {build}")

    # Soft, non-blocking warning if the build number is not advancing.
    numeric_old = [int(v) for v in old_build if v.isdigit()]
    if numeric_old and int(build) <= max(numeric_old):
        sys.stderr.write(
            f"warning: new build number {build} is not greater than the current "
            f"{max(numeric_old)} — double-check this is intended.\n"
        )

    if args.dry_run:
        print("No changes written (dry run).")
        return

    for cfg_id in configs:
        start_idx, end_idx = find_config_block(lines, cfg_id)
        replace_key_in_block(lines, start_idx, end_idx, MARKETING_KEY, marketing)
        replace_key_in_block(lines, start_idx, end_idx, BUILD_KEY, build)

    new_text = "\n".join(lines)

    # Write atomically: validate the candidate file with plutil before it
    # replaces the original, so a malformed pbxproj can never be left behind.
    dir_name = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=dir_name, prefix=".pbxproj-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(new_text)
        lint = subprocess.run(["plutil", "-lint", tmp],
                              capture_output=True, text=True)
        if lint.returncode != 0:
            fail(f"internal error: edited pbxproj failed validation "
                 f"({lint.stdout.strip() or lint.stderr.strip()}); "
                 f"{path} left unchanged")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)

    print(f"Updated {path}")


def main():
    parser = argparse.ArgumentParser(description="update-app-version helper")
    sub = parser.add_subparsers(dest="command", required=True)

    p_set = sub.add_parser("set", help="set both versions for all non-test targets")
    p_set.add_argument("--marketing", required=True,
                       help="marketing version, e.g. 3.8.0")
    p_set.add_argument("--build", required=True,
                       help="build number, e.g. 5")
    p_set.add_argument("--project", default="secant",
                       help="path to .xcodeproj, its project.pbxproj, or the "
                            "project name (default: secant)")
    p_set.add_argument("--dry-run", action="store_true",
                       help="report what would change without writing")
    p_set.set_defaults(func=cmd_set)

    p_show = sub.add_parser("show", help="print current versions per non-test target")
    p_show.add_argument("--project", default="secant",
                        help="path to .xcodeproj, its project.pbxproj, or the "
                             "project name (default: secant)")
    p_show.set_defaults(func=cmd_show)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
