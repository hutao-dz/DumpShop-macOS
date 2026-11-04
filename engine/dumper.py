#!/usr/bin/env python3
# Dump a decrypted IPA off a jailbroken iOS device.
#
# Speaks NDJSON on stdout so a GUI can render live progress.
#
# frida 17 removed the built-in ObjC bridge, so the injected agent is pure
# Mach-O/memory work. The bundle itself is staged on-device by a root shell
# (frida-server spawns /var/jb/bin/sh as uid 0) and pulled back over AFC, which
# is both faster and immune to the app sandbox.

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

import frida

MH_MAGIC, MH_CIGAM = 0xFEEDFACE, 0xCEFAEDFE
MH_MAGIC_64, MH_CIGAM_64 = 0xFEEDFACF, 0xCFFAEDFE
FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64 = 0x21, 0x2C

_wlock = threading.Lock()


def emit(**kw):
    with _wlock:
        sys.stdout.write(json.dumps(kw, ensure_ascii=False, default=str) + "\n")
        sys.stdout.flush()


def log(msg, **kw):
    emit(e="log", m=str(msg), **kw)


def stage(name):
    emit(e="stage", n=name)


def fail(msg, **kw):
    emit(e="error", m=str(msg), **kw)
    raise SystemExit(1)


# ---------------------------------------------------------------- injected agent
AGENT = r"""
'use strict';

function parseEncInfo(base) {
  const magic = base.readU32() >>> 0;
  let is64;
  if (magic === 0xFEEDFACF || magic === 0xCFFAEDFE) is64 = true;
  else if (magic === 0xFEEDFACE || magic === 0xCEFAEDFE) is64 = false;
  else return null;
  const ncmds = base.add(16).readU32();
  let off = is64 ? 32 : 28;
  for (let i = 0; i < ncmds; i++) {
    const cmd = base.add(off).readU32();
    const cmdsize = base.add(off + 4).readU32();
    if (cmdsize === 0 || cmdsize > 0x100000) break;
    if (cmd === 0x21 || cmd === 0x2C) {
      return {
        cryptoff: base.add(off + 8).readU32(),
        cryptsize: base.add(off + 12).readU32(),
        cryptid: base.add(off + 16).readU32()
      };
    }
    off += cmdsize;
  }
  return null;
}

rpc.exports = {
  modules: function (bp) {
    const res = [];
    const prefix = bp.charAt(bp.length - 1) === '/' ? bp : bp + '/';
    Process.enumerateModules().forEach(function (m) {
      if (m.path.indexOf(prefix) !== 0) return;
      let info = null;
      try { info = parseEncInfo(m.base); } catch (e) { info = null; }
      res.push({ path: m.path, base: m.base.toString(), enc: info });
    });
    return res;
  },
  readCrypt: function (baseStr, cryptoff, cryptsize) {
    // frida 17 dropped Memory.readByteArray(addr, n) in favour of the pointer method.
    var where = ptr(baseStr).add(cryptoff);
    if (typeof where.readByteArray === 'function') return where.readByteArray(cryptsize);
    return Memory.readByteArray(where, cryptsize);
  }
};
"""

# ------------------------------------------------------------- device-side staging
# $3 is a marker file written only after tar has fully closed, so the host never
# races a half-written archive.
STAGE_SH = r"""#!/bin/sh
# $1 = bundle dir, $2 = output tar, $3 = done marker (all under /var/mobile/Media)
BUNDLE="$1"; OUT="$2"; DONE="$3"
TAR=""
for c in /var/jb/usr/bin/tar /var/jb/bin/tar /usr/bin/tar /bin/tar; do
  [ -x "$c" ] && TAR="$c" && break
done
rm -f "$OUT" "$DONE" 2>/dev/null
if [ -z "$TAR" ]; then echo "3:no-tar" > "$DONE"; exit 3; fi
"$TAR" -cf "$OUT" -C "$BUNDLE" . 2>/dev/null
rc=$?
if [ $rc -ne 0 ]; then echo "$rc:failed" > "$DONE"; exit $rc; fi
echo "0:$(wc -c < "$OUT" 2>/dev/null | tr -d ' ')" > "$DONE"
exit 0
"""

SH_CANDIDATES = ["/var/jb/bin/sh", "/bin/sh", "/usr/bin/sh"]


# ------------------------------------------------------------------- Mach-O logic
def iter_slices(buf):
    if len(buf) < 4:
        return
    be = struct.unpack(">I", buf[:4])[0]
    if be in (FAT_MAGIC, FAT_MAGIC_64):
        is64 = be == FAT_MAGIC_64
        nfat = struct.unpack(">I", buf[4:8])[0]
        hdr, off = (32 if is64 else 20), 8
        for _ in range(nfat):
            if off + hdr > len(buf):
                return
            if is64:
                offset = struct.unpack(">Q", buf[off + 8:off + 16])[0]
            else:
                offset = struct.unpack(">I", buf[off + 8:off + 12])[0]
            yield offset
            off += hdr
        return
    if struct.unpack("<I", buf[:4])[0] in (MH_MAGIC, MH_MAGIC_64, MH_CIGAM, MH_CIGAM_64):
        yield 0


