"""Verify privacy checks against real arm64 debug maps and executable strings."""
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
from prepare_app_binaries import (
    BinaryPrivacyError,
    prepare_app_binaries,
    read_binary_metadata,
    verify_app_binaries,
    verify_app_symbols,
)


@unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64",
                     "Native binary privacy checks require Apple Silicon macOS")
class AppBinaryPrivacyTests(unittest.TestCase):
    executable_paths = (
        Path("Contents/MacOS/LAD"),
        Path("Contents/PlugIns/LADThumbnailExtension.appex/Contents/MacOS/LADThumbnailExtension"),
    )

    def compile_fixture(self, root, embedded_path="public fixture"):
        source = root / "fixture.c"
        source.write_text("#include <stdio.h>\n"
                          f"const char *fixture_path = {json.dumps(embedded_path)};\n"
                          "int main(void) { return puts(fixture_path) < 0; }\n")
        object_file = root / "fixture.o"
        subprocess.run(["/usr/bin/xcrun", "clang", "-arch", "arm64", "-g", "-c",
                        str(source), "-o", str(object_file)], check=True,
                       capture_output=True, text=True)
        executable = root / "fixture"
        subprocess.run(["/usr/bin/xcrun", "clang", "-arch", "arm64", "-g",
                        str(object_file), "-o", str(executable)], check=True,
                       capture_output=True, text=True)
        return executable

    def make_app(self, root, embedded_path="public fixture"):
        fixture = self.compile_fixture(root, embedded_path)
        app = root / "LAD.app"
        for relative in self.executable_paths:
            executable = app / relative
            executable.parent.mkdir(parents=True)
            shutil.copy2(fixture, executable)
        return app

    def test_unstripped_debug_maps_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="lad-binary-privacy-", dir="/private/tmp") as directory:
            root = Path(directory)
            app = self.make_app(root)
            metadata = read_binary_metadata(app / self.executable_paths[0])
            self.assertGreater(metadata["debugRecordCount"], 0)
            with self.assertRaises(BinaryPrivacyError):
                verify_app_binaries(app)

    def test_prepare_retains_matching_symbols_and_strips_both_executables(self):
        with tempfile.TemporaryDirectory(prefix="lad-binary-privacy-", dir="/private/tmp") as directory:
            root = Path(directory)
            app = self.make_app(root)
            before = {relative.name: read_binary_metadata(app / relative)["uuid"]
                      for relative in self.executable_paths}
            symbols = root / "private symbols"
            prepare_app_binaries(app, symbols, build_roots=(root,))
            result = verify_app_binaries(app, build_roots=(root,))
            self.assertEqual(len(result), 2)
            for relative in self.executable_paths:
                with self.subTest(executable=relative.name):
                    executable = app / relative
                    metadata = read_binary_metadata(executable)
                    self.assertEqual(metadata["architecture"], "arm64")
                    self.assertEqual(metadata["debugRecordCount"], 0)
                    self.assertFalse(metadata["hasDWARF"])
                    self.assertEqual(metadata["uuid"], before[relative.name])
                    dwarf = symbols / f"{relative.name}.dSYM/Contents/Resources/DWARF/{relative.name}"
                    self.assertTrue(dwarf.is_file())
                    debug = read_binary_metadata(dwarf)
                    self.assertEqual(debug["uuid"], metadata["uuid"])
                    self.assertTrue(debug["hasDebugInfo"])
                    subprocess.run([str(executable)], check=True, capture_output=True)

    def test_retained_symbols_must_match_the_shipped_executable(self):
        with tempfile.TemporaryDirectory(prefix="lad-binary-privacy-", dir="/private/tmp") as directory:
            root = Path(directory)
            app = self.make_app(root)
            symbols = root / "symbols"
            prepare_app_binaries(app, symbols, build_roots=(root,))
            verify_app_symbols(app, symbols)
            other = root / "different build"
            other.mkdir()
            executable = self.compile_fixture(other, "different public fixture")
            dsym = other / "fixture.dSYM"
            subprocess.run(["/usr/bin/xcrun", "dsymutil", "--arch", "arm64",
                            str(executable), "-o", str(dsym)], check=True, capture_output=True)
            replacement = dsym / "Contents/Resources/DWARF/fixture"
            self.assertNotEqual(read_binary_metadata(replacement)["uuid"],
                                read_binary_metadata(app / self.executable_paths[0])["uuid"])
            shutil.copy2(replacement, symbols / "LAD.dSYM/Contents/Resources/DWARF/LAD")
            with self.assertRaisesRegex(BinaryPrivacyError, "mismatched"):
                verify_app_symbols(app, symbols)

    def test_symbols_cannot_be_retained_inside_the_distributed_app(self):
        with tempfile.TemporaryDirectory(prefix="lad-binary-privacy-", dir="/private/tmp") as directory:
            root = Path(directory)
            app = self.make_app(root)
            symbols = app / "Contents/Resources/symbols"
            with self.assertRaisesRegex(BinaryPrivacyError, "outside the app"):
                prepare_app_binaries(app, symbols)
            with self.assertRaisesRegex(BinaryPrivacyError, "outside the app"):
                verify_app_symbols(app, symbols)
            self.assertFalse(symbols.exists())

    def test_missing_debug_object_fails_before_executable_is_stripped(self):
        with tempfile.TemporaryDirectory(prefix="lad-binary-privacy-", dir="/private/tmp") as directory:
            root = Path(directory)
            app = self.make_app(root)
            executable = app / self.executable_paths[0]
            before = read_binary_metadata(executable)["debugRecordCount"]
            self.assertGreater(before, 0)
            (root / "fixture.o").unlink()
            with self.assertRaises(BinaryPrivacyError):
                prepare_app_binaries(app, root / "symbols", build_roots=(root,))
            self.assertEqual(read_binary_metadata(executable)["debugRecordCount"], before)

    def test_stripping_does_not_hide_embedded_personal_or_checkout_paths(self):
        with tempfile.TemporaryDirectory(prefix="lad-binary-privacy-", dir="/private/tmp") as directory:
            root = Path(directory)
            for name, embedded_path in (
                ("personal", "/Users/private-fixture/internal-checkout/Source.swift"),
                ("checkout", str(root / "checkout/Source.swift")),
            ):
                with self.subTest(kind=name):
                    case = root / name
                    case.mkdir()
                    app = self.make_app(case, embedded_path)
                    for relative in self.executable_paths:
                        subprocess.run(["/usr/bin/xcrun", "strip", "-S", str(app / relative)],
                                       check=True, capture_output=True)
                    self.assertEqual(read_binary_metadata(app / self.executable_paths[0])["debugRecordCount"], 0)
                    with self.assertRaises(BinaryPrivacyError) as error:
                        verify_app_binaries(app, build_roots=(root / "checkout",))
                    self.assertNotIn(embedded_path, str(error.exception))

    def test_missing_or_malformed_executable_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix="lad-binary-privacy-", dir="/private/tmp") as directory:
            root = Path(directory)
            app = self.make_app(root)
            executable = app / self.executable_paths[1]
            executable.unlink()
            with self.assertRaises(BinaryPrivacyError):
                verify_app_binaries(app)
            executable.write_bytes(b"not a Mach-O executable")
            with self.assertRaises(BinaryPrivacyError):
                read_binary_metadata(executable)


if __name__ == "__main__":
    unittest.main()
