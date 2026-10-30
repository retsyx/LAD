"""Release failures must never produce apparently distributable artifacts."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("lad_release", SCRIPTS / "release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_production_credentials_and_valid_version_are_required(self):
        for version, build, local, identity, profile in [
            ("0.3.0", "99", False, "", ""),
            ("0.3.0", "99", False, "-", "profile"),
            ("0.3.0", "99", True, "Developer ID", ""),
            ("../output", "99", True, "", ""),
            ("0.3.0", "0", True, "", ""),
            ("0.3.0", "1/../../escape", True, "", ""),
        ]:
            with self.subTest(version=version, build=build, local=local), self.assertRaises(release.ReleaseError):
                release.validate_inputs(version, build, local, identity, profile)
        release.validate_inputs("0.3.0", "99", False, "Developer ID Application: LAD", "profile")
        release.validate_inputs("0.3.0", "99", True, "", "")

    def test_corrupt_payload_fails_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "manifest.json").write_text(json.dumps({"architecture": "arm64", "formatVersion": 1,
                                                           "archive": "payload.tar.gz", "sha256": "0" * 64}))
            (root / "payload.tar.gz").write_bytes(b"corrupted")
            destination = root / "extracted"
            with self.assertRaisesRegex(release.ReleaseError, "checksum"):
                release.unpack_payload(root, destination)
            self.assertFalse(destination.exists())

    def test_payload_cannot_extract_outside_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "payload.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                entry = tarfile.TarInfo("../escaped")
                entry.size = 0
                output.addfile(entry)
            (root / "manifest.json").write_text(json.dumps({"architecture": "arm64", "formatVersion": 1,
                                                           "archive": archive.name, "sha256": release.file_hash(archive)}))
            with self.assertRaises(tarfile.FilterError):
                release.unpack_payload(root, root / "extracted")
            self.assertFalse((root / "escaped").exists())

    def test_notarization_rejection_retains_the_complete_log(self):
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            response = subprocess.CompletedProcess([], 0, json.dumps({"id": "submission", "status": "Invalid"}), "")
            def fetch_log(command, **kwargs):
                Path(command[4]).write_text(json.dumps({"status": "Invalid", "issues": [{"severity": "error"}]}))
            with patch.object(release.subprocess, "run", return_value=response), patch.object(release, "run", side_effect=fetch_log):
                with self.assertRaisesRegex(release.ReleaseError, "not accepted"):
                    release.notarize(logs / "test.zip", "runtime", "profile", logs)
            self.assertTrue((logs / "runtime-log.json").is_file())
            self.assertEqual(json.loads((logs / "runtime-submission.json").read_text())["status"], "Invalid")

    def test_successful_submission_still_requires_successful_log(self):
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            response = subprocess.CompletedProcess([], 0, json.dumps({"id": "submission", "status": "Accepted"}), "")
            def fetch_log(command, **kwargs):
                Path(command[4]).write_text(json.dumps({"status": "Invalid", "issues": []}))
            with patch.object(release.subprocess, "run", return_value=response), patch.object(release, "run", side_effect=fetch_log):
                with self.assertRaisesRegex(release.ReleaseError, "not successful"):
                    release.notarize(logs / "test.zip", "app", "profile", logs)

    def test_unfinished_submission_is_not_success(self):
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            response = subprocess.CompletedProcess([], 1, json.dumps({"id": "submission", "status": "In Progress"}), "timed out")
            with patch.object(release.subprocess, "run", return_value=response), patch.object(release, "run"):
                with self.assertRaisesRegex(release.ReleaseError, "not accepted"):
                    release.notarize(logs / "test.dmg", "dmg", "profile", logs)
            self.assertEqual((logs / "dmg-submission.stderr.txt").read_text(), "timed out")


if __name__ == "__main__":
    unittest.main()