def find_crypt_cmd(buf, slice_off):
    magic = struct.unpack("<I", buf[slice_off:slice_off + 4])[0]
    if magic in (MH_MAGIC_64, MH_CIGAM_64):
        is64 = True
    elif magic in (MH_MAGIC, MH_CIGAM):
        is64 = False
    else:
        return None
    e = ">" if magic in (MH_CIGAM, MH_CIGAM_64) else "<"
    ncmds = struct.unpack(e + "I", buf[slice_off + 16:slice_off + 20])[0]
    off = slice_off + (32 if is64 else 28)
    for _ in range(ncmds):
        if off + 8 > len(buf):
            return None
        cmd, cmdsize = struct.unpack(e + "II", buf[off:off + 8])
        if cmdsize == 0 or cmdsize > 0x100000:
            break
        if cmd in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64):
            co, cs, ci = struct.unpack(e + "III", buf[off + 8:off + 20])
            return cmd, off, co, cs, ci
        off += cmdsize
    return None


def cryptid_of(path):
    try:
        buf = path.read_bytes()
    except OSError:
        return None
    ids = []
    for so in iter_slices(buf):
        info = find_crypt_cmd(buf, so)
        if info:
            ids.append(info[4])
    return ids or None


def is_macho(head):
    if len(head) < 4:
        return False
    return (struct.unpack("<I", head)[0] in (MH_MAGIC, MH_MAGIC_64, MH_CIGAM, MH_CIGAM_64)
            or struct.unpack(">I", head)[0] in (FAT_MAGIC, FAT_MAGIC_64))


def patch_local_binary(path, cryptoff_mem, blob):
    buf = bytearray(path.read_bytes())
    done = False
    for slice_off in iter_slices(bytes(buf)):
        info = find_crypt_cmd(bytes(buf), slice_off)
        if not info:
            continue
        cmd, cmd_off, cryptoff, cryptsize, cryptid = info
        if cryptid == 0:
            done = True
            continue
        if cryptoff != cryptoff_mem:
            return "cryptoff mismatch (%d != %d)" % (cryptoff, cryptoff_mem)
        if cryptsize != len(blob):
            return "size mismatch (%d != %d)" % (cryptsize, len(blob))
        t = slice_off + cryptoff
        buf[t:t + cryptsize] = blob
        buf[cmd_off + 16:cmd_off + 20] = struct.pack("<I", 0)
        done = True
    if not done:
        return "no crypt load command"
    path.write_bytes(bytes(buf))
    return None


# ------------------------------------------------------------------------ AFC glue
def pmd_binary(args):
    if args.pymobiledevice3:
        return args.pymobiledevice3
    cand = Path(args.python_hint or sys.executable).parent / "pymobiledevice3"
    return str(cand) if cand.exists() else (shutil.which("pymobiledevice3") or "")


