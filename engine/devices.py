#!/usr/bin/env python3
# Device and app inventory via pymobiledevice3 only -- no Homebrew tools needed,
# which is what makes the app portable to a clean Mac.
#
#   devices.py list                 -> NDJSON one line per connected device
#   devices.py apps --udid X        -> NDJSON one line per installed app
#   devices.py uninstall --udid X --bundle-id Y
#   devices.py lookup --udid X --bundle-id Y
#   devices.py install --udid X --ipa PATH
#   devices.py openurl --udid X --url itms-apps://...
#   devices.py waitinstall --udid X --bundle-id Y [--timeout 900]
#
# Output is NDJSON so the GUI can consume it without parsing CLI noise.

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path


def emit(**kw):
    sys.stdout.write(json.dumps(kw, ensure_ascii=False, default=str) + "\n")
    sys.stdout.flush()


def _run(coro):
    return asyncio.run(coro)


def cmd_list(args):
    """One NDJSON line per connected device, enriched via lockdown."""
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.usbmux import list_devices

    async def go():
        devs = await list_devices()
        for d in devs:
            udid = getattr(d, "serial", None)
            conn = getattr(d, "connection_type", "") or ""
            try:
                c = await create_using_usbmux(serial=udid)
                info = c.short_info or {}
                emit(e="device", udid=udid,
                     name=info.get("DeviceName", ""),
                     product_type=info.get("ProductType", ""),
                     version=info.get("ProductVersion", ""),
                     build=info.get("BuildVersion", ""),
                     connection=info.get("ConnectionType", conn) or conn,
                     paired=True)
            except Exception as ex:
                emit(e="device", udid=udid, name="", product_type="", version="",
                     build="", connection=conn, paired=False, error=str(ex))
    _run(go())
    return 0


def cmd_apps(args):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    async def go():
        c = await create_using_usbmux(serial=args.udid)
        inst = InstallationProxyService(c)
        apps = await inst.get_apps(application_type="Any")
        for bid, meta in (apps or {}).items():
            path = meta.get("Path", "") or ""
            signer = meta.get("SignerIdentity", "") or ""
            if bid.startswith("com.apple.") or path.startswith("/Applications/"):
                kind = "system"
            elif "Apple iPhone OS Application Signing" in signer:
                kind = "appStore"
            else:
                kind = "plain"
            emit(e="app", bundle_id=bid,
                 name=meta.get("CFBundleDisplayName") or meta.get("CFBundleName") or bid,
                 executable=meta.get("CFBundleExecutable", "") or "",
                 version=meta.get("CFBundleShortVersionString")
                        or meta.get("CFBundleVersion") or "?",
                 build=str(meta.get("CFBundleVersion", "") or ""),
                 path=path, container=meta.get("Container", "") or "",
                 kind=kind, app_type=meta.get("ApplicationType", ""))
    _run(go())
    return 0


def cmd_uninstall(args):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    async def go():
        c = await create_using_usbmux(serial=args.udid)
        inst = InstallationProxyService(c)
        await inst.uninstall(args.bundle_id)
    _run(go())
    emit(e="ok", m="已卸载 %s" % args.bundle_id)
    return 0


def cmd_lookup(args):
    """Report whether one bundle id is present, and at which version."""
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    async def go():
        c = await create_using_usbmux(serial=args.udid)
        inst = InstallationProxyService(c)
        apps = await inst.get_apps(application_type="Any")
        meta = (apps or {}).get(args.bundle_id) or {}
        emit(e="result", installed=bool(meta),
             version=str(meta.get("CFBundleShortVersionString") or meta.get("CFBundleVersion") or ""),
             path=meta.get("Path", ""),
             signer=meta.get("SignerIdentity", ""))
    _run(go())
    return 0


_STAGE = "PublicStaging"


