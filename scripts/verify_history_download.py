#!/usr/bin/env python3
"""Verify an authorized historical download; never prints account credentials."""
import argparse
import importlib.util
import json
from pathlib import Path
import platform
import sys
import zipfile


def main():
    parser = argparse.ArgumentParser()
    for name in ("adapter", "tool", "cache", "bundle-id", "version-id", "expected-version", "output", "report"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--profile", default="HK")
    args = parser.parse_args()
    adapter = Path(args.adapter).resolve()
    sys.path.insert(0, str(adapter.parent))
    spec = importlib.util.spec_from_file_location("store", adapter)
    store = importlib.util.module_from_spec(spec)
    sys.modules["store"] = store
    spec.loader.exec_module(store)
    tool, cache, output = Path(args.tool), Path(args.cache), Path(args.output)
    if output.exists():
        raise RuntimeError("Verification output already exists; choose a new path")
    info = store.auth_info(tool, cache, args.profile)
    if not info.get("logged_in"):
        raise RuntimeError(info.get("error") or "Download session is not ready")
    ids = store.list_versions(tool, cache, args.bundle_id, args.profile, info["account_id"])
    if args.version_id not in ids["externalVersionIdentifiers"]:
        raise RuntimeError("Requested historical version is absent from Apple's version list")
    print("Version list verified: %d identifiers." % ids["total"], flush=True)
    store.download(tool, cache, args.bundle_id, output, purchase=False, profile=args.profile,
                   expected_account=info["account_id"], external_version_id=args.version_id,
                   expected_version=args.expected_version, timeout=300)
    package = store.package_info(output)
    with zipfile.ZipFile(output) as archive:
        bad = archive.testzip()
        if bad is not None:
            raise RuntimeError("Downloaded archive failed CRC verification")
    result = {"os": platform.system(), "arch": platform.machine(), "profile": args.profile,
              "bundle_id": package["bundle_id"], "version": package["version"],
              "build": package["build"], "externalVersionID": args.version_id,
              "available_version_count": ids["total"], "bytes": output.stat().st_size,
              "zip_crc_passed": True, "purchase_requested": False,
              "decryption_performed": False, "output": str(output)}
    Path(args.report).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