def afc(pmd, udid, *a, timeout=600, capture=False):
    env = dict(os.environ)
    if udid:
        env["PYMOBILEDEVICE3_UDID"] = udid
    r = subprocess.run([pmd, "afc"] + list(a), env=env, timeout=timeout,
                       stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                       stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise RuntimeError("afc %s failed: %s" % (
            a[0], r.stderr.decode("utf-8", "replace").strip()[-300:]))
    return r.stdout.decode("utf-8", "replace") if capture else ""


def run_token(work) -> str:
    """Per-job tag used in every device-side filename.

    Two dumps running at once must never delete each other's staging archive, so
    each one only ever touches files carrying its own token. The work directory is
    already a fresh UUID per job, which makes a good unique seed.
    """
    import re
    t = re.sub(r"[^0-9a-zA-Z]", "", str(Path(work).name)).lower()
    return "k" + (t[:10] or "0")


def stage_bundle(pmd, udid, bundle_path, work, app_name):
    """Archive the .app on-device as root, then pull it back over AFC."""
    dev = frida.get_device(udid, timeout=20) if udid else frida.get_usb_device(timeout=20)
    slug = "".join(c if c.isalnum() else "_" for c in app_name)[:40]
    token = run_token(work)
    tar_name = "ds_%s_%s.tar" % (token, slug)
    done_name = "ds_%s_%s.done" % (token, slug)
    script_name = "ds_%s_stage.sh" % token
    (work / script_name).write_text(STAGE_SH)
    afc(pmd, udid, "push", str(work / script_name), "/")

    def listed():
        try:
            return afc(pmd, udid, "ls", "/", timeout=60, capture=True)
        except Exception:
            return ""

    try:
        afc(pmd, udid, "rm", "/" + done_name, timeout=60)
    except Exception:
        pass

    spawned = None
    for sh in SH_CANDIDATES:
        try:
            spawned = dev.spawn([sh, "/var/mobile/Media/" + script_name,
                                 bundle_path, "/var/mobile/Media/" + tar_name,
                                 "/var/mobile/Media/" + done_name])
            log("用 %s 以 root 打包 bundle" % sh)
            break
        except Exception:
            continue
    if spawned is None:
        raise RuntimeError("设备上找不到可执行的 sh，无法以 root 打包")
    dev.resume(spawned)

    marker = None
    deadline = time.time() + 600
    while time.time() < deadline:
        if done_name in listed():
            # afc has no cat; pull the tiny marker instead.
            mk_local = work / done_name
            try:
                if mk_local.exists():
                    mk_local.unlink()
                afc(pmd, udid, "pull", "/" + done_name, str(mk_local), timeout=60)
                txt = mk_local.read_text(errors="replace").strip()
            except Exception:
                txt = ""
            # Only trust the marker once it carries a newline-terminated status.
            if txt and ":" in txt:
                marker = txt
                break
        time.sleep(1.0)
    if marker is None:
        raise RuntimeError("等待设备打包完成超时")
    code, _, size_txt = marker.partition(":")
    if code != "0":
        raise RuntimeError("设备打包失败: %s" % marker)
    expected = int(size_txt) if size_txt.isdigit() else 0

    tar_local = work / tar_name
    afc(pmd, udid, "pull", "/" + tar_name, str(tar_local), timeout=1800)
    got = tar_local.stat().st_size
    if expected and got != expected:
        raise RuntimeError("tar 大小不符（本地 %d，设备 %d）" % (got, expected))
    emit(e="progress", phase="pull", done=got, total=got, files_done=1, files_total=1)
    log("已拉回 bundle %.1f MB" % (got / 1e6))
    return tar_local


def text_entropy(path, limit=300000):
    """Shannon entropy of the __TEXT,__text bytes, or None if not resolvable."""
    try:
        d = path.read_bytes()
    except OSError:
        return None
    if len(d) < 32 or struct.unpack("<I", d[:4])[0] not in (MH_MAGIC_64, MH_MAGIC):
        return None
    is64 = struct.unpack("<I", d[:4])[0] == MH_MAGIC_64
    ncmds = struct.unpack("<I", d[16:20])[0]
    off = 32 if is64 else 28
    for _ in range(ncmds):
        if off + 8 > len(d):
            return None
        cmd, cmdsize = struct.unpack("<II", d[off:off + 8])
        if cmdsize == 0:
            break
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack("<I", d[off + 56:off + 60])[0]
            so = off + 72
            for _ in range(nsects):
                if so + 56 > len(d):
                    break
                sect = d[so:so + 16].split(b"\x00")[0]
                seg = d[so + 16:so + 32].split(b"\x00")[0]
                if seg == b"__TEXT" and sect == b"__text":
                    size = struct.unpack("<Q", d[so + 40:so + 48])[0]
                    fileoff = struct.unpack("<I", d[so + 48:so + 52])[0]
                    body = d[fileoff:fileoff + min(size, limit)]
                    if len(body) < 64:
                        return None
                    counts = {}
                    for b in body:
                        counts[b] = counts.get(b, 0) + 1
                    n = len(body)
                    return -sum((v / n) * __import__("math").log2(v / n) for v in counts.values())
                so += 80
        off += cmdsize
    return None


def clear_cryptid_flag(path):
    """Set cryptid to 0 without touching code bytes.

    Only safe once the caller has proved the text is already plaintext, which is
    how pre-decrypted installs keep a stale cryptid=1 marker.
    """
    buf = bytearray(path.read_bytes())
    done = False
    for slice_off in iter_slices(bytes(buf)):
        info = find_crypt_cmd(bytes(buf), slice_off)
        if not info:
            continue
        cmd, cmd_off, cryptoff, cryptsize, cryptid = info
        if cryptid != 0:
            buf[cmd_off + 16:cmd_off + 20] = struct.pack("<I", 0)
            done = True
    if done:
        path.write_bytes(bytes(buf))
    return done


# Real FairPlay ciphertext sits near 8 bits/byte; ordinary arm64 code measures
# roughly 4.5-6.8. Anything under this line is already plaintext.
PLAINTEXT_ENTROPY_MAX = 7.3


def sweep_device(pmd, udid, token=None):
    """Delete this job's ds_* staging artefacts from /var/mobile/Media.

    Runs on both success and failure so an aborted dump cannot quietly eat the
    user's storage. With a token, only that job's files go, which is what makes
    parallel dumps safe; a token-less sweep is the idle-time garbage collection.
    """
    try:
        listing = afc(pmd, udid, "ls", "/", timeout=60, capture=True)
    except Exception:
        return 0
    gone = 0
    want = ("ds_" + token) if token else "ds_"
    for name in listing.splitlines():
        name = name.strip().lstrip("/")
        if not name.startswith(want):
            continue
        try:
            afc(pmd, udid, "rm", "/" + name, timeout=60)
            gone += 1
        except Exception:
            pass
    return gone



def still_list(root):
    """Relative paths of every Mach-O under root that still carries cryptid != 0."""
    out = []
    for q in sorted(root.rglob("*")):
        if not q.is_file():
            continue
        try:
            with open(q, "rb") as fh:
                if not is_macho(fh.read(4)):
                    continue
        except OSError:
            continue
        ids = cryptid_of(q)
        if ids and any(i != 0 for i in ids):
            out.append(os.path.relpath(q, root))
    return out


def run_devices(args, sub, extra, timeout=1200, quiet=False):
    """Call devices.py and forward its NDJSON into this job's own stream.

    Reusing the engine's log channel means the GUI renders install/lookup output
    without knowing that a second process produced it.
    """
    py = args.python_hint or sys.executable
    script = Path(__file__).resolve().parent / "devices.py"
    cmd = [py, str(script), sub] + list(extra)
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout)
    except subprocess.TimeoutExpired:
        fail("%s 超时（%d 秒）" % (sub, timeout))
    events = []
    for raw in proc.stdout.decode("utf-8", "replace").splitlines():
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        try:
            ev = json.loads(raw)
        except json.JSONDecodeError:
            continue
        events.append(ev)
        kind = ev.get("e")
        if kind in ("log", "progress"):
            emit(**ev)
        elif kind == "ok":
            emit(e="log", m=ev.get("m", ""))
        elif kind == "error":
            emit(e="log", level="error", m=ev.get("m", ""))
        elif kind == "result":
            # Never forward a child's "result": the GUI reads that event as "the
            # dump is finished" and would stop on a lookup reply.
            if quiet:
                continue
            bits = ["%s=%s" % (k, v) for k, v in ev.items()
                    if k != "e" and v not in ("", None, False)]
            emit(e="log", m=" ".join(bits)[:220])
    for raw in proc.stderr.decode("utf-8", "replace").splitlines():
        if raw.strip():
            log(raw.strip()[:300], level="warn")
    return proc.returncode, events


