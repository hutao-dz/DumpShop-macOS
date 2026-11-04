#!/usr/bin/env python3
# List installed apps from a device frida can already reach, as NDJSON.
# One line per app, icon inlined as base64 PNG so the GUI needs no network.

from __future__ import annotations

import argparse
import base64
import json
import sys

import frida


def emit(**kw):
    sys.stdout.write(json.dumps(kw, ensure_ascii=False, default=str) + "\n")


def pick_icon(params):
    best = None
    for ic in params.get("icons") or []:
        raw = ic.get("image")
        if isinstance(raw, bytes) and (best is None or len(raw) > len(best)):
            best = raw
    return base64.b64encode(best).decode() if best else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--no-icons", action="store_true")
    args = ap.parse_args()

    dev = frida.get_device(args.udid, timeout=args.timeout)
    try:
        apps = dev.enumerate_applications(scope="full")
    except Exception as e:
        emit(e="error", m="enumerate_applications failed: %s" % e)
        return 1
    for a in sorted(apps, key=lambda x: (x.name or x.identifier).lower()):
        p = dict(a.parameters or {})
        row = {
            "e": "app",
            "bundle_id": a.identifier,
            "name": a.name or a.identifier,
            "version": p.get("version") or "?",
            "build": p.get("build") or "",
            "path": p.get("path") or "",
            "container": (p.get("containers") or {}).get("data") or "",
            "pid": a.pid or 0,
            "system": a.identifier.startswith("com.apple.")
                      or (p.get("path") or "").startswith("/Applications/"),
        }
        if not args.no_icons:
            icon = pick_icon(p)
            if icon:
                row["icon_b64"] = icon
        emit(**row)
    emit(e="done", count=len(apps))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        emit(e="error", m="%s: %s" % (type(e).__name__, e))
        sys.exit(1)
