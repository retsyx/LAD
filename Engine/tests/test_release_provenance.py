import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("lad_release_provenance", SCRIPTS / "release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseProvenanceTests(unittest.TestCase):
    def test_source_snapshot_uses_committed_bytes_and_dirty_checkout_blocks_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "checkout"
            root.mkdir()
            subprocess.run(["/usr/bin/git", "-C", str(root), "init", "-q"], check=True)
            program = root / "program.txt"
            program.write_text("committed release bytes")
            subprocess.run(["/usr/bin/git", "-C", str(root), "add", "program.txt"], check=True)
            subprocess.run(["/usr/bin/git", "-C", str(root), "-c", "user.name=LAD Test",
                            "-c", "user.email=lad-test@example.invalid", "-c", "commit.gpgsign=false",
                            "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture"], check=True)
            revision = subprocess.check_output(["/usr/bin/git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
            release.verify_checkout_unchanged(root, revision)
            program.write_text("edits made during notarization")
            snapshot = release.snapshot_source(root, revision, Path(directory) / "frozen source")
            self.assertEqual((snapshot / "program.txt").read_text(), "committed release bytes")
            self.assertFalse((snapshot / ".git").exists())
            with self.assertRaisesRegex(release.ReleaseError, "changed during packaging"):
                release.verify_checkout_unchanged(root, revision)
            program.write_text("committed release bytes")
            with self.assertRaisesRegex(release.ReleaseError, "changed during packaging"):
                release.verify_checkout_unchanged(root, "0" * 40)

    def test_payload_must_match_frozen_preparation_recipes_and_locks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "source"
            for name in ("Engine", "Scripts"):
                (root / name).mkdir(parents=True)
            source = {"pythonVersion": "3.11.18", "arm64": {"sha256": "a" * 64, "url": "https://example.invalid/python.tar.gz"}}
            (root / "Engine/runtime-source.json").write_text(json.dumps(source))
            requirements = root / "Engine/requirements-lock.txt"
            requirements.write_text("cadquery==2.8.0\n")
            wheels = {"cadquery.whl": "b" * 64}
            (root / "Engine/runtime-wheels-arm64.json").write_text(json.dumps(wheels))
            for name in ("prepare_runtime.py", "audit_runtime.py", "check_runtime.py"):
                (root / "Scripts" / name).write_text("# pinned preparation recipe\n")
            expanded = Path(directory) / "expanded"
            expanded.mkdir()
            (expanded / "requirements-lock.txt").write_bytes(requirements.read_bytes())
            (expanded / "wheel-hashes.json").write_text(json.dumps(wheels))
            manifest = {"pythonVersion": source["pythonVersion"], "pythonSourceURL": source["arm64"]["url"],
                        "pythonSourceSHA256": source["arm64"]["sha256"], "requirementsSHA256": release.file_hash(requirements),
                        "buildFingerprint": release.payload_fingerprint(root, "a" * 64 + ".tar.gz", "arm64")}
            release.verify_payload_provenance(root, expanded, manifest)
            (expanded / "requirements-lock.txt").write_text("cadquery==0.0.0\n")
            with self.assertRaisesRegex(release.ReleaseError, "does not match"):
                release.verify_payload_provenance(root, expanded, manifest)
            (expanded / "requirements-lock.txt").write_bytes(requirements.read_bytes())
            (root / "Scripts/check_runtime.py").write_text("# changed release recipe\n")
            with self.assertRaisesRegex(release.ReleaseError, "does not match"):
                release.verify_payload_provenance(root, expanded, manifest)


if __name__ == "__main__":
    unittest.main()