# installd only says "verification failed" in English, which is no help when the
# real cause is that the receipt belongs to a different Apple ID than the phone.
_INSTALL_HINTS = [
    ("BundleiTunesMetadataVersionMismatch",
     "包里的 iTunesMetadata 版本和 App 自身版本对不上，这个包可能不完整"),
    ("ApplicationVerificationFailed",
     "签名校验没过。最常见的原因是手机登录的 Apple ID 和下载用的不是同一个，"
     "请在手机“设置 → App Store”里确认登录的是同一个账号"),
    ("No code signature", "包里没有代码签名"),
    ("MissingServiceCFBundleDisplayName", "系统应用扩展缺失，换一个 App 试试"),
    ("kMDInstallErrorDomain", "installd 拒绝了这次安装"),
    ("0xe8000067", "installd 内部错误，通常是重试一次就好"),
    ("Insufficient storage", "手机存储空间不够"),
]


def _install_error(text: str) -> str:
    for key, hint in _INSTALL_HINTS:
        if key.lower() in text.lower():
            return "%s\n原始信息: %s" % (hint, text[:300])
    return text[:400]


# Opening a URL on the device is what makes the no-credentials route work: the
# phone's own App Store is already signed in, so the user taps 获取 and Apple never
# asks this tool for a password or a second factor. uiopen ships with the
# Dopamine/procursus base and frida-server spawns it as root.
_UIOPEN = ["/var/jb/usr/bin/uiopen", "/var/jb/bin/uiopen", "/usr/bin/uiopen"]


def cmd_openurl(args):
    import frida

    try:
        dev = frida.get_device(args.udid, timeout=20) if args.udid \
            else frida.get_usb_device(timeout=20)
    except Exception as e:
        emit(e="error", m="连不上设备（这一步需要 frida-server 在跑）: %s" % e)
        return 1
    last = None
    for cand in _UIOPEN:
        try:
            pid = dev.spawn([cand, args.url])
            dev.resume(pid)
            emit(e="ok", m="已在手机上打开这个 App 的详情页")
            return 0
        except Exception as e:
            last = e
    emit(e="error", m="设备上打不开链接。没装 uiopen 的话在 Sileo 里装一个；错误: %s" % last)
    return 1


def cmd_waitinstall(args):
    """Poll installd until the bundle shows up, so the dump can start by itself."""
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    async def go():
        c = await create_using_usbmux(serial=args.udid)
        inst = InstallationProxyService(c)
        waited = 0.0
        while waited < args.timeout:
            apps = await inst.get_apps(application_type="Any")
            meta = (apps or {}).get(args.bundle_id)
            if meta:
                return meta
            await asyncio.sleep(2)
            waited += 2
            emit(e="progress", phase="waitinstall", done=waited, total=args.timeout)
        return None

    try:
        meta = _run(go())
    except Exception as e:
        emit(e="error", m="查询安装状态失败: %s: %s" % (type(e).__name__, e))
        return 1
    if not meta:
        emit(e="error", m="等了 %d 秒还没看到 %s 装上。请在手机上点「获取」，"
                          "或解锁屏幕后重试" % (int(args.timeout), args.bundle_id))
        return 1
    emit(e="ok", m="手机上已装好 %s %s" % (
        args.bundle_id, meta.get("CFBundleShortVersionString", "?")))
    return 0


