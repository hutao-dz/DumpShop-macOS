#!/usr/bin/env python3
"""Runtime wrapper for the vendored fairplay-decrypt implementation."""

from __future__ import annotations

import json
import os
import runpy
import struct
import sys
import zipfile
from pathlib import Path

ARM64 = 0x0100000C
FAT32 = b"\xca\xfe\xba\xbe"
FAT64 = b"\xca\xfe\xba\xbf"
THIN32 = b"\xce\xfa\xed\xfe"
THIN64 = b"\xcf\xfa\xed\xfe"
LC_ENCRYPTION_INFO = 0x21
LC_ENCRYPTION_INFO_64 = 0x2C

source = os.environ.get("FAIRPLAY_DECRYPT_SOURCE", "").strip()
if source:
    root = Path(source)
    sys.path.insert(0, str(root / "credential-retrieval"))
    sys.path.insert(0, str(root))


def run_retrieve(args: list[str]) -> None:
    import retrieve

    previous = sys.argv
    sys.argv = ["retrieve.py", *args]
    try:
        retrieve.main()
    finally:
        sys.argv = previous


def run_decrypt(args: list[str]) -> None:
    import decrypt

    previous = sys.argv
    sys.argv = ["decrypt.py", *args]
    try:
        decrypt.main()
    finally:
        sys.argv = previous


def scan_slice(data: bytes, base: int, size: int) -> tuple[int, int]:
    if base < 0 or size < 28 or base + size > len(data):
        raise ValueError("invalid Mach-O slice bounds")
    magic = struct.unpack_from("<I", data, base)[0]
    if magic not in (0xFEEDFACE, 0xFEEDFACF):
        raise ValueError(f"unsupported Mach-O slice magic {magic:#x}")
    is64 = magic == 0xFEEDFACF
    ncmds = struct.unpack_from("<I", data, base + 16)[0]
    if ncmds > 1000:
        raise ValueError("invalid Mach-O command count")
    offset = base + (32 if is64 else 28)
    end = base + size
    commands = 0
    encrypted = 0
    for _ in range(ncmds):
        if offset + 8 > end:
            raise ValueError("truncated Mach-O load command")
        command, command_size = struct.unpack_from("<II", data, offset)
        if command_size < 8 or offset + command_size > end:
            raise ValueError("invalid Mach-O load command size")
        if command in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64):
            if command_size < 20:
                raise ValueError("short encryption info command")
            cryptid = struct.unpack_from("<I", data, offset + 16)[0]
            commands += 1
            if cryptid != 0:
                encrypted += 1
        offset += command_size
    return commands, encrypted


def scan_macho(data: bytes) -> tuple[int, int]:
    if len(data) < 8:
        return 0, 0
    magic = data[:4]
    slices: list[tuple[int, int]] = []
    if magic in (FAT32, FAT64):
        count = struct.unpack_from(">I", data, 4)[0]
        if not 0 < count <= 64:
            raise ValueError("invalid FAT architecture count")
        entry_size = 32 if magic == FAT64 else 20
        table_end = 8 + count * entry_size
        if table_end > len(data):
            raise ValueError("truncated FAT architecture table")
        for index in range(count):
            offset = 8 + index * entry_size
            if magic == FAT64:
                _cpu, _subtype, base, size, _align, _reserved = struct.unpack_from(
                    ">IIQQII", data, offset
                )
            else:
                _cpu, _subtype, base, size, _align = struct.unpack_from(
                    ">IIIII", data, offset
                )
            slices.append((base, size))
    elif magic in (THIN32, THIN64):
        slices.append((0, len(data)))
    else:
        return 0, 0
    commands = 0
    encrypted = 0
    for base, size in slices:
        found, wrapped = scan_slice(data, base, size)
        commands += found
        encrypted += wrapped
    return commands, encrypted


def verify(ipa_path: Path) -> int:
    result = {
        "all_decrypted": False,
        "macho_images": 0,
        "encrypted_images": 0,
        "files_scanned": 0,
        "errors": [],
    }
    try:
        with zipfile.ZipFile(ipa_path) as archive:
            for info in archive.infolist():
                if info.is_dir():
                    continue
                result["files_scanned"] += 1
                with archive.open(info) as member:
                    head = member.read(4)
                if head not in (FAT32, FAT64, THIN32, THIN64):
                    continue
                data = archive.read(info)
                commands, encrypted = scan_macho(data)
                result["macho_images"] += commands
                result["encrypted_images"] += encrypted
        result["all_decrypted"] = (
            result["macho_images"] > 0 and result["encrypted_images"] == 0
        )
        if result["macho_images"] == 0:
            result["errors"].append("没有找到带加密信息的 Mach-O")
    except Exception as error:
        result["errors"].append(str(error))
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["all_decrypted"] else 1


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: fairplay_helper retrieve|decrypt|verify ...", file=sys.stderr)
        return 2
    command = sys.argv[1]
    args = sys.argv[2:]
    if command == "python":
        # Narrow launcher for bundled stdlib-only engine scripts. This is not a
        # replacement for the optional external Frida development environment.
        if not args:
            print("usage: engine-runtime script.py [args] | -c code | -", file=sys.stderr)
            return 2
        if args[0] == "-c":
            if len(args) < 2:
                return 2
            sys.argv = ["-c", *args[2:]]
            exec(compile(args[1], "<string>", "exec"), {"__name__": "__main__"})
        elif args[0] == "-":
            sys.argv = args
            exec(compile(sys.stdin.read(), "<stdin>", "exec"), {"__name__": "__main__"})
        else:
            sys.argv = args
            sys.path.insert(0, str(Path(args[0]).resolve().parent))
            runpy.run_path(args[0], run_name="__main__")
        return 0
    if command == "retrieve":
        try:
            run_retrieve(args)
            return 0
        except SystemExit:
            raise
        except Exception as error:
            print(f"错误: {error}", file=sys.stderr)
            return 1
    if command == "decrypt":
        try:
            run_decrypt(args)
            return 0
        except SystemExit:
            raise
        except Exception as error:
            print(f"错误: {error}", file=sys.stderr)
            return 1
    if command == "verify" and len(args) == 1:
        return verify(Path(args[0]))
    print(f"unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
