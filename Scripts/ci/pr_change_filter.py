#!/usr/bin/env python3
"""Skip expensive PR work only for a complete, unchanged docs-only diff."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any, Callable
import urllib.error
import urllib.parse
import urllib.request


class ClassificationError(Exception):
    """The PR diff could not be classified safely."""


_SDK_PATHS = {
    ".github/PULL_REQUEST_TEMPLATE.md", "README.md", "CHANGELOG.md",
    "CONTRIBUTING.md", "responsible_disclosure.md", "SECURITY.md", "SWIFTLINT.md",
}
_LICENSE_PATHS = {"LICENSE", "LICENSE-MIT", "LICENSE-EXCEPTIONS.md", "COMMERCIAL-LICENSE.md"}
_PROFILES = {
    "app": {".github/pull_request_template.md", "LICENSE", "README.md"},
    "sdk-build": _SDK_PATHS,
    "sdk-proto": _SDK_PATHS | _LICENSE_PATHS,
}


def _validate_path(path: str) -> None:
    if (not isinstance(path, str) or not path or "\x00" in path or "\\" in path
            or any(part in ("", ".", "..") for part in path.split("/"))):
        raise ClassificationError("Invalid changed path")


def is_ignored_path(path: str, profile: str) -> bool:
    if profile not in _PROFILES:
        raise ClassificationError("Unknown classification profile")
    _validate_path(path)
    template = path.startswith(".github/ISSUE_TEMPLATE/") and len(path.split("/")) == 3
    return path in _PROFILES[profile] or path.startswith("docs/") or template


def requires_ci(changes: list[dict], profile: str) -> bool:
    if profile not in _PROFILES or not isinstance(changes, list):
        raise ClassificationError("Invalid change list or profile")
    run_ci = not changes
    for change in changes:
        if not isinstance(change, dict) or "filename" not in change or "status" not in change:
            raise ClassificationError("Invalid changed file")
        ignored = is_ignored_path(change["filename"], profile)
        status = change["status"]
        if status not in ("added", "removed", "modified", "renamed"):
            run_ci = True
        if "previous_filename" in change:
            ignored = is_ignored_path(change["previous_filename"], profile) and ignored
        elif status == "renamed":
            run_ci = True
        run_ci = run_ci or not ignored
    return run_ci


def _identity(pr: dict, number: int) -> tuple[str, str]:
    if not isinstance(pr, dict) or type(pr.get("number")) is not int or pr["number"] != number:
        raise ClassificationError("Invalid PR metadata")
    shas = []
    for side in ("head", "base"):
        value = pr.get(side)
        sha = value.get("sha") if isinstance(value, dict) else None
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", sha):
            raise ClassificationError("Invalid PR revision")
        shas.append(sha)
    return tuple(shas)


def _changed_count(pr: dict) -> int:
    count = pr.get("changed_files")
    if type(count) is not int or count < 0:
        raise ClassificationError("Invalid PR file count")
    return count


def classify_pull_request(event: dict, repository: str, profile: str,
                          api_get: Callable[[str], Any]) -> bool:
    if profile not in _PROFILES or not isinstance(repository, str) or not re.fullmatch(
            r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or any(
                part in (".", "..") for part in repository.split("/")):
        raise ClassificationError("Invalid repository or profile")
    if not isinstance(event, dict) or not isinstance(event.get("repository"), dict):
        raise ClassificationError("Invalid event")
    if event["repository"].get("full_name") != repository:
        raise ClassificationError("Event repository mismatch")
    number = event.get("number")
    if type(number) is not int or number <= 0:
        raise ClassificationError("Invalid PR number")
    expected = _identity(event.get("pull_request"), number)
    endpoint = f"/repos/{repository}/pulls/{number}"
    before = api_get(endpoint)
    if _identity(before, number) != expected:
        return True
    count = _changed_count(before)
    # GitHub truncates this endpoint at 3000 files. Never trust the cap.
    if count == 0 or count >= 3000:
        return True
    changes = []
    for page in range(1, (count + 99) // 100 + 1):
        rows = api_get(f"{endpoint}/files?per_page=100&page={page}")
        if not isinstance(rows, list):
            raise ClassificationError("Invalid PR files response")
        if len(rows) != min(100, count - len(changes)):
            return True
        changes.extend(rows)
    after = api_get(endpoint)
    if _identity(after, number) != expected or _changed_count(after) != count:
        return True
    run_ci = requires_ci(changes, profile)
    if len({change["filename"] for change in changes}) != count:
        return True
    return run_ci


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # In particular, never forward the token to an arbitrary redirect host.
        raise ClassificationError("GitHub API redirect refused")


def _api_get(path: str) -> Any:
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    parsed = urllib.parse.urlsplit(base)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.query or parsed.fragment or not path.startswith("/repos/")
            or any(part in (".", "..") for part in urllib.parse.urlsplit(path).path.split("/"))):
        raise ClassificationError("Invalid GitHub API endpoint")
    token = os.environ.get("GH_TOKEN")
    if not token:
        raise ClassificationError("Missing GitHub API token")
    request = urllib.request.Request(base + path, headers={
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    try:
        with urllib.request.build_opener(_NoRedirect()).open(request, timeout=30) as response:
            return json.load(response)
    except (OSError, ValueError, urllib.error.URLError) as error:
        raise ClassificationError("GitHub API request failed") from error


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=sorted(_PROFILES), required=True)
    parser.add_argument("--github-output", required=True)
    args = parser.parse_args(argv)
    try:
        if os.environ.get("GITHUB_EVENT_NAME") == "pull_request":
            with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as stream:
                event = json.load(stream)
            run_ci = classify_pull_request(event, os.environ["GITHUB_REPOSITORY"], args.profile, _api_get)
        else:
            run_ci = True
        with open(args.github_output, "a", encoding="utf-8") as stream:
            stream.write("run_ci=" + str(run_ci).lower() + "\n")
    except (ClassificationError, OSError, ValueError, KeyError):
        print("Unable to classify PR changes safely", file=sys.stderr)
        return 1
    print("CI required" if run_ci else "Complete docs-only PR")
    return 0


if __name__ == "__main__":
    sys.exit(main())