def cmd_install(args):
    """Install an App Store .ipa, handing installd its FairPlay SINF.

    installd rejects an encrypted App Store payload that arrives as a plain zip;
    the receipt inside Payload/<app>/SC_Info/ has to be lifted into the install
    request as ApplicationSINF, with iTunesMetadata alongside it. That is what
    ideviceinstaller does, done here over pymobiledevice3 so the app stays free of
    Homebrew.
    """
    import store
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    ipa = Path(args.ipa)
    if not ipa.exists():
        emit(e="error", m="找不到要安装的文件: %s" % ipa)
        return 1
    try:
        info = store.package_info(ipa)
    except store.StoreError as e:
        emit(e="error", m=str(e))
        return 1
    emit(e="log", m="包内识别: %s %s（可执行文件 %s）" % (
        info["bundle_id"], info["version"] or "?", info["exe"]))
    if not info["sinf"]:
        emit(e="log", level="warn", m="包里没有找到 SC_Info/*.sinf，"
                                      "这个包可能本来就不带壳")

    remote_dir = "/" + _STAGE
    remote_name = "ds_store_%s.ipa" % info["bundle_id"]
    package_path = "%s/%s" % (_STAGE, remote_name)

    def on_percent(percent, *_extra):
        # pymobiledevice3 forwards its own trailing args tuple, so accept extras.
        emit(e="progress", phase="install", done=float(percent or 0), total=100.0)

    async def go():
        c = await create_using_usbmux(serial=args.udid)
        inst = InstallationProxyService(c)
        existing = await inst.get_apps(application_type="Any")
        if info["bundle_id"] in (existing or {}) and not args.force:
            return ("already", existing[info["bundle_id"]])
        async with AfcService(c) as afc:
            await afc.makedirs(remote_dir)
            size = ipa.stat().st_size
            emit(e="log", m="上传 %.1f MB 到手机 /var/mobile/Media/%s" % (
                size / 1048576.0, package_path))
            await afc.push(str(ipa), remote_dir + "/" + remote_name,
                           progress_bar=False)
            opts = {}
            if info["bundle_id"]:
                opts["CFBundleIdentifier"] = info["bundle_id"]
            if info["sinf"]:
                opts["ApplicationSINF"] = info["sinf"]
            if info["metadata"]:
                opts["iTunesMetadata"] = info["metadata"]
            try:
                await inst.send_package("Install", opts, on_percent, package_path)
            finally:
                try:
                    await afc.rm_single(remote_dir + "/" + remote_name, force=True)
                except Exception:
                    pass
        # installd reports completion before SpringBoard has registered the app,
        # so poll rather than trusting the callback alone.
        for _ in range(40):
            apps = await inst.get_apps(application_type="Any")
            meta = (apps or {}).get(info["bundle_id"])
            if meta:
                return ("installed", meta)
            await asyncio.sleep(0.75)
        return ("missing", {})

    try:
        state, meta = _run(go())
    except Exception as e:
        emit(e="error", m="安装失败: %s" % _install_error(
            "%s: %s" % (type(e).__name__, e)))
        return 1

    if state == "already":
        emit(e="ok", m="手机上已经装有 %s（%s），跳过下载直接砸壳" % (
            info["bundle_id"], meta.get("CFBundleShortVersionString", "?")),
            already=True, bundle_id=info["bundle_id"])
        return 0
    if state == "missing":
        emit(e="error", m="installd 说装完了，但应用列表里找不到 %s。"
                          "可能是手机存储不足或 SpringBoard 未刷新，重试一次看看" % info["bundle_id"])
        return 1
    emit(e="log", m="安装完成: %s" % (meta.get("Path", "") or "路径未知"))
    emit(e="ok", m="已安装 %s %s" % (info["bundle_id"], info["version"]))
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    p = sub.add_parser("apps"); p.add_argument("--udid", required=True)
    u = sub.add_parser("uninstall"); u.add_argument("--udid", required=True)
    u.add_argument("--bundle-id", required=True)
    l = sub.add_parser("lookup"); l.add_argument("--udid", required=True)
    l.add_argument("--bundle-id", required=True)
    i = sub.add_parser("install"); i.add_argument("--udid", required=True)
    i.add_argument("--ipa", required=True)
    i.add_argument("--force", action="store_true",
                   help="install even when the app is already present")
    o = sub.add_parser("openurl"); o.add_argument("--udid", required=True)
    o.add_argument("--url", required=True)
    w = sub.add_parser("waitinstall"); w.add_argument("--udid", required=True)
    w.add_argument("--bundle-id", required=True)
    w.add_argument("--timeout", type=float, default=900.0)
    args = ap.parse_args()
    try:
        if args.cmd == "list":
            return cmd_list(args)
        if args.cmd == "apps":
            return cmd_apps(args)
        if args.cmd == "lookup":
            return cmd_lookup(args)
        if args.cmd == "install":
            return cmd_install(args)
        if args.cmd == "openurl":
            return cmd_openurl(args)
        if args.cmd == "waitinstall":
            return cmd_waitinstall(args)
        return cmd_uninstall(args)
    except Exception as e:
        emit(e="error", m="%s: %s" % (type(e).__name__, e))
        return 1


if __name__ == "__main__":
    sys.exit(main())
