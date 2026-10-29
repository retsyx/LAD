"""Reject native runtime libraries that depend on a developer's installation."""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import re
import subprocess

MACHO = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
         b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/", "/Library/Apple/System/Library/")


def is_system(value):
    return value.startswith(SYSTEM_PREFIXES) or value.rstrip("/") in {prefix.rstrip("/") for prefix in SYSTEM_PREFIXES}


def load_commands(text):
    commands = []
    for block in re.split(r"Load command \d+\n", text)[1:]:
        command = re.search(r"^\s*cmd (\S+)", block, re.MULTILINE)
        if not command:
            continue
        name = command.group(1)
        if name in {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB"}:
            value = re.search(r"^\s*name (.*?) \(offset", block, re.MULTILINE)
            commands.append(("dependency", value.group(1)))
        elif name == "LC_RPATH":
            value = re.search(r"^\s*path (.*?) \(offset", block, re.MULTILINE)
            commands.append(("rpath", value.group(1)))
        elif name in {"LC_BUILD_VERSION", "LC_VERSION_MIN_MACOSX"}:
            value = re.search(r"^\s*(?:minos|version) ([\d.]+)", block, re.MULTILINE)
            commands.append(("minimumOS", value.group(1)))
    return commands


def validate_commands(commands, name, minimum_os="14.0"):
    for kind, value in commands:
        if kind == "minimumOS":
            version = tuple(map(int, value.split(".")))[:2]
            version += (0,) * (2 - len(version))
            if version > tuple(map(int, minimum_os.split(".")))[:2]:
                raise RuntimeError(f"{name} requires macOS {value}, above supported {minimum_os}")
        elif value.startswith("/"):
            if not is_system(value):
                raise RuntimeError(f"External {kind} in {name}: {value}")
        elif not value.startswith(("@loader_path/", "@executable_path/", "@rpath/")) and value not in {"@loader_path", "@executable_path"}:
            raise RuntimeError(f"Nonrelocatable {kind} in {name}: {value}")


def audit_runtime(root, architecture="arm64", repair_build_rpaths=False):
    root = root.resolve()
    files = []
    for path in root.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO:
                    files.append(path)

    def inspect(path):
        arches = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).split()
        if architecture not in arches:
            raise RuntimeError(f"{path.relative_to(root)} has no {architecture} architecture: {arches}")
        text = subprocess.check_output(["/usr/bin/otool", "-arch", architecture, "-l", str(path)], text=True)
        commands = load_commands(text)
        removed = []
        if repair_build_rpaths:
            # Some upstream wheels retain unused build-machine search paths.
            # Dependencies themselves must still resolve within the payload;
            # never rewrite an actual missing external library into a guess.
            for kind, value in commands:
                if kind == "rpath" and value.startswith("/") and not is_system(value):
                    subprocess.run(["/usr/bin/install_name_tool", "-delete_rpath", value, str(path)], check=True, capture_output=True)
                    removed.append(value)
            if removed:
                subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(path)], check=True, capture_output=True)
                text = subprocess.check_output(["/usr/bin/otool", "-arch", architecture, "-l", str(path)], text=True)
                commands = load_commands(text)
        validate_commands(commands, path.relative_to(root))
        return path, commands, removed

    with ThreadPoolExecutor(max_workers=8) as executor:
        results = list(executor.map(inspect, files))
        inspected = {path: commands for path, commands, removed in results}

    def expand(value, owner):
        if value.startswith("@loader_path"):
            return Path(str(owner.parent) + value[len("@loader_path"):]).resolve()
        if value.startswith("@executable_path"):
            return Path(str(root / "bin") + value[len("@executable_path"):]).resolve()
        return Path(value)

    # Resolve each relative link against its own loader search paths. An image
    # may inherit loader rpaths from its importing extension, so also consider
    # the packaged images' rpaths; no external directories are ever searched.
    all_rpaths = {expand(value, path) for path, commands in inspected.items() for kind, value in commands if kind == "rpath"}
    missing = []
    for path, commands in inspected.items():
        local_rpaths = {expand(value, path) for kind, value in commands if kind == "rpath"}
        for kind, value in commands:
            if kind != "dependency" or is_system(value):
                continue
            if value.startswith("@rpath/"):
                suffix = value[len("@rpath/"):]
                candidates = [base / suffix for base in local_rpaths | all_rpaths]
            else:
                candidates = [expand(value, path)]
            if not any(candidate.is_file() and candidate.resolve().is_relative_to(root) for candidate in candidates):
                missing.append(f"{path.relative_to(root)}: {value}")
    if missing:
        raise RuntimeError("Missing packaged libraries:\n" + "\n".join(missing))
    minimums = [value for commands in inspected.values() for kind, value in commands if kind == "minimumOS"]
    minimum = max(minimums, key=lambda value: tuple(map(int, value.split("."))))
    return {"nativeImages": len(files), "architecture": architecture, "minimumMacOS": minimum,
            "removedBuildRpaths": {str(path.relative_to(root)): removed for path, commands, removed in results if removed}}


if __name__ == "__main__":
    import argparse
    import json
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    args = parser.parse_args()
    print(json.dumps(audit_runtime(args.runtime), indent=2))
