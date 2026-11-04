#!/usr/bin/env python3
# Report what an iOS device can actually do, as one JSON object.
#
# frida-core will happily answer lockdown questions without frida-server, which
# makes a bare query_system_parameters() look like success. The real test is
# whether app enumeration / injection works, so that is what we probe.

from __future__ import annotations

import argparse
import json
import sys

import frida


def out(**kw):
    sys.stdout.write(json.dumps(kw, ensure_ascii=False, default=str) + "\n")
    sys.stdout.flush()


def probe(dev):
    """Distinguish three very different states.

    enumerate_ok  -- a mounted Developer Disk Image is enough for frida to list
                     apps and processes.
    injectable    -- only a running frida-server can actually attach. Without it
                     every attach fails, so a dump cannot happen.
    """
    r = {"udid": dev.id, "name": dev.name, "type": dev.type,
         "frida_visible": True, "enumerate_ok": False, "injectable": False,
         "ddi_required": False, "needs_frida_server": False,
         "ios": None, "arch": None, "app_count": 0, "error": None,
         "attach_target": None}
    try:
        sp = dev.query_system_parameters()
        r["ios"] = (sp.get("os") or {}).get("version")
        r["arch"] = sp.get("arch")
    except Exception as e:
        r["error"] = "lockdown: %s" % e

    try:
        r["app_count"] = len(dev.enumerate_applications())
        r["enumerate_ok"] = True
    except frida.NotSupportedError as e:
        msg = str(e)
        r["error"] = msg
        if "Developer Disk Image" in msg:
            r["ddi_required"] = True
        return r
    except Exception as e:
        r["error"] = "%s: %s" % (type(e).__name__, e)
        return r

    # Real injection test: attach to an existing system process, then leave.
    try:
        procs = dev.enumerate_processes()
    except Exception as e:
        r["error"] = "enumerate_processes: %s" % e
        return r
    for name in ("SpringBoard", "backboardd", "launchd"):
        target = next((p for p in procs if p.name == name), None)
        if target is None:
            continue
        try:
            session = dev.attach(target.pid)
            session.detach()
            r["injectable"] = True
            r["attach_target"] = "%s:%d" % (name, target.pid)
            return r
        except Exception as e:
            r["error"] = "attach %s: %s" % (name, e)

    if not r["injectable"]:
        r["needs_frida_server"] = True
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", default=None)
    ap.add_argument("--remote", default=None)
    ap.add_argument("--all", action="store_true", help="probe every ios-ish device")
    ap.add_argument("--timeout", type=float, default=15.0)
    args = ap.parse_args()

    targets = []
    if args.remote:
        targets.append(frida.get_device_manager().add_remote_device(args.remote))
    elif args.udid:
        targets.append(frida.get_device(args.udid, timeout=args.timeout))
    else:
        # Skip frida's pseudo devices (local macOS host, socket, gdb stub) and
        # keep anything that actually looks like an iOS target.
        pseudo = {"local", "socket", "barebone"}
        for d in frida.enumerate_devices():
            if d.id in pseudo:
                continue
            if d.type != "usb" and not args.all:
                continue
            targets.append(d)

    if not targets:
        out(devices=[], error="no frida devices")
        return 1
    for d in targets:
        try:
            out(**probe(d))
        except Exception as e:
            out(udid=d.id, name=d.name, type=d.type, frida_visible=True,
                injectable=False, ddi_required=False, error="%s: %s" % (type(e).__name__, e))
    return 0


if __name__ == "__main__":
    sys.exit(main())
