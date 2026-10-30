"""Sign and package a staged copy of LAD's pinned offline CAD runtime.

The caller owns staging and notarization. Never pass the shared prepared runtime
to ``sign_runtime``: release signatures must not modify the development cache.
Notarize the expanded, signed payload before calling ``pack_runtime`` because a
compressed tar archive is opaque to Apple's notary service.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

from audit_runtime import MACHO, audit_runtime


def native_images(root: Path) -> list[Path]:
    """Enumerate each actual native image once, without following symlinks."""
    root = Path(root)
    images = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO:
                    images.append(path)
    return images


def file_hash(path: Path) -> str:
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def checked(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    result = subprocess.run(command, check=False, capture_output=True, text=True, **kwargs)
    if result.returncode:
        details = (result.stderr or result.stdout or "").strip()
        raise RuntimeError(f"{Path(command[0]).name} failed ({result.returncode}): {details}")
    return result


def smoke_runtime(expanded: Path) -> None:
    """Exercise the signed interpreter, native CAD libraries and LLVM JIT."""
    expanded = Path(expanded).resolve()
    script = Path(__file__).resolve().with_name("check_runtime.py")
    with tempfile.TemporaryDirectory(prefix="LAD-signed-runtime-") as directory:
        environment = {
            "PATH": "/usr/bin:/bin", "HOME": directory, "TMPDIR": directory,
            "MPLCONFIGDIR": directory, "XDG_CACHE_HOME": directory,
            "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1",
        }
        result = checked([str(expanded / "python/bin/python3"), "-I", "-B", str(script)],
                         cwd=directory, env=environment, timeout=180)
        print(result.stdout.strip(), file=sys.stderr)


def sign_runtime(expanded: Path, identity: str, production: bool = True,
                 python_entitlements: Path | None = None) -> dict:
    """Sign and verify every Mach-O in a private expanded payload copy.

    An ad-hoc identity is supported solely for local packaging verification.
    The pinned LLVM/Numba build needs unsigned executable memory. The smoke
    check demonstrates this requirement; allow-jit alone is insufficient. This
    exception applies to Python only; native libraries receive no exceptions.
    """
    expanded = Path(expanded).resolve()
    if not identity or (production and identity == "-"):
        raise ValueError("A Developer ID Application signing identity is required for a release.")
    prepared_cache = Path(__file__).resolve().parents[1] / ".build/cad-runtime"
    if expanded.is_relative_to(prepared_cache.resolve()):
        raise ValueError("Sign a private staging copy, never the prepared CAD runtime cache.")
    audit = audit_runtime(expanded / "python", "arm64")
    images = native_images(expanded)
    if not images:
        raise ValueError("The staged CAD runtime contains no native images.")
    print(f"Signing and verifying {len(images)} CAD runtime native images…", file=sys.stderr, flush=True)
    entitlements = {"com.apple.security.cs.allow-unsigned-executable-memory": True}
    if python_entitlements is not None:
        python_entitlements = Path(python_entitlements).resolve()
        with python_entitlements.open("rb") as stream:
            entitlements = plistlib.load(stream)
        if not isinstance(entitlements, dict) or any(not isinstance(value, bool) for value in entitlements.values()):
            raise ValueError("Python entitlements must be a dictionary of Boolean capabilities.")
    if production and any(entitlements.get(key) for key in
                          ("com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation")):
        raise ValueError("Release Python must retain library validation and disable debugger access.")
    if not production:
        # Ad-hoc signatures have no Team ID, so macOS cannot apply same-team
        # library validation. This exception is solely for local packaging
        # checks; Developer ID releases retain library validation.
        entitlements["com.apple.security.cs.disable-library-validation"] = True
    effective_entitlements_path = None

    def sign(path: Path) -> dict:
        command = ["/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime",
                   "--timestamp" if production else "--timestamp=none"]
        if effective_entitlements_path is not None and path.parent == expanded / "python/bin":
            command += ["--entitlements", str(effective_entitlements_path)]
        checked(command + [str(path)])
        checked(["/usr/bin/codesign", "--verify", "--strict", str(path)])
        details = checked(["/usr/bin/codesign", "--display", "--verbose=4", str(path)]).stderr
        flags = re.search(r"\bflags=0x([0-9a-fA-F]+)", details)
        if not flags or not int(flags.group(1), 16) & 0x10000:
            raise RuntimeError(f"Hardened runtime is missing from {path.relative_to(expanded)}")
        team = next((line.partition("=")[2] for line in details.splitlines() if line.startswith("TeamIdentifier=")), None)
        if production:
            authorities = [line.partition("=")[2] for line in details.splitlines() if line.startswith("Authority=")]
            if not authorities or not authorities[0].startswith("Developer ID Application:") or team in {None, "not set"}:
                raise RuntimeError(f"{path.relative_to(expanded)} lacks a Developer ID Application signature.")
            if not any(line.startswith("Timestamp=") for line in details.splitlines()):
                raise RuntimeError(f"{path.relative_to(expanded)} lacks a secure signing timestamp.")
        return {"path": path.relative_to(expanded).as_posix(), "teamIdentifier": team}

    with tempfile.TemporaryDirectory(prefix="LAD-runtime-entitlements-") as directory:
        if entitlements:
            effective_entitlements_path = Path(directory) / "Python.entitlements"
            effective_entitlements_path.write_bytes(plistlib.dumps(entitlements))
        with ThreadPoolExecutor(max_workers=8) as executor:
            signed = list(executor.map(sign, images))
        teams = {entry["teamIdentifier"] for entry in signed}
        if len(teams) != 1:
            raise RuntimeError("The CAD runtime contains signatures from different signing teams.")
        smoke_runtime(expanded)
    return {
        "identity": identity, "production": production, "hardenedRuntime": True,
        "teamIdentifier": signed[0]["teamIdentifier"],
        "nativeImages": [entry["path"] for entry in signed],
        "pythonEntitlements": entitlements or {}, "nativeAudit": audit,
    }


def pack_runtime(expanded: Path, source_manifest: dict, destination: Path,
                 signing: dict | None = None) -> dict:
    """Pack final signed bytes and assign a new content-addressed install ID."""
    expanded, destination = Path(expanded).resolve(), Path(destination).resolve()
    if source_manifest.get("architecture") != "arm64":
        raise ValueError("LAD release runtimes support Apple Silicon only.")
    if source_manifest.get("formatVersion") != 1:
        raise ValueError("Unsupported source CAD runtime manifest.")
    required = [expanded / name for name in ("python", "requirements-lock.txt", "wheel-hashes.json")]
    if not all(path.exists() for path in required):
        raise ValueError("The staged CAD runtime payload is incomplete.")
    for path in expanded.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(expanded):
            raise ValueError(f"The staged CAD runtime contains an external symlink: {path}")
    if destination == expanded or destination.is_relative_to(expanded):
        raise ValueError("The output payload must be outside its expanded runtime.")
    destination.mkdir(parents=True, exist_ok=True)
    # Publish the manifest only after the complete archive exists. The app's
    # installer verifies its exact digest before extracting anything.
    with tempfile.TemporaryDirectory(prefix=".runtime-package-", dir=destination) as temporary:
        archive = Path(temporary) / "payload.tar.gz"
        checked(["/usr/bin/tar", "-czf", str(archive), "-C", str(expanded),
                 "python", "requirements-lock.txt", "wheel-hashes.json"])
        digest = file_hash(archive)
        manifest = dict(source_manifest)
        original_identifier = source_manifest.get("identifier", "")
        old_digest = source_manifest.get("sha256", "")
        # Keep preparation's readable runtime/version prefix while guaranteeing
        # that Developer ID signatures cannot reuse an unsigned installation.
        suffix = "-" + old_digest[:20]
        prefix = original_identifier[:-len(suffix)] if original_identifier.endswith(suffix) else original_identifier
        if not prefix or any(not (character.isascii() and (character.isalnum() or character in "-_.")) for character in prefix):
            raise ValueError("The source runtime identifier is invalid.")
        if len(prefix) + 21 > 160:
            raise ValueError("The final CAD runtime identifier exceeds the installer's size limit.")
        manifest.update({"identifier": f"{prefix}-{digest[:20]}", "archive": "payload.tar.gz", "sha256": digest})
        if signing is not None:
            # The complete image inventory accompanies the release separately.
            # Runtime manifests remain within the installer's 64 KiB limit.
            manifest["signing"] = {key: value for key, value in signing.items() if key not in {"nativeImages", "nativeAudit"}}
            manifest["signing"]["nativeImageCount"] = len(signing.get("nativeImages", []))
        data = (json.dumps(manifest, indent=2) + "\n").encode()
        if len(data) > 65_536:
            raise ValueError("The final CAD runtime manifest exceeds the installer's size limit.")
        temporary_manifest = Path(temporary) / "manifest.json"
        temporary_manifest.write_bytes(data)
        os.replace(archive, destination / "payload.tar.gz")
        os.replace(temporary_manifest, destination / "manifest.json")
    return manifest
