import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import store


class StoreProfileTests(unittest.TestCase):
    def test_storefront_and_identity(self):
        for storefront, region in store._STOREFRONTS.items():
            with self.subTest(region=region):
                event = {"success": True, "email": "Test@example.test",
                         "storefront": storefront + "-1,29"}
                summary = store._auth_summary(event, region)
                self.assertTrue(summary["logged_in"])
                self.assertEqual(summary["region"], region.upper())
                self.assertNotIn("Test@", summary["email"])
                self.assertEqual(summary["account_id"], store._auth_summary(
                    dict(event, email="test@EXAMPLE.test"), region)["account_id"])
                wrong = "us" if region != "us" else "tw"
                self.assertFalse(store._auth_summary(event, wrong)["logged_in"])
        self.assertFalse(store._auth_summary({"email": "a@example.test"}, "tw")["logged_in"])
        # Preserve the existing CN helper, which cannot emit a storefront field.
        self.assertTrue(store._auth_summary({"email": "a@example.test"}, "cn")["logged_in"])

    def test_state_isolation(self):
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, {"XDG_STATE_HOME": "/unrelated"}):
            cn = store.ipatool_env(Path(root), "CN")
            tw = store.ipatool_env(Path(root), "TW")
            self.assertNotEqual(cn["XDG_STATE_HOME"], tw["XDG_STATE_HOME"])
            self.assertEqual(tw["XDG_STATE_HOME"], tw["XDG_DATA_HOME"])
            self.assertEqual(tw["IPATOOL_PROFILE"], "tw")
            with self.assertRaises(store.StoreError):
                store.ipatool_env(Path(root), "../cn")

    def test_legacy_binary_cannot_read_regional_session(self):
        result = subprocess.CompletedProcess([], 0, b"ipatool version 2.7.0", b"")
        with patch.object(store.subprocess, "run", return_value=result) as run:
            with self.assertRaisesRegex(store.StoreError, "多地区专用"):
                store.run_json(Path("/fake/ipatool"), ["auth", "info"], Path("/unused"), profile="tw")
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][-1], "--version")

    def run_download(self, root, purchase=False, error=None, account="account-a"):
        destination = Path(root) / "app.ipa"
        destination.touch()
        with patch.object(store, "auth_info", return_value={"logged_in": True, "account_id": account}), \
             patch.object(store, "run_json", return_value=[{"output": str(destination)}], side_effect=error) as run:
            got = store.download(Path("/fake/tool"), Path(root), "example.app", destination,
                                 purchase=purchase, profile="TW", expected_account="account-a")
            return got, run.call_args

    def test_owned_paid_download_never_purchases(self):
        with tempfile.TemporaryDirectory() as root:
            got, call = self.run_download(root)
            self.assertTrue(got.exists())
            self.assertNotIn("--purchase", call.args[1])
            self.assertEqual(call.kwargs["profile"], "TW")

    def test_free_app_can_acquire_license(self):
        with tempfile.TemporaryDirectory() as root:
            _, call = self.run_download(root, purchase=True)
            self.assertIn("--purchase", call.args[1])

    def test_unowned_paid_message(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(store.StoreError, "该软件需要付费，暂不支持砸壳"):
                self.run_download(root, error=store.StoreError("license is required"))

    def test_network_error_is_not_misreported_as_unowned(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(store.StoreError, "network offline"):
                self.run_download(root, error=store.StoreError("network offline"))

    def test_changed_account_stops_before_download(self):
        with tempfile.TemporaryDirectory() as root, \
             patch.object(store, "auth_info", return_value={"logged_in": True, "account_id": "account-b"}), \
             patch.object(store, "run_json") as run:
            with self.assertRaisesRegex(store.StoreError, "账号已变更"):
                store.download(Path("/fake/tool"), Path(root), "example.app", Path(root) / "app.ipa",
                               profile="TW", expected_account="account-a")
            run.assert_not_called()

    def test_transient_dns_error_retries_without_paid_purchase(self):
        with tempfile.TemporaryDirectory() as root:
            destination = Path(root) / "app.ipa"
            destination.touch()
            with patch.object(store, "auth_info", return_value={"logged_in": True, "account_id": "a"}), \
                 patch.object(store.time, "sleep") as sleep, \
                 patch.object(store, "log"), \
                 patch.object(store, "run_json", side_effect=[store.StoreError("no such host"),
                              [{"output": str(destination)}]]) as run:
                result = store.download(Path("/fake/tool"), Path(root), "example.app", destination,
                                        purchase=False, profile="JP", expected_account="a")
                self.assertEqual(result, destination)
                self.assertEqual(run.call_count, 2)
                self.assertTrue(all("--purchase" not in call.args[1] for call in run.call_args_list))
                sleep.assert_called_once_with(1)

    def test_persistent_dns_error_stops_at_attempt_limit(self):
        with tempfile.TemporaryDirectory() as root, \
             patch.object(store, "auth_info", return_value={"logged_in": True, "account_id": "a"}), \
             patch.object(store.time, "sleep"), patch.object(store, "log"), \
             patch.object(store, "run_json", side_effect=store.StoreError("no such host")) as run:
            with self.assertRaisesRegex(store.StoreError, "no such host"):
                store.download(Path("/fake/tool"), Path(root), "example.app", Path(root) / "app.ipa",
                               purchase=False, profile="JP", expected_account="a")
            self.assertEqual(run.call_count, store.DOWNLOAD_MAX_ATTEMPTS)
            self.assertIn("DNS 解析失败", store._friendly("dial tcp: lookup itunes.apple.com: no such host"))

    def test_changed_account_during_retry_stops_download(self):
        with tempfile.TemporaryDirectory() as root, \
             patch.object(store, "auth_info", side_effect=[
                 {"logged_in": True, "account_id": "a"}, {"logged_in": True, "account_id": "b"}]), \
             patch.object(store.time, "sleep"), patch.object(store, "log"), \
             patch.object(store, "run_json", side_effect=store.StoreError("i/o timeout")) as run:
            with self.assertRaisesRegex(store.StoreError, "账号已变更"):
                store.download(Path("/fake/tool"), Path(root), "example.app", Path(root) / "app.ipa",
                               purchase=False, profile="JP", expected_account="a")
            self.assertEqual(run.call_count, 1)

    def test_transfer_timeout_messages_are_retryable(self):
        messages = (
            "failed to download file: failed to write file: read tcp 192.0.2.1:1234->192.0.2.2:443: read: operation timed out",
            "request failed: net/http: timeout awaiting response headers",
            "failed to download file: failed to write file: unexpected EOF",
            "unexpected download response status: 503",
        )
        for message in messages:
            with self.subTest(message=message):
                self.assertEqual(store._network_failure_kind(message), "connection")
                self.assertIn("连接 App Store 超时或中断", store._friendly(message))
        for message in ("credential does not decode this SINF priv record", "license is required",
                        "invalid account information", "unexpected download response status: 403"):
            self.assertEqual(store._network_failure_kind(message), "")

    def test_read_timeout_retries_child_process_with_partial_file(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            destination = root / "app.ipa"
            tool = root / "ipatool"
            tool.write_text("#!" + str(Path(sys.executable).resolve()) + "\n" + '''
import json, pathlib, sys
dest = pathlib.Path(sys.argv[sys.argv.index('--output') + 1])
partial = pathlib.Path(str(dest) + '.tmp')
if not partial.exists():
    partial.write_bytes(b'first-part')
    print(json.dumps({'success': False, 'error': 'failed to download file: read tcp: operation timed out'}))
    sys.exit(1)
assert partial.read_bytes() == b'first-part', 'partial download was lost'
dest.write_bytes(partial.read_bytes() + b'-last-part')
print(json.dumps({'success': True, 'output': str(dest)}))
''')
            tool.chmod(0o700)
            with patch.object(store, "auth_info", return_value={"logged_in": True, "account_id": "a"}), \
                 patch.object(store.time, "sleep"), patch.object(store, "log") as log:
                got = store.download(tool, root, "example.app", destination,
                                     purchase=False, profile="CN", expected_account="a")
                self.assertEqual(got.read_bytes(), b'first-part-last-part')
                self.assertEqual(log.call_count, 1)
                self.assertEqual(log.call_args.kwargs["phase"], "download-retry")
                self.assertIn("断点续传", log.call_args.args[0])

    def test_process_deadline_is_a_network_failure(self):
        with tempfile.TemporaryDirectory() as root, \
             patch.object(store.subprocess, "run", side_effect=subprocess.TimeoutExpired("ipatool", 12)):
            with self.assertRaisesRegex(store.StoreError, "连接 App Store 超时"):
                store.run_json(Path("/fake/tool"), ["download"], Path(root), timeout=12)


if __name__ == "__main__":
    unittest.main()