def installed_version(args):
    rc, events = run_devices(args, "lookup", ["--udid", args.udid or "",
                                              "--bundle-id", args.bundle_id], quiet=True)
    for ev in events:
        if ev.get("e") == "result":
            return bool(ev.get("installed")), str(ev.get("version") or "")
    return False, ""


def fetch_from_store(args, work):
    """Download + install an App Store app that is not on the phone yet.

    Returns True when this job put the app on the device, so the caller can offer
    to take it back off afterwards.
    """
    import store

    cache_root = Path(args.cache_root)
    cache_root.mkdir(parents=True, exist_ok=True)

    stage("store-login")
    try:
        path, label = store.find_ipatool(args.ipatool, None, cache_root / "bin/ipatool")
        if not path:
            path = store.download_ipatool(cache_root / "bin/ipatool",
                                          on_line=lambda s: log(s))
            label = "已自动下载"
    except (store.StoreError, SystemExit) as e:
        fail("准备 ipatool 失败: %s" % e)
    log("使用 ipatool %s（%s）" % (store.IPATOOL_VERSION, label))
    info = store.auth_info(path, cache_root, args.store_profile)
    if not info.get("logged_in"):
        hint = info.get("error") or ""
        fail("当前地区下载会话未初始化%s。请运行随包的初始化下载会话脚本。"
             % (("：" + hint) if hint else ""))
    log("Apple ID 会话有效（%s）" % (info.get("email") or info.get("name") or "?"))

    stage("store-download")
    dst = work / "store" / ("%s.ipa" % args.bundle_id)
    # The SAP signer is needed by the download endpoints too, not only by sign-in,
    # so make sure it is in ipatool's cache before asking it to talk to the store.
    try:
        store.warm_unicorn(on_line=log)
    except store.StoreError as e:
        log("签名组件未就绪: %s" % e, level="warn")
    dst.parent.mkdir(parents=True, exist_ok=True)
    mb = [0]

    def report(n):
        mb[0] = n / 1048576.0
        emit(e="progress", phase="download", done=n, total=0)

    try:
        got = store.download(path, cache_root, args.bundle_id, dst, on_progress=report,
                             purchase=not args.store_no_purchase,
                             profile=args.store_profile,
                             expected_account=args.store_expected_account)
    except store.StoreError as e:
        fail("从 App Store 下载失败: %s" % e)
    except Exception as e:  # noqa: BLE001
        fail("从 App Store 下载异常: %s: %s" % (type(e).__name__, e))
    log("下载完成 %s（%.1f MB）" % (got.name, got.stat().st_size / 1048576.0))
    try:
        probe = store.encrypt_probe(got)
        log("包内检查: cryptid=%s，加密段 %s MB，SINF=%s，收据=%s" % (
            probe.get("cryptid"), probe.get("cryptsize_mb"),
            "有" if probe.get("has_sinf") else "无",
            "有" if probe.get("has_metadata") else "无"))
        if probe.get("cryptid") == 0:
            log("注意: 这个包的二进制 cryptid=0，Apple 直接给了明文（越狱设备上并不常见），"
                "砸壳结果可能只是把它原样取回", level="warn")
    except store.StoreError as e:
        log("包内检查失败: %s" % e, level="warn")

    stage("store-install")
    rc, events = run_devices(args, "install", ["--udid", args.udid or "", "--ipa", str(got)])
    if rc != 0:
        if any("已经装有" in str(ev.get("m", "")) for ev in events):
            log("手机上已经装有这个 App，继续砸壳")
            got.unlink(missing_ok=True)
            return False
        fail("安装到手机失败，详见上面的 installd 报错")
    # The encrypted download has served its purpose; requirement is to keep only
    # the decrypted output on the Mac, so drop the wrapped copy.
    got.unlink(missing_ok=True)
    shutil.rmtree(work / "store", ignore_errors=True)
    return True


