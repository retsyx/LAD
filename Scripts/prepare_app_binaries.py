"""Keep arm64 app debug symbols private and reject build paths before signing."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
from uuid import UUID


EXECUTABLES = (
    Path("Contents/MacOS/LAD"),
    Path("Contents/PlugIns/LADThumbnailExtension.appex/Contents/MacOS/LADThumbnailExtension"),
)


class BinaryPrivacyError(RuntimeError):
    pass


def _metadata(data, label):
    """Read only thin arm64 Mach-O records, including the separate dSYM image."""
    def bounded(offset, size):
        if offset < 0 or size < 0 or offset + size > len(data):
            raise BinaryPrivacyError(f"Malformed Mach-O records in {label}.")
        return data[offset:offset + size]

    header = struct.unpack("<IiiIIIII", bounded(0, 32))
    magic, cpu, _, _, command_count, command_bytes, _, _ = header
    if magic != 0xFEEDFACF or cpu != 0x0100000C:
        raise BinaryPrivacyError(f"Expected a thin arm64 Mach-O image: {label}.")
    commands_end = 32 + command_bytes
    bounded(32, command_bytes)
    if command_count > command_bytes // 8:
        raise BinaryPrivacyError(f"Malformed Mach-O commands in {label}.")
    offset = 32
    image_uuid = None
    symbol_table = None
    has_dwarf = False
    has_debug_info = False
    for _ in range(command_count):
        command, size = struct.unpack("<II", bounded(offset, 8))
        if size < 8 or offset + size > commands_end:
            raise BinaryPrivacyError(f"Malformed Mach-O command in {label}.")
        record = bounded(offset, size)
        if command == 0x1B:  # LC_UUID
            if size != 24 or image_uuid is not None:
                raise BinaryPrivacyError(f"Invalid Mach-O UUID in {label}.")
            image_uuid = str(UUID(bytes=record[8:24])).upper()
        elif command == 0x19:  # LC_SEGMENT_64
            if size < 72:
                raise BinaryPrivacyError(f"Malformed Mach-O segment in {label}.")
            dwarf_segment = record[8:24].rstrip(b"\0") == b"__DWARF"
            has_dwarf |= dwarf_segment
            section_count = struct.unpack_from("<I", record, 64)[0]
            if size != 72 + section_count * 80:
                raise BinaryPrivacyError(f"Malformed Mach-O sections in {label}.")
            for section in range(section_count):
                start = 72 + section * 80
                name = record[start:start + 16].rstrip(b"\0")
                section_size, section_offset = struct.unpack_from("<QI", record, start + 40)
                if dwarf_segment and name == b"__debug_info" and section_size:
                    bounded(section_offset, section_size)
                    has_debug_info = True
        elif command == 0x2:  # LC_SYMTAB
            if size != 24 or symbol_table is not None:
                raise BinaryPrivacyError(f"Invalid Mach-O symbol table in {label}.")
            symbol_table = struct.unpack_from("<IIII", record, 8)
        offset += size
    if offset != commands_end or image_uuid is None:
        raise BinaryPrivacyError(f"Incomplete Mach-O metadata in {label}.")
    debug_records = 0
    if symbol_table is not None:
        symbols, count, strings, string_bytes = symbol_table
        entries = bounded(symbols, count * 16)
        names = bounded(strings, string_bytes)
        for index in range(count):
            string_index, kind = struct.unpack_from("<IB", entries, index * 16)
            if string_index >= string_bytes:
                raise BinaryPrivacyError(f"Invalid Mach-O symbol string in {label}.")
            # Apple's linker retains this harmless N_OPT marker after strip -S.
            # It carries neither a debug map nor compiler options/source paths.
            if kind == 0x3C and names[string_index:].split(b"\0", 1)[0] == b"radr://5614542":
                continue
            # N_STAB debug-map entries and Swift's N_AST module-file record.
            debug_records += bool(kind & 0xE0 or kind == 0x32)
    return {"architecture": "arm64", "uuid": image_uuid,
            "debugRecordCount": debug_records, "hasDWARF": has_dwarf,
            "hasDebugInfo": has_debug_info}


def read_binary_metadata(path):
    path = Path(path)
    try:
        return _metadata(path.read_bytes(), path.name)
    except OSError as error:
        raise BinaryPrivacyError(f"Cannot read app binary metadata for {path.name}.") from error


def verify_app_binaries(app, build_roots=()):
    """Fail closed for debug maps or personal/build paths in either executable."""
    prefixes = {b"/Users/", b"/home/"}
    for root in (Path.home(), *build_roots):
        value = str(Path(root).resolve()).rstrip("/")
        if value:
            prefixes.add((value + "/").encode())
    inventory = []
    for relative in EXECUTABLES:
        path = Path(app) / relative
        try:
            data = path.read_bytes()
        except OSError as error:
            raise BinaryPrivacyError(f"Cannot read app executable {path.name}.") from error
        metadata = _metadata(data, path.name)
        if metadata["debugRecordCount"] or metadata["hasDWARF"]:
            raise BinaryPrivacyError(f"{path.name} still contains debug records; strip it before signing.")
        if any(prefix in data for prefix in prefixes):
            # Report the category without copying a private value into logs.
            raise BinaryPrivacyError(f"{path.name} contains an embedded home or build-machine path.")
        inventory.append({"executable": relative.as_posix(), **metadata})
    return inventory


def _run(command, operation):
    result = subprocess.run([str(value) for value in command], capture_output=True, text=True)
    if result.returncode:
        raise BinaryPrivacyError(f"{operation} failed: {(result.stderr or result.stdout).strip()}")
    return result


def verify_app_symbols(app, symbols):
    """Require usable, UUID-matched private symbols for both shipped images."""
    app, symbols = Path(app).resolve(), Path(symbols).resolve()
    if symbols.is_relative_to(app):
        raise BinaryPrivacyError("Debug symbols must be stored outside the app bundle.")
    for relative in EXECUTABLES:
        executable = app / relative
        dwarf = symbols / f"{executable.name}.dSYM/Contents/Resources/DWARF/{executable.name}"
        debug = read_binary_metadata(dwarf)
        if debug["uuid"] != read_binary_metadata(executable)["uuid"] or not debug["hasDebugInfo"]:
            raise BinaryPrivacyError(f"Missing or mismatched debug symbols for {executable.name}.")


def prepare_app_binaries(app, symbols, build_roots=()):
    """Generate matching dSYMs before stripping only staged executable copies."""
    app, symbols = Path(app).resolve(), Path(symbols).resolve()
    if symbols.is_relative_to(app):
        raise BinaryPrivacyError("Debug symbols must be stored outside the app bundle.")
    if symbols.exists() and (not symbols.is_dir() or any(symbols.iterdir())):
        raise BinaryPrivacyError("Debug symbol output must be a new or empty directory.")
    symbols.mkdir(parents=True, exist_ok=True, mode=0o700)
    for relative in EXECUTABLES:
        executable = app / relative
        original = read_binary_metadata(executable)
        dsym = symbols / f"{executable.name}.dSYM"
        generated = _run(["/usr/bin/xcrun", "dsymutil", "--arch", "arm64", "--verify",
                          executable, "-o", dsym], f"Debug symbol generation for {executable.name}")
        if re.search(r"\bwarning:", generated.stdout + generated.stderr, re.IGNORECASE):
            (symbols / f"{executable.name}-dsymutil.log").write_text(generated.stdout + generated.stderr)
            raise BinaryPrivacyError(f"Debug symbol generation for {executable.name} reported warnings; refusing to strip incomplete symbols.")
        dwarf = dsym / "Contents/Resources/DWARF" / executable.name
        debug = read_binary_metadata(dwarf)
        if debug["uuid"] != original["uuid"] or not debug["hasDebugInfo"]:
            raise BinaryPrivacyError(f"Missing or mismatched debug symbols for {executable.name}.")
        _run(["/usr/bin/xcrun", "strip", "-S", executable], f"Debug stripping for {executable.name}")
        if read_binary_metadata(executable)["uuid"] != original["uuid"]:
            raise BinaryPrivacyError(f"Stripping changed the UUID for {executable.name}.")
    inventory = verify_app_binaries(app, build_roots)
    verify_app_symbols(app, symbols)
    (symbols / "symbols.json").write_text(json.dumps({"formatVersion": 1, "binaries": inventory}, indent=2) + "\n")
    return inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--symbols", required=True, type=Path)
    parser.add_argument("--build-root", action="append", default=[], type=Path)
    args = parser.parse_args()
    try:
        prepare_app_binaries(args.app, args.symbols, args.build_root)
    except (BinaryPrivacyError, OSError) as error:
        print(f"App binary preparation failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified stripped arm64 app executables; private debug symbols: {args.symbols}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
