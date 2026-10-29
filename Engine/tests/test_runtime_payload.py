"""Packaging checks that prevent shipping a runtime tied to a developer Mac."""
import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/audit_runtime.py"
SPEC = importlib.util.spec_from_file_location("lad_runtime_audit", SCRIPT)
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


class RuntimeNativeAuditTests(unittest.TestCase):
    def test_rejects_external_runtime_libraries_and_search_paths(self):
        for kind in ["dependency", "rpath"]:
            for path in ["/opt/homebrew/opt/lib/libsomething.dylib", "/Users/builder/local/lib", "liblocal.dylib"]:
                with self.subTest(kind=kind, path=path), self.assertRaises(RuntimeError):
                    audit.validate_commands([(kind, path)], "test-image")

    def test_checks_minimum_macos_while_allowing_relocatable_and_system_paths(self):
        audit.validate_commands([("dependency", "@rpath/libTKMesh.dylib"),
                                 ("rpath", "@loader_path/../native libraries"),
                                 ("dependency", "/usr/lib/libSystem.B.dylib"),
                                 ("minimumOS", "14.0")], "test-image")
        with self.assertRaises(RuntimeError):
            audit.validate_commands([("minimumOS", "15.0")], "test-image")

    def test_parses_dependencies_rpaths_and_both_deployment_commands(self):
        commands = audit.load_commands("""
Load command 0
          cmd LC_LOAD_DYLIB
         name @rpath/native library.dylib (offset 24)
Load command 1
          cmd LC_RPATH
         path @loader_path/../native libraries (offset 12)
Load command 2
          cmd LC_BUILD_VERSION
        minos 14.0
Load command 3
          cmd LC_VERSION_MIN_MACOSX
      version 11.0
""")
        self.assertEqual(commands, [("dependency", "@rpath/native library.dylib"),
                                    ("rpath", "@loader_path/../native libraries"),
                                    ("minimumOS", "14.0"), ("minimumOS", "11.0")])


if __name__ == "__main__":
    unittest.main()