def install_on_phone(args):
    """Open the product page on the phone and wait for the user's own App Store.

    This is the route that needs no credentials at all: the device is already
    signed in, so Apple authenticates the tap locally instead of asking this tool
    for a password or a second factor.
    """
    stage("store-phone")
    url = args.store_url or ("itms-apps://itunes.apple.com/app/id%s" % args.bundle_id)
    rc, _ = run_devices(args, "openurl", ["--udid", args.udid or "", "--url", url])
    if rc != 0:
        fail("在手机上打开 App Store 失败，看上面的原因")
    log("手机上应该已经跳到这个 App 的详情页，点「获取」开始下载；"
        "下载完成后会自动继续砸壳，最长等 15 分钟")
    rc, _ = run_devices(args, "waitinstall",
                        ["--udid", args.udid or "", "--bundle-id", args.bundle_id,
                         "--timeout", "900"], timeout=1000)
    if rc != 0:
        fail("没等到 %s 装好。可以在手机上装完之后再砸一次" % args.bundle_id)
    log("检测到手机上已经装好，继续砸壳")
    return True


# ---------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description="Dump a decrypted IPA (NDJSON output)")
    # Required in practice, but not declared so: --sweep must run without them.
    ap.add_argument("--bundle-id", default=None)
    ap.add_argument("--udid", default=None)
    ap.add_argument("-o", "--output-dir", dest="output_dir", default=None)
    ap.add_argument("--app-label", default=None, help="display name used for the IPA file")
    ap.add_argument("--workdir", default=None)
    ap.add_argument("--pymobiledevice3", default=None)
    ap.add_argument("--python-hint", default=None, help="python3 in the same venv as pmd3")
    ap.add_argument("--no-resume", action="store_true")
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--from-store", action="store_true", dest="from_store",
                    help="download and install from the App Store first")
    ap.add_argument("--store-on-device", action="store_true", dest="store_on_device",
                    help="let the phone's own App Store download it (no Apple ID here)")
    ap.add_argument("--store-url", default=None, dest="store_url",
                    help="itms-apps:// product page to open on the device")
    ap.add_argument("--ipatool", default=None, help="path to a bundled ipatool binary")
    ap.add_argument("--store-profile", choices=("CN", "US", "JP", "HK", "TW"), default="CN")
    ap.add_argument("--store-no-purchase", action="store_true")
    ap.add_argument("--store-expected-account", default="")
    ap.add_argument("--cache-root", default=str(Path.home() /
                    "Library/Application Support/DumpShop"), dest="cache_root")
    ap.add_argument("--uninstall-after", action="store_true", dest="uninstall_after",
                    help="remove the app from the device once the dump is verified")
    ap.add_argument("--uninstall-if-installed-by-us", action="store_true",
                    dest="uninstall_if_placed",
                    help="remove the app only if this job installed it from the store")
    ap.add_argument("--sweep", action="store_true",
                    help="only delete leftover ds_* staging files, then exit")
    args = ap.parse_args()

    if args.sweep:
        pmd0 = pmd_binary(args)
        if not pmd0 or not args.udid:
            fail("需要 --udid 和 pymobiledevice3 才能清理设备")
        n = sweep_device(pmd0, args.udid)
        emit(e="result", removed=n)
        log("已清理手机上 %d 个残留临时文件" % n)
        return 0

    missing = [n for n, v in (("--bundle-id", args.bundle_id),
                              ("-o/--output-dir", args.output_dir),
                              ("--workdir", args.workdir)) if not v]
    if missing:
        ap.error("缺少必需参数: " + ", ".join(missing))

    t0 = time.time()
    pmd = pmd_binary(args)
    if not pmd:
        fail("找不到 pymobiledevice3，无法通过 AFC 拉取 bundle。在「环境」页安装后重试。")

    work = Path(args.workdir)
    if work.exists():
        shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)

    # Route B: the app may not be on the phone at all, so fetch it from the store
    # first and remember whether we are the one who put it there.
    placed_by_us = False
    if args.from_store:
        stage("store-check")
        have, ver = installed_version(args)
        if have:
            log("手机上已经装有 %s（%s），跳过下载" % (args.bundle_id, ver or "?"))
        elif args.store_on_device:
            placed_by_us = install_on_phone(args)
        else:
            log("手机上没有这个 App，从 App Store 下载安装后再砸壳")
            placed_by_us = fetch_from_store(args, work)

    stage("device")
    try:
        device = (frida.get_device(args.udid, timeout=args.timeout) if args.udid
                  else frida.get_usb_device(timeout=args.timeout))
    except frida.InvalidArgumentError as e:
        fail("设备找不到: %s" % e)
    log("已连接 %s (%s)" % (device.name, device.id))

    stage("injection-test")
    try:
        procs = device.enumerate_processes()
        probe_target = None
        for pname in ("SpringBoard", "backboardd", "launchd"):
            probe_target = next((x for x in procs if x.name == pname), None)
            if probe_target is not None:
                break
        ps = device.attach(probe_target.pid)
        ps.detach()
        log("注入探测通过 (attach %s)" % probe_target.name)
    except frida.NotSupportedError:
        fail("frida 读不到进程列表，Developer Image 未挂载。在「环境」页点「挂载 Developer Image」。")
    except Exception as e:
        msg = str(e)
        if "unlocked" in msg:
            fail("手机处于锁屏状态，请先解锁。")
        fail("无法注入到设备进程（%s）。设备上没有运行 frida-server 的话就是这个原因。" % msg)

    stage("enumerate")
    apps = {}
    saw_full_list = False
    for attempt in range(1, 7):
        try:
            apps = {a.identifier: a for a in device.enumerate_applications(scope="full")}
            saw_full_list = True
        except Exception:
            # The plain list only contains *running* apps, so treating it as the
            # whole device would make an idle app look absent. Retry instead.
            log("全量应用枚举失败（第 %d 次）: %s" % (attempt, sys.exc_info()[1]))
            time.sleep(2)
        if args.bundle_id in apps:
            break
        # A freshly installed app is registered with installd before frida's
        # SpringBoard snapshot catches up, so give it a moment rather than failing.
        if attempt < 6:
            log("等 SpringBoard 注册 %s（第 %d 次）" % (args.bundle_id, attempt))
            time.sleep(3)
    app = apps.get(args.bundle_id)
    bundle_path = (getattr(app, "parameters", None) or {}).get("path") or "" if app else ""
    app_display = str(app.name) if app is not None else ""
    if not bundle_path:
        # installd knows the truth even when SpringBoard's snapshot is unavailable,
        # which is what happens when several dumps enumerate at once.
        rc_l, evs_l = run_devices(args, "lookup", ["--udid", args.udid or "",
                                                   "--bundle-id", args.bundle_id],
                                  quiet=True)
        meta_l = next((x for x in evs_l if x.get("e") == "result"), None) or {}
        if meta_l.get("installed"):
            bundle_path = (meta_l.get("path") or "").strip()
            log("frida 没给出路径，改用 installd 的: %s" % (bundle_path or "空"))
    if not bundle_path:
        fail("设备上看不到 %s%s" % (args.bundle_id,
                                  "" if saw_full_list else "（应用列表也没能读全）"))
    if not app_display:
        app_display = args.app_label or args.bundle_id
    app_name = Path(bundle_path).name
    log("目标: %s (%s)" % (app_display, args.bundle_id))
    log("bundle: %s" % bundle_path)

    payload = work / "Payload"
    payload.mkdir(parents=True)
    app_dest = payload / app_name
    app_dest.mkdir(parents=True)

    stage("pull")
    try:
        tar_local = stage_bundle(pmd, args.udid, bundle_path, work, app_name)
        subprocess.run(["tar", "-xf", str(tar_local), "-C", str(app_dest)], check=True)
        tar_local.unlink(missing_ok=True)
    except subprocess.CalledProcessError as e:
        fail("本地解包失败: %s" % e)
    except Exception as e:
        fail("拉取 bundle 失败: %s" % e)

    stage("dump")
    try:
        pid = device.spawn([args.bundle_id])
        session = device.attach(pid)
        script = session.create_script(AGENT)
        script.on("message", lambda m, d: log("agent: %s" % m))
        script.load()
    except Exception as e:
        msg = str(e)
        if "not, or could not be, unlocked" in msg or "unlocked" in msg:
            fail("手机当前是锁屏状态，系统不允许启动 App。请解锁手机后重试。")
        if "sandbox" in msg.lower():
            fail("启动被沙箱拒绝: %s" % msg)
        fail("spawn/attach 失败: %s" % e)
    log("已挂起启动 pid %d" % pid)

    if not args.no_resume:
        device.resume(pid)
        time.sleep(2.5)

    mods = script.exports_sync.modules(bundle_path)
    log("bundle 内已加载 %d 个模块" % len(mods))
    dumped = skipped = failed = 0
    for m in mods:
        rel = os.path.relpath(m["path"], bundle_path)
        local = app_dest / rel
        enc = m.get("enc")
        if not local.exists() or not enc or enc["cryptid"] == 0:
            skipped += 1
            continue
        try:
            blob = script.exports_sync.read_crypt(m["base"], enc["cryptoff"], enc["cryptsize"])
        except Exception as e:
            log("%s 内存读取失败: %s" % (rel, e), level="warn")
            failed += 1
            continue
        if not blob:
            failed += 1
            continue
        err = patch_local_binary(local, enc["cryptoff"], bytes(blob))
        if err:
            log("%s: %s" % (rel, err), level="warn")
            failed += 1
            continue
        dumped += 1
        log("%s cryptid 1->0 (%.1f MB)" % (rel, len(blob) / 1e6))
        emit(e="progress", phase="dump", done=dumped, total=len(mods), current=rel)

    for closer in ("detach",):
        try:
            getattr(session, closer)()
        except Exception:
            pass
    try:
        device.kill(pid)
    except Exception:
        pass

    if dumped == 0:
        if failed == 0 and skipped > 0:
            # Not a failure of the pipeline: this app simply has no shell to remove.
            fail("这个应用没有 FairPlay 壳（%d 个模块的 cryptid 本来就是 0），不需要砸壳。"
                 "一般是 TrollStore / 自签装的，或者已经被解密工具处理过" % skipped)
        fail("没有任何二进制被解密（跳过 %d，失败 %d）" % (skipped, failed))

    # App extensions live in separate processes, so the main app's memory has no
    # image of them. Spawn each one by its own bundle id and repeat the read.
    pending = still_list(app_dest)
    if pending:
        log("%d 个 App 扩展待处理（需宿主进程，通常拿不到）" % len(pending))
        for rel in pending:
            local = app_dest / rel
            exedir = app_dest.parent / rel.split("/")[0] if False else None
            appex_dir = (app_dest / rel).parent
            plist = appex_dir / "Info.plist"
            if not plist.exists():
                continue
            try:
                with open(plist, "rb") as fh:
                    ex_bid = plistlib.load(fh).get("CFBundleIdentifier")
            except Exception:
                continue
            if not ex_bid:
                continue
            try:
                epid = device.spawn([ex_bid])
                esess = device.attach(epid)
                escript = esess.create_script(AGENT)
                escript.on("message", lambda m, dd: None)
                escript.load()
                device.resume(epid)
                time.sleep(1.5)
                ebundle = str(appex_dir)
                got = 0
                for m in escript.exports_sync.modules(ebundle):
                    enc = m.get("enc")
                    if not enc or enc["cryptid"] == 0:
                        continue
                    rel2 = os.path.relpath(m["path"], bundle_path)
                    tgt = app_dest / rel2
                    if not tgt.exists():
                        continue
                    blob = escript.exports_sync.read_crypt(m["base"], enc["cryptoff"],
                                                           enc["cryptsize"])
                    if not blob or patch_local_binary(tgt, enc["cryptoff"], bytes(blob)):
                        continue
                    got += 1
                    dumped += 1
                    log("%s cryptid 1->0 (扩展)" % rel2)
                for fn in ("detach",):
                    try:
                        getattr(esess, fn)()
                    except Exception:
                        pass
                try:
                    device.kill(epid)
                except Exception:
                    pass
                if got:
                    try:
                        pending.remove(rel)
                    except ValueError:
                        pass
                else:
                    log("%s 未能解密（扩展可能拒绝启动或受保护）" % rel, level="warn")
            except Exception as e:
                log("%s 无法解密: appex 不能独立启动，需宿主进程加载" % rel, level="warn")

    stage("verify")
    still = list(pending)
    for p in app_dest.rglob("*"):
        if not p.is_file():
            continue
        try:
            with open(p, "rb") as fh:
                head = fh.read(4)
        except OSError:
            continue
        if not is_macho(head):
            continue
        try:
            os.chmod(p, 0o755)
        except OSError:
            pass
        ids = cryptid_of(p)
        if ids and any(i != 0 for i in ids):
            still.append(os.path.relpath(p, app_dest))
    still = sorted(set(still))
    stale_cleared = []
    genuine = []
    for rel in still:
        target = app_dest / rel
        ent = text_entropy(target)
        if ent is not None and ent < PLAINTEXT_ENTROPY_MAX:
            if clear_cryptid_flag(target):
                stale_cleared.append((rel, round(ent, 2)))
                continue
        genuine.append((rel, None if ent is None else round(ent, 2)))
    for rel, e in stale_cleared:
        log("%s 内容本就是明文(熵 %.2f)，已清除残留 cryptid 标记" % (rel, e))
    for rel, e in genuine:
        log("仍处于加密: %s%s" % (rel, "" if e is None else " (熵 %.2f)" % e), level="warn")
    still = [rel for rel, _ in genuine]

    ver, disp = "?", app_display
    exe = ""
    info = app_dest / "Info.plist"
    if info.exists():
        with open(info, "rb") as fh:
            pl = plistlib.load(fh)
        ver = str(pl.get("CFBundleShortVersionString", "?"))
        disp = str(pl.get("CFBundleDisplayName") or pl.get("CFBundleName") or app_display)
        exe = str(pl.get("CFBundleExecutable") or "")

    # Name it 软件名-版本号-是否全解密.ipa so the verdict is readable in Finder.
    tag = "全解密" if not still else "带壳%d项" % len(still)
    label = args.app_label or disp or args.bundle_id
    safe = "".join(c if (c.isalnum() or c in "._- ") else "_" for c in label).strip() or args.bundle_id
    out = Path(args.output_dir) / ("%s-%s-%s.ipa" % (safe, ver, tag))
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    stage("pack")
    subprocess.run(["zip", "-qry", str(out), "Payload"], cwd=str(work), check=True)
    shutil.rmtree(work, ignore_errors=True)

    emit(e="result", ipa=str(out), app=disp, bundle_id=args.bundle_id, version=ver,
         binaries=dumped, still_encrypted=still,
         mb=round(out.stat().st_size / 1e6, 1), seconds=round(time.time() - t0, 1),
         exe=exe)

    # Only touch the device again once the decrypted package is verified on disk,
    # so a failed run can never lose the copy that was just pulled off the phone.
    should_remove = args.uninstall_after or (placed_by_us and args.uninstall_if_placed)
    if should_remove and not still:
        stage("store-cleanup")
        rc, _ = run_devices(args, "uninstall", ["--udid", args.udid or "",
                                                "--bundle-id", args.bundle_id])
        if rc == 0:
            log("已卸载手机上的 %s，脱壳包只保留在电脑" % args.bundle_id)
        else:
            log("卸载 %s 失败，手机上先留着，可手动删除" % args.bundle_id, level="warn")
    elif placed_by_us:
        log("这个 App 是本次从 App Store 装的，按你的设置保留在手机上了")

    return 0


