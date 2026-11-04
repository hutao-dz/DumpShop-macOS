#!/usr/bin/env python3
# Mount the Developer Disk Image the device's iOS version needs.
#
# pymobiledevice3's CLI hard-codes /Applications/Xcode.app when that bundle
# exists, which is root-owned and not writable by a normal user. We point the
# image cache at Application Support instead, so this needs no sudo.
#
# Note: the mobile_image_mounter service tolerates only one open connection per
# lockdown session, so we must not pre-query it before calling auto_mount.

from __future__ import annotations

import argparse
import asyncio
import inspect
import json
import sys
from pathlib import Path


def out(**kw):
    sys.stdout.write(json.dumps(kw, ensure_ascii=False, default=str) + "\n")
    sys.stdout.flush()


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    ap.add_argument("--xcode", default=None)
    ap.add_argument("--version", default=None)
    args = ap.parse_args()

    xcode = args.xcode or str(
        Path.home() / "Library/Application Support/DumpShop/DDDXcode.app")
    Path(xcode).mkdir(parents=True, exist_ok=True)

    try:
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.services.mobile_image_mounter import (
            AlreadyMountedError, auto_mount)
    except ImportError as e:
        out(e="error", m="pymobiledevice3 未安装: %s" % e)
        return 1

    r = create_using_usbmux(serial=args.udid)
    lockdown = await r if inspect.isawaitable(r) else r
    out(e="stage", n="mount", ios="%s (%s)" % (lockdown.product_version,
                                               lockdown.product_type))
    try:
        await auto_mount(lockdown, xcode=xcode, version=args.version)
        out(e="ok", m="Developer Image 挂载完成", already=False)
        return 0
    except AlreadyMountedError:
        out(e="ok", m="Developer Image 已经挂载", already=True)
        return 0
    except Exception as e:
        out(e="error", m="%s: %s" % (type(e).__name__, e))
        return 1


sys.exit(asyncio.run(main()))
