"""Exercise real wrapper/CLI execution with an isolated, deterministic store server."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import store
import store_history


FAKE_TOOL = r'''
import json, os, pathlib, plistlib, sys, zipfile
args = sys.argv[1:]
mode = os.environ.get("FAKE_STORE_MODE", "")
def emit(**data): print(json.dumps(data))
def value(flag): return args[args.index(flag) + 1]
if args == ["--version"]:
    print("2.7.0-dumpshop-profiles"); sys.exit(0)
if args[:2] == ["auth", "info"]:
    emit(success=True, email="test@example.test", storefront="143463", name="Test"); sys.exit(0)
if args[0] == "list-versions":
    emit(success=True, externalVersionIdentifiers=["1", "2"] if mode != "bad-list" else ["../1"])
    sys.exit(0)
ident = value("--external-version-id") if "--external-version-id" in args else "3"
version = {"1": "13.1", "2": "13.2", "3": "13.3"}.get(ident)
if version is None or (mode == "missing" and args[0] == "download"):
    emit(success=False, error="requested version is unavailable"); sys.exit(1)
if args[0] == "get-version-metadata":
    emit(success=True, externalVersionID=ident, displayVersion=version, releaseDate="2026-03-21T10:54:48Z")
elif args[0] == "download":
    assert "--purchase" not in args, "history must not purchase"
    dst = pathlib.Path(value("--output")); dst.parent.mkdir(parents=True, exist_ok=True)
    with pathlib.Path(os.environ["FAKE_REQUEST_LOG"]).open("a") as f: f.write(json.dumps(args) + "\n")
    with zipfile.ZipFile(dst, "w") as z:
        z.writestr("Payload/Test.app/Info.plist", plistlib.dumps({
            "CFBundleIdentifier": "example.app", "CFBundleShortVersionString": "13.3" if mode == "wrong-version" else version,
            "CFBundleVersion": "123", "CFBundleExecutable": "Test"}))
        z.writestr("iTunesMetadata.plist", plistlib.dumps({"softwareVersionExternalIdentifier": "3" if mode == "wrong-id" else ident}))
    emit(success=True, output=str(dst))
'''


class StoreHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tool = self.root / "tool"
        self.tool.write_text("#!" + sys.executable + "\n" + FAKE_TOOL)
        self.tool.chmod(0o700)
        self.log = self.root / "requests.jsonl"
        env = patch.dict(os.environ, {"FAKE_REQUEST_LOG": str(self.log), "FAKE_STORE_MODE": ""})
        env.start(); self.addCleanup(env.stop)

    def download(self, ident="2", **kwargs):
        return store.download(self.tool, self.root / "cache", "example.app", self.root / "app.ipa",
                              profile="HK", external_version_id=ident, **kwargs)

    def test_real_transfer_validates_and_publishes_selected_version(self):
        path = self.download(expected_version="13.2")
        self.assertEqual(store.package_info(path)["version"], "13.2")
        request = json.loads(self.log.read_text().splitlines()[-1])
        self.assertEqual(request[request.index("--external-version-id") + 1], "2")
        self.assertNotIn("--purchase", request)

    def test_wrong_version_or_id_never_overwrites_existing_output(self):
        dest = self.root / "app.ipa"
        for mode in ("wrong-version", "wrong-id"):
            with self.subTest(mode=mode), patch.dict(os.environ, {"FAKE_STORE_MODE": mode}):
                dest.write_bytes(b"keep-existing-file")
                with self.assertRaisesRegex(store.StoreError, "不符"):
                    self.download()
                self.assertEqual(dest.read_bytes(), b"keep-existing-file")

    def test_missing_version_is_not_replaced_with_latest(self):
        with patch.dict(os.environ, {"FAKE_STORE_MODE": "missing"}):
            with self.assertRaisesRegex(store.StoreError, "unavailable"):
                self.download()
        self.assertFalse((self.root / "app.ipa").exists())

    def test_partial_files_are_isolated_from_other_versions_and_latest(self):
        partial = self.root / "app.ipa.tmp"
        partial.write_bytes(b"latest-partial")
        self.download("1")
        self.download("2")
        requests = [json.loads(line) for line in self.log.read_text().splitlines()]
        outputs = [r[r.index("--output") + 1] for r in requests]
        self.assertNotEqual(outputs[0], outputs[1])
        self.assertEqual(partial.read_bytes(), b"latest-partial")

    def test_changed_account_prevents_any_download(self):
        with self.assertRaisesRegex(store.StoreError, "账号已变更"):
            self.download(expected_account="other-account")
        self.assertFalse(self.log.exists())

    def test_bad_version_id_and_changed_metadata_fail_before_transfer(self):
        for ident in ("../1", "0", "", "1.2"):
            with self.subTest(ident=ident), self.assertRaises(store.StoreError):
                self.download(ident, expected_version="13.2")
        with self.assertRaisesRegex(store.StoreError, "信息已变化"):
            self.download(expected_version="13.0")
        self.assertFalse(self.log.exists())

    def test_page_retains_ids_and_has_usable_metadata(self):
        page = store_history.page(store, self.tool, self.root / "cache", "example.app", "HK", limit=1)
        self.assertEqual(page["versions"][0]["displayVersion"], "13.2")
        self.assertEqual(page["next_offset"], 1)
        self.assertEqual(page["total"], 2)
        with patch.dict(os.environ, {"FAKE_STORE_MODE": "bad-list"}):
            with self.assertRaises(store.StoreError):
                store.list_versions(self.tool, self.root / "cache", "example.app", "HK")

    def test_same_transfer_cannot_run_concurrently(self):
        work = self.root / "locked"
        with store_history.transfer_lock(work, store.StoreError):
            with self.assertRaisesRegex(store.StoreError, "正在下载"):
                with store_history.transfer_lock(work, store.StoreError):
                    self.fail("second transfer acquired the same lock")

    def test_cli_uses_shared_module_and_emits_result(self):
        proc = subprocess.run([sys.executable, str(Path(store.__file__)), "--ipatool", str(self.tool),
                               "--cache-root", str(self.root / "cache"), "--profile", "HK", "download",
                               "--bundle-id", "example.app", "--dest", str(self.root / "cli.ipa"),
                               "--external-version-id", "2", "--expected-version", "13.2"],
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        result = [json.loads(line) for line in proc.stdout.splitlines() if json.loads(line).get("e") == "result"]
        self.assertEqual(result[-1]["version"], "13.2")


if __name__ == "__main__":
    unittest.main()
