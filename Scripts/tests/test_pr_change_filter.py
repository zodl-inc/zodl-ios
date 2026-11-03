"""Docs skips require a complete, immutable PR diff, never a best guess."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[1] / "ci/pr_change_filter.py"
spec = importlib.util.spec_from_file_location("pr_change_filter", HELPER)
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


def row(path="README.md", status="modified", **extra):
    return dict(filename=path, status=status, **extra)


def metadata(count=1):
    return {"number": 12, "changed_files": count,
            "head": {"sha": "a" * 40}, "base": {"sha": "b" * 40}}


def event(count=1):
    return {"number": 12, "repository": {"full_name": "owner/repo"},
            "pull_request": metadata(count)}


class FakeAPI:
    def __init__(self, pages=None, before=None, after=None):
        self.pages = pages if pages is not None else [[row()]]
        self.before = before if before is not None else metadata(sum(map(len, self.pages)))
        self.after = after if after is not None else self.before
        self.calls = []
        self.reads = 0

    def __call__(self, path):
        self.calls.append(path)
        if path == "/repos/owner/repo/pulls/12":
            value = self.before if self.reads == 0 else self.after
            self.reads += 1
        else:
            prefix = "/repos/owner/repo/pulls/12/files?per_page=100&page="
            if not path.startswith(prefix):
                raise AssertionError("Unexpected API request")
            value = self.pages[int(path[len(prefix):]) - 1]
        if isinstance(value, Exception):
            raise value
        return copy.deepcopy(value)


class PathTests(unittest.TestCase):
    def test_docs_only_skips_but_code_and_deleted_code_run(self):
        self.assertFalse(ci.requires_ci([row()], "sdk-build"))
        self.assertTrue(ci.requires_ci([row(), row("Cargo.lock")], "sdk-build"))
        self.assertTrue(ci.requires_ci([row("Sources/File.swift", "removed")], "sdk-build"))
        for path in ("Scripts/ci/pr_change_filter.py", ".github/workflows/swift.yml", "AGENTS.md"):
            for profile in ("app", "sdk-build", "sdk-proto"):
                self.assertTrue(ci.requires_ci([row(path)], profile))

    def test_license_profiles_preserve_build_difference(self):
        for path in ("LICENSE", "LICENSE-MIT", "LICENSE-EXCEPTIONS.md", "COMMERCIAL-LICENSE.md"):
            with self.subTest(path=path):
                self.assertTrue(ci.requires_ci([row(path)], "sdk-build"))
                self.assertFalse(ci.requires_ci([row(path)], "sdk-proto"))
        self.assertFalse(ci.requires_ci([row("LICENSE")], "app"))
        self.assertTrue(ci.requires_ci([row("CHANGELOG.md")], "app"))

    def test_renames_check_both_names(self):
        for new, old in (("docs/file.md", "Sources/file.swift"), ("Sources/file.swift", "docs/file.md")):
            self.assertTrue(ci.requires_ci([row(new, "renamed", previous_filename=old)], "sdk-build"))
        self.assertFalse(ci.requires_ci([row("docs/new.md", "renamed", previous_filename="README.md")], "sdk-build"))

    def test_case_single_segment_templates_and_unusual_names(self):
        for path, ignored in (("README.MD", False), ("Docs/a.md", False),
                              ("docs/deep/a.md", True), ("docs/a b\nc.md", True),
                              ("Sources/a b\nc.swift", False), (".github/ISSUE_TEMPLATE/a.md", True),
                              (".github/ISSUE_TEMPLATE/deep/a.md", False),
                              (".github/PULL_REQUEST_TEMPLATE.md", True),
                              (".github/pull_request_template.md", False)):
            with self.subTest(path=path):
                self.assertEqual(ignored, ci.is_ignored_path(path, "sdk-build"))
        self.assertTrue(ci.is_ignored_path(".github/pull_request_template.md", "app"))
        self.assertFalse(ci.is_ignored_path(".github/PULL_REQUEST_TEMPLATE.md", "app"))

    def test_empty_unknown_or_malformed_changes_never_skip(self):
        for changes in ([], [row(status="unknown")], [row(status="renamed")]):
            self.assertTrue(ci.requires_ci(changes, "sdk-build"))
        for changes in (None, {}, [None], [{}], [row(None)], [row("")],
                        [row("/docs/a")], [row("docs/../a")], [row("docs//a")],
                        [row("docs/a\x00b")], [row("docs/a", "renamed", previous_filename=2)]):
            with self.subTest(changes=changes):
                with self.assertRaises(ci.ClassificationError):
                    ci.requires_ci(changes, "sdk-build")
        with self.assertRaises(ci.ClassificationError):
            ci.is_ignored_path("README.md", "unknown")


class APITests(unittest.TestCase):
    def classify(self, api, payload=None):
        return ci.classify_pull_request(payload or event(), "owner/repo", "sdk-build", api)

    def test_complete_docs_only_skips_after_identity_recheck(self):
        api = FakeAPI()
        self.assertFalse(self.classify(api))
        self.assertEqual(["/repos/owner/repo/pulls/12", "/repos/owner/repo/pulls/12/files?per_page=100&page=1", "/repos/owner/repo/pulls/12"], api.calls)

    def test_second_page_code_requires_ci(self):
        api = FakeAPI([[row("docs/%d.md" % i) for i in range(100)], [row("Cargo.lock")]])
        self.assertTrue(self.classify(api, event(101)))
        self.assertIn("/repos/owner/repo/pulls/12/files?per_page=100&page=2", api.calls)

    def test_complete_two_pages_docs_can_skip(self):
        api = FakeAPI([[row("docs/%d.md" % i) for i in range(100)], [row("docs/last.md")]])
        self.assertFalse(self.classify(api, event(101)))

    def test_identity_mismatch_before_or_after_never_skips(self):
        for phase in ("before", "after"):
            for side in ("head", "base"):
                changed = metadata()
                changed[side]["sha"] = "c" * 40
                api = FakeAPI(**{phase: changed})
                self.assertTrue(self.classify(api))

    def test_counts_empty_duplicate_and_cap_never_skip(self):
        for api in (FakeAPI([], metadata(0)), FakeAPI([[row()]], metadata(2)),
                    FakeAPI([[row(), row()]], metadata(2)),
                    FakeAPI(before=metadata(3000)), FakeAPI(before=metadata(3001)),
                    FakeAPI(after=metadata(2))):
            with self.subTest(api=api):
                self.assertTrue(self.classify(api))

    def test_api_failures_and_malformed_payloads_fail_closed(self):
        for api in (FakeAPI(before=ci.ClassificationError("failed")),
                    FakeAPI([ci.ClassificationError("failed")], metadata()),
                    FakeAPI(after=ci.ClassificationError("failed")),
                    FakeAPI(before={}), FakeAPI(pages=[{}], before=metadata()),
                    FakeAPI(before=dict(metadata(), changed_files=True))):
            with self.subTest(api=api):
                with self.assertRaises(ci.ClassificationError):
                    self.classify(api)

    def test_invalid_repository_number_and_shas_rejected(self):
        for payload in (dict(event(), number=13), dict(event(), number=True),
                        dict(event(), repository={"full_name": "other/repo"})):
            with self.assertRaises(ci.ClassificationError):
                self.classify(FakeAPI(), payload)
        bad = event()
        bad["pull_request"]["head"]["sha"] = "bad"
        with self.assertRaises(ci.ClassificationError):
            self.classify(FakeAPI(), bad)
        with self.assertRaises(ci.ClassificationError):
            ci.classify_pull_request(event(), "../repo", "sdk-build", FakeAPI())


class CLITests(unittest.TestCase):
    def invoke(self, name, api=None, payload=None):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "output"
            event_path = Path(tmp) / "event.json"
            event_path.write_text(json.dumps(payload or event()))
            env = {"GITHUB_EVENT_NAME": name, "GITHUB_EVENT_PATH": str(event_path),
                   "GITHUB_REPOSITORY": "owner/repo", "GITHUB_API_URL": "https://api.github.com",
                   "GH_TOKEN": "test-secret"}
            with patch.dict(os.environ, env, clear=True), patch.object(ci, "_api_get", side_effect=api or AssertionError("No API expected")):
                result = ci.main(["--profile", "sdk-build", "--github-output", str(output)])
            return result, output.read_text() if output.exists() else ""

    def test_push_and_manual_events_require_ci_without_api(self):
        for name in ("push", "workflow_dispatch"):
            self.assertEqual((0, "run_ci=true\n"), self.invoke(name))

    def test_docs_pr_writes_exact_false(self):
        self.assertEqual((0, "run_ci=false\n"), self.invoke("pull_request", FakeAPI()))

    def test_errors_never_write_false(self):
        for api in (FakeAPI(before=ci.ClassificationError("failed")),
                    FakeAPI([ci.ClassificationError("failed")], metadata()),
                    FakeAPI(after=ci.ClassificationError("failed"))):
            result, output = self.invoke("pull_request", api)
            self.assertNotEqual(0, result)
            self.assertNotIn("run_ci=false", output)

    def test_transport_rejects_redirects_and_foreign_origins(self):
        with patch.dict(os.environ, {"GITHUB_API_URL": "https://api.github.com", "GH_TOKEN": "secret"}, clear=True):
            for path in ("https://evil.test/files", "//evil.test/files", "/repos/../files"):
                with self.assertRaises(ci.ClassificationError):
                    ci._api_get(path)
        request = ci.urllib.request.Request("https://api.github.com/repos/o/r")
        with self.assertRaises(ci.ClassificationError):
            ci._NoRedirect().redirect_request(request, None, 302, "Found", {}, "https://evil.test/")


if __name__ == "__main__":
    unittest.main()