def _cleanup(argv):
    """Best-effort device sweep so a failed run leaves nothing behind."""
    try:
        ns = argparse.ArgumentParser(add_help=False)
        ns.add_argument("--udid", default=None)
        ns.add_argument("--python-hint", default=None)
        ns.add_argument("--pymobiledevice3", default=None)
        ns.add_argument("--workdir", default=None)
        args, _ = ns.parse_known_args(argv)
        pmd = pmd_binary(args)
        if pmd and args.udid:
            # Only our own files: another dump may well be mid-transfer right now.
            n = sweep_device(pmd, args.udid,
                             run_token(args.workdir) if args.workdir else None)
            if n:
                log("已清理手机上 %d 个临时文件" % n)
        # The wrapped copy pulled from the App Store is never worth keeping around.
        if args.workdir:
            shutil.rmtree(Path(args.workdir) / "store", ignore_errors=True)
    except Exception:
        pass


if __name__ == "__main__":
    try:
        rc = main()
    except SystemExit as e:
        _cleanup(sys.argv[1:])
        raise
    except Exception as e:
        _cleanup(sys.argv[1:])
        try:
            fail("%s: %s" % (type(e).__name__, e))
        except SystemExit:
            raise
    else:
        _cleanup(sys.argv[1:])
        sys.exit(rc)
