#!/usr/bin/env python3
# Report the on-disk size of every installed app bundle, as NDJSON.
#
# One root shell does the whole sweep: frida-server spawns /var/jb/bin/sh as
# uid 0, so `du` can see every bundle. Results land in /var/mobile/Media and are
# read back over AFC. A marker file is written last so the host never reads a
# half-written listing.

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import frida

SCRIPT = r"""#!/bin/sh
# $1 = output listing, $2 = marker
DU=""
for c in /var/jb/usr/bin/du /var/jb/bin/du /usr/bin/du /bin/du; do
  [ -x "$c" ] && DU="$c" && break
done
rm -f "$1" "$2" 2>/dev/null
if [ -z "$DU" ]; then echo "3:no-du" > "$2"; exit 3; fi
"$DU" -sk /private/var/containers/Bundle/Application/*/*.app > "$1" 2>/dev/null
echo "0:$(wc -l < "$1" | tr -d ' ')" > "$2"
exit 0
"""


def emit(**kw):
    sys.stdout.write(json.dumps(kw, ensure_ascii=False, default=str) + "\n")
    sys.stdout.flush()


def afc(pmd, udid, *a, timeout=300):
    env = dict(os.environ)
    env["PYMOBILEDEVICE3_UDID"] = udid
    return subprocess.run([pmd, "afc"] + list(a), env=env, timeout=timeout,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    ap.add_argument("--pymobiledevice3", default=None)
    ap.add_argument("--python-hint", default=None)
    ap.add_argument("--timeout", type=float, default=180.0)
    args = ap.parse_args()

    pmd = args.pymobiledevice3
    if not pmd:
        cand = Path(args.python_hint or sys.executable).parent / "pymobiledevice3"
        pmd = str(cand) if cand.exists() else "pymobiledevice3"

    # Tagged per process so a second size sweep, or a dump running in parallel,
    # can never read or delete the other's files.
    tag = "as%05x" % (os.getpid() & 0xFFFFF)
    tmp = Path("/tmp")
    local_script = tmp / ("ds_%s.sh" % tag)
    local_script.write_text(SCRIPT)
    if afc(pmd, args.udid, "push", str(local_script), "/").returncode != 0:
        emit(e="error", m="推送 du 脚本失败")
        return 1

    out_name, done_name = "ds_%s.txt" % tag, "ds_%s.done" % tag
    afc(pmd, args.udid, "rm", "/" + done_name)
    try:
        dev = frida.get_device(args.udid, timeout=20)
        pid = dev.spawn(["/var/jb/bin/sh", "/var/mobile/Media/" + local_script.name,
                         "/var/mobile/Media/" + out_name,
                         "/var/mobile/Media/" + done_name])
        dev.resume(pid)
    except Exception as e:
        emit(e="error", m="启动 root 打包进程失败: %s" % e)
        return 1

    deadline = time.time() + args.timeout
    marker = None
    while time.time() < deadline:
        if afc(pmd, args.udid, "ls", "/").stdout.decode().find(done_name) >= 0:
            mk = tmp / done_name
            if afc(pmd, args.udid, "pull", "/" + done_name, str(mk)).returncode == 0:
                txt = mk.read_text(errors="replace").strip()
                if ":" in txt:
                    marker = txt
                    break
        time.sleep(0.6)
    if marker is None:
        emit(e="error", m="等待 du 完成超时")
        return 1
    if not marker.startswith("0:"):
        emit(e="error", m="du 失败: %s" % marker)
        return 1

    local_out = tmp / out_name
    if afc(pmd, args.udid, "pull", "/" + out_name, str(local_out)).returncode != 0:
        emit(e="error", m="拉取 du 结果失败")
        return 1

    n = 0
    for line in local_out.read_text(errors="replace").splitlines():
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        kb_txt, path = parts[0].strip(), parts[1].strip()
        if not kb_txt.isdigit():
            continue
        emit(e="size", path=path, kb=int(kb_txt))
        n += 1
    emit(e="done", count=n)

    for f in ("/" + out_name, "/" + done_name, "/" + local_script.name):
        afc(pmd, args.udid, "rm", f, timeout=60)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        emit(e="error", m="%s: %s" % (type(e).__name__, e))
        sys.exit(1)
