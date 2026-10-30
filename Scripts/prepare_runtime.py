"""Prepare a relocatable, offline CAD payload using the pinned standalone Python."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

from audit_runtime import audit_runtime


def remove_external_tool_plugins(python):
    site = python / "lib/python3.11/site-packages"
    # These optional upstream plugins already require separately installed
    # solvers, MATLAB or OpenMP. None is used by CadQuery's CAD construction,
    # sketch solver or bundled IPOPT assembly solver. Never leave native images
    # in the product whose dependency closure cannot be satisfied.
    patterns = ["numba/np/ufunc/omppool*.so", "casadi/libmatlab_ipc.dylib"]
    patterns += [f"casadi/libcasadi_{plugin}*.dylib" for plugin in
                 ("linsol_ma27", "conic_xpress", "nlpsol_knitro", "nlpsol_snopt", "nlpsol_ccopt",
                  "nlpsol_madnlp", "conic_mosek", "nlpsol_conopt")]
    removed = []
    for pattern in patterns:
        for file in sorted(site.glob(pattern)):
            removed.append(str(file.relative_to(python)))
            file.unlink()
    return removed


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def checked(command, **kwargs):
    subprocess.run(command, check=True, stdout=sys.stderr, **kwargs)


def payload_fingerprint(root, archive_name, architecture):
    """Identify the exact preparation recipes and pinned artifact manifests."""
    root = Path(root)
    requirements = root / "Engine/requirements-lock.txt"
    wheel_lock = root / f"Engine/runtime-wheels-{architecture}.json"
    return hashlib.sha256(
        Path(archive_name).name.encode() + requirements.read_bytes() + wheel_lock.read_bytes()
        + (root / "Scripts/prepare_runtime.py").read_bytes()
        + (root / "Scripts/audit_runtime.py").read_bytes() + (root / "Engine/runtime-source.json").read_bytes()
        + (root / "Scripts/check_runtime.py").read_bytes()
    ).hexdigest()[:16]


def prepare(root, archive, architecture):
    source = json.loads((root / "Engine/runtime-source.json").read_text())
    requirements = root / "Engine/requirements-lock.txt"
    wheel_lock = root / f"Engine/runtime-wheels-{architecture}.json"
    fingerprint = payload_fingerprint(root, archive.name, architecture)
    destination = root / ".build/cad-runtime" / architecture
    manifest_path = destination / "manifest.json"
    if manifest_path.exists():
        previous = json.loads(manifest_path.read_text())
        if previous.get("buildFingerprint") == fingerprint and digest(destination / "payload.tar.gz") == previous.get("sha256"):
            return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{architecture}-", dir=destination.parent))
    try:
        expanded = staging / "expanded"
        expanded.mkdir()
        with tarfile.open(archive) as bundle:
            bundle.extractall(expanded, filter="data")
        python = expanded / "python/bin/python3"
        wheels = staging / "wheels"
        wheels.mkdir()
        checked([sys.executable, "-m", "pip", "download", "--only-binary=:all:", "--no-deps",
                 "--dest", str(wheels), "--requirement", str(requirements)])
        wheel_hashes = {path.name: digest(path) for path in sorted(wheels.iterdir())}
        if wheel_hashes != json.loads(wheel_lock.read_text()):
            raise RuntimeError("Downloaded CAD wheels differ from the committed artifact hashes.")
        checked([str(python), "-m", "pip", "install", "--no-index", "--no-deps", "--no-compile",
                 "--find-links", str(wheels), "--requirement", str(requirements)])
        checked([str(python), "-m", "pip", "check"])
        excluded_plugins = remove_external_tool_plugins(expanded / "python")
        native_audit = audit_runtime(expanded / "python", architecture, repair_build_rpaths=True)
        checked([str(python), "-I", "-B", str(root / "Scripts/check_runtime.py")])
        for cache in expanded.rglob("__pycache__"):
            shutil.rmtree(cache)
        # pip-generated launchers retain the build path. The app uses `python -m`
        # and creates a fresh venv; remove these unnecessary stale entry points.
        for entry in (expanded / "python/bin").iterdir():
            if entry.is_file() and not entry.is_symlink() and entry.read_bytes()[:2] == b"#!":
                entry.unlink()
        for entry in expanded.rglob("*"):
            if entry.is_symlink():
                resolved = entry.resolve()
                if not resolved.is_relative_to(expanded.resolve()):
                    raise RuntimeError(f"Payload contains an external symlink: {entry}")
        shutil.copy2(requirements, expanded / "requirements-lock.txt")
        (expanded / "wheel-hashes.json").write_text(json.dumps(wheel_hashes, indent=2) + "\n")
        payload = staging / "payload.tar.gz"
        checked(["/usr/bin/tar", "-czf", str(payload), "-C", str(expanded), "python", "requirements-lock.txt", "wheel-hashes.json"])
        payload_hash = digest(payload)
        # Different built bytes never share an installation path, including
        # rebuilds by a different builder or a later runtime-packaging change.
        identifier = f"cpython-{source['pythonVersion']}-cadquery-2.8.0-{architecture}-{payload_hash[:20]}"
        manifest = {"formatVersion": 1, "identifier": identifier, "architecture": architecture,
                    "pythonVersion": source["pythonVersion"], "archive": "payload.tar.gz",
                    "sha256": payload_hash, "buildFingerprint": fingerprint, "requirementsSHA256": digest(requirements),
                    "pythonSourceURL": source[architecture]["url"],
                    "pythonSourceSHA256": source[architecture]["sha256"], "nativeAudit": native_audit,
                    "excludedExternalToolPlugins": excluded_plugins}
        (staging / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        shutil.rmtree(wheels)
        if destination.exists():
            shutil.rmtree(destination)
        staging.rename(destination)
        return destination
    finally:
        if staging.exists():
            shutil.rmtree(staging)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--architecture", required=True, choices=["arm64"])
    args = parser.parse_args()
    print(prepare(args.root, args.archive, args.architecture))
