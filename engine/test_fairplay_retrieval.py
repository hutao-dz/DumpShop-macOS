"""Exercise credential validation without connecting to a phone."""
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

VENDOR = Path(__file__).resolve().parents[1] / "vendor/fairplay-decrypt"
sys.path[:0] = [str(VENDOR), str(VENDOR / "credential-retrieval")]
import retrieve


def atom(tag, payload):
    return (len(payload) + 8).to_bytes(4, "big") + tag + payload


def license_for(credential):
    name, salt = b"test-license", bytes(range(16))
    clear = bytearray(448)
    clear[:4], clear[20:24], clear[44:48] = b"itun", b"key ", b"iviv"
    clear[24:40] = b"test-working-key"
    encryptor = Cipher(algorithms.AES(bytes(x ^ 0x30 for x in credential)),
                       modes.CBC(hashlib.md5(name + salt).digest())).encryptor()
    encrypted = encryptor.update(bytes(clear)) + encryptor.finalize()
    return atom(b"sinf", atom(b"schi", atom(b"name", name + b"\0")
                + atom(b"iviv", salt) + atom(b"priv", encrypted)
                + atom(b"key ", b"\1") + atom(b"user", b"test-account")))


class RetrievalValidationTests(unittest.TestCase):
    def run_retrieval(self, directory, credential, sinf):
        output = directory / "new-credential"
        udid = "11" * 20
        device = MagicMock()
        device.path.side_effect = lambda name: "/remote/" + name
        device.write.side_effect = lambda name, *args, **kwargs: "/remote/" + name
        device.trigger_directory = "/remote/trigger"
        device.read.side_effect = lambda path: bytes.fromhex(udid) if path.endswith("device-udid.bin") else credential
        argv = ["retrieve", "--ipa", str(directory / "app.ipa"), "--output-dir", str(output),
                "--device-udid", udid, "--bundle", str(directory)]
        with patch.object(sys, "argv", argv), patch.object(retrieve, "SSHDevice", return_value=device), \
             patch.object(retrieve, "license_sinf", return_value=sinf), \
             patch.object(retrieve, "trigger_app", return_value=("/apps/Test.app", "Test", sinf)), \
             patch.object(retrieve, "restart_fairplayd", return_value=1), \
             patch.object(retrieve, "observe_uid_layer"):
            try:
                retrieve.main()
            finally:
                device.cleanup.assert_called_once()
        return output

    def test_matching_credential_is_saved(self):
        credential = bytes(range(16))
        with tempfile.TemporaryDirectory() as root:
            output = self.run_retrieval(Path(root), credential, license_for(credential))
            self.assertEqual((output / "credential.bin").read_bytes(), credential)

    def test_wrong_16_byte_credential_is_not_saved(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(ValueError, "credential does not decode"):
                self.run_retrieval(Path(root), b"x" * 16, license_for(bytes(range(16))))
            self.assertFalse((Path(root) / "new-credential").exists())


if __name__ == "__main__":
    unittest.main()
