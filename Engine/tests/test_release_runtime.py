"""Release runtime boundaries: exact bytes, safe staging and native inventory."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("lad_release_runtime", SCRIPTS / "release_runtime.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseRuntimeTests(unittest.TestCase):
    def fixture(self, root):
        expanded = root / "expanded"
        (expanded / "python/bin").mkdir(parents=True)
        (expanded / "python/bin/python3").write_bytes(b"native executable")
        (expanded / "requirements-lock.txt").write_text("cadquery==2.8.0\n")
        (expanded / "wheel-hashes.json").write_text("{}\n")
        return expanded

    def manifest(self):
        digest = "a" * 64
        return {"formatVersion": 1, "identifier": "cpython-3.11.18-cadquery-2.8.0-arm64-" + digest[:20],
                "architecture": "arm64", "pythonVersion": "3.11.18", "archive": "payload.tar.gz", "sha256": digest}

    def test_inventory_includes_unusual_native_names_once_and_never_follows_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "z.bin").write_bytes(b"\xcf\xfa\xed\xfe" + b"image")
            (root / "a.cpython.so").write_bytes(b"\xca\xfe\xba\xbe" + b"image")
            (root / "script").write_text("#!/bin/sh\n")
            (root / "alias").symlink_to("z.bin")
            self.assertEqual([path.name for path in release.native_images(root)], ["a.cpython.so", "z.bin"])

    def test_packed_bytes_receive_new_install_identity_and_complete_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expanded = self.fixture(root)
            source = self.manifest()
            signing = {"identity": "Test Developer ID", "hardenedRuntime": True,
                       "nativeImages": ["python/bin/python3"], "pythonEntitlements": {}}
            manifest = release.pack_runtime(expanded, source, root / "output", signing)
            archive = root / "output/payload.tar.gz"
            actual = hashlib.sha256(archive.read_bytes()).hexdigest()
            self.assertEqual(manifest["sha256"], actual)
            self.assertNotEqual(manifest["identifier"], source["identifier"])
            self.assertTrue(manifest["identifier"].endswith(actual[:20]))
            self.assertEqual(json.loads((root / "output/manifest.json").read_text()), manifest)
            self.assertEqual(manifest["signing"]["nativeImageCount"], 1)
            self.assertNotIn("nativeImages", manifest["signing"])
            self.assertEqual(source, self.manifest())
            with tarfile.open(archive) as bundle:
                self.assertEqual(bundle.extractfile("python/bin/python3").read(), b"native executable")
                self.assertEqual(bundle.extractfile("requirements-lock.txt").read(), b"cadquery==2.8.0\n")

    def test_refuses_external_symlinks_and_incomplete_payload_before_publishing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expanded = self.fixture(root)
            (expanded / "python/external").symlink_to("/usr/bin/true")
            with self.assertRaisesRegex(ValueError, "external symlink"):
                release.pack_runtime(expanded, self.manifest(), root / "output")
            self.assertFalse((root / "output/manifest.json").exists())
            (expanded / "python/external").unlink()
            (expanded / "wheel-hashes.json").unlink()
            with self.assertRaisesRegex(ValueError, "incomplete"):
                release.pack_runtime(expanded, self.manifest(), root / "output")

    def test_refuses_adhoc_release_and_mutating_the_prepared_runtime_cache(self):
        with self.assertRaisesRegex(ValueError, "Developer ID"):
            release.sign_runtime(Path("/tmp/unused"), "-", production=True)
        cache = SCRIPTS.parent / ".build/cad-runtime/arm64/expanded"
        with self.assertRaisesRegex(ValueError, "staging copy"):
            release.sign_runtime(cache, "-", production=False)

    def test_rejects_output_inside_runtime_and_unsupported_source_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expanded = self.fixture(root)
            with self.assertRaisesRegex(ValueError, "outside"):
                release.pack_runtime(expanded, self.manifest(), expanded / "output")
            with self.assertRaisesRegex(ValueError, "Apple Silicon"):
                release.pack_runtime(expanded, {**self.manifest(), "architecture": "unsupported"}, root / "output")


if __name__ == "__main__":
    unittest.main()
