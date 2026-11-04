#!/usr/bin/env python3
# App Store leg of the pipeline: Apple ID sign-in and package download.
#
# Device I/O deliberately lives in devices.py; this module only talks to Apple's
# store through ipatool and reads the resulting .ipa. dumper.py imports it when
# a job starts from the store instead of from an installed app.
#
# Credential handling: the Apple ID password is typed into ipatool's own prompt
# over a pty, so it never appears in a command line (any same-user process can
# read argv) and we never store it. ipatool keeps the resulting session in the
# macOS Keychain under "ipatool-auth.service" and its cookie jar in the state
# directory we point it at with XDG_DATA_HOME.

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import platform
import re
import shutil
import subprocess
import sys
import threading
import time
import zipfile
from pathlib import Path

IPATOOL_VERSION = "2.7.0"
DOWNLOAD_MAX_ATTEMPTS = 10

# asset id + sha256 of the official release tarball, per Mac architecture.
_ASSETS = {
    "arm64": (626257203,
              "5ae100d4520cf4b3f4374239e5925a9ad9a8dc02abc16bae27479e7ae99aca33"),
    "x86_64": (626257331,
               "05f48994d8b3cfefe7ea1172a0ac0b28715888e9df0af38cf3e490d2ed592263"),
}

# ipatool signs Apple's SAP challenge with a native Unicorn library that it
# fetches from PyPI using a fixed-timeout HTTP client -- on a slow link that
# download always fails and login becomes unretryable. The cache layout below
# mirrors internal/sap/unicorn/cache.go from ipatool 2.7.0, so warming it with
# our own patient, resumable download makes the first sign-in succeed offline-ish
# and needs no change upstream.
UNICORN_VERSION = "2.1.4"
UNICORN_MEMBER = "unicorn/lib/libunicorn.2.dylib"
UNICORN_FILENAME = "libunicorn.2.dylib"
# PyPI's file layout is not derivable from the wheel sha256, so the exact published
# paths are recorded together with the wheel and extracted-library hashes.
_UNICORN = {
    "arm64": ("/packages/6c/ae/4943c6f8524d729ec7d5e69df6407ea05d710fe77471d91cecf3fc64eb57/"
              "unicorn-2.1.4-cp37-abi3-macosx_11_0_arm64.whl",
              "d6c93e0f60328d8f4a1792af3f834137a28050fcc2305f2ec01efe8558a9844e",
              "unicorn-2.1.4-cp37-abi3-macosx_11_0_arm64.whl",
              "7207c8e3d7a63118fb0bca73e01816797fd51b1d8a39a4cbc7abfd562ee59c85"),
    "x86_64": ("/packages/c8/a7/92b47771e2107a201632a199cec91e8a81ee8a071ca6b7e7d600d8c61ac9/"
               "unicorn-2.1.4-cp37-abi3-macosx_10_9_x86_64.whl",
               "2a6f738fab5fabffa56af1e7bbf16ea1e91466c342f8dc64f125bd70f36c6b80",
               "unicorn-2.1.4-cp37-abi3-macosx_10_9_x86_64.whl",
               "51c4a6f3ce22628ecd3acd1c49b921a818ffb989ca2c473134cc7eb06094f256"),
}
# Files are matched against the official wheel sha256 no matter where they come
# from, so a mirror cannot hand us a different binary. Domestic mirrors first:
# files.pythonhosted.org is throttled to a crawl from Chinese networks, which is
# exactly what made ipatool's own sign-in time out.
_PYPI_MIRRORS = [
    "https://mirrors.aliyun.com/pypi",
    "https://mirrors.cloud.tencent.com/pypi",
    "https://mirror.nju.edu.cn/pypi/web",
    "https://pypi.tuna.tsinghua.edu.cn",
    "https://files.pythonhosted.org",
]

_wlock = threading.Lock()


def emit(**kw):
    with _wlock:
        sys.stdout.write(json.dumps(kw, ensure_ascii=False, default=str) + "\n")
        sys.stdout.flush()


def log(msg, **kw):
    emit(e="log", m=str(msg), **kw)


def fail(msg, **kw):
    emit(e="error", m=str(msg), **kw)
    raise SystemExit(1)


class StoreError(RuntimeError):
    pass


# ------------------------------------------------------------------- ipatool home
def host_arch() -> str:
    m = platform.machine().lower()
    return "arm64" if m in ("arm64", "aarch64") else "x86_64"


def macho_arch(path: Path) -> str:
    """Return 'arm64'/'x86_64'/... for a Mach-O, or '' when unreadable.

    A cached binary may be for the wrong Mac, so the header is checked before it
    is trusted.
    """
    try:
        with open(path, "rb") as fh:
            head = fh.read(8)
            if len(head) < 8:
                return ""
            if int.from_bytes(head[:4], "big") in (0xCAFEBABE, 0xCAFEBABF):
                # fat: the first arch header starts at 8 and its cputype is big endian
                fh.seek(8)
                return _cputype(int.from_bytes(fh.read(4), "big"))
            fh.seek(4)
            return _cputype(int.from_bytes(fh.read(4), "little"))
    except OSError:
        return ""


def _cputype(v: int) -> str:
    return {0x0100000C: "arm64", 0x01000007: "x86_64"}.get(v, "")


def state_dir(cache_root: Path, profile: str = "cn") -> Path:
    profile = _clean_profile(profile)
    d = cache_root / "ipatool-state"
    if profile != "cn":
        d = d / "profiles" / profile
    d.mkdir(parents=True, exist_ok=True)
    return d


def _clean_profile(profile: str) -> str:
    """Keep profile names on disk and in the keychain service predictable."""
    text = (profile or "cn").strip().lower()
    if text not in ("cn", "us", "jp", "hk", "tw"):
        raise StoreError("不支持的商店地区")
    return text


def candidate_paths(explicit: str | None, bundle_bin: Path | None,
                    cache_bin: Path) -> list[Path]:
    out: list[Path] = []
    if explicit:
        out.append(Path(explicit))
    if bundle_bin:
        out.append(bundle_bin)
    out.append(cache_bin)
    where = shutil.which("ipatool")
    if where:
        out.append(Path(where))
    return out


def usable(path: Path) -> bool:
    return path.is_file() and os.access(path, os.X_OK) and macho_arch(path) in ("", host_arch())


def find_ipatool(explicit=None, bundle_bin: Path | None = None,
                 cache_bin: Path | None = None) -> tuple[Path, str]:
    """First working ipatool, plus where it came from. Never downloads."""
    cache_bin = cache_bin or (Path.home() / "Library/Application Support/DumpShop/bin/ipatool")
    for p in candidate_paths(explicit, bundle_bin, cache_bin):
        if p.exists() and usable(p):
            return p, _source_label(p, explicit, bundle_bin, cache_bin)
    return Path(""), ""


def _source_label(p: Path, explicit, bundle_bin, cache_bin) -> str:
    """Say where the binary came from, in the words the UI shows."""
    if bundle_bin and p == bundle_bin:
        return "内置"
    if p == cache_bin:
        return "已缓存"
    if "/Contents/Resources/bin/" in str(p):
        return "内置"
    if explicit and p == Path(explicit):
        return "手动指定"
    return "系统 PATH"


def download_ipatool(dst: Path, on_line=None) -> Path:
    """Fetch the official release tarball for this Mac and verify its sha256."""
    arch = host_arch()
    if arch not in _ASSETS:
        raise StoreError("这台 Mac 的架构 %s 没有官方 ipatool 构建" % arch)
    asset_id, want = _ASSETS[arch]
    dst.parent.mkdir(parents=True, exist_ok=True)
    tar = dst.parent / ("ipatool-%s-macos-%s.tar.gz" % (IPATOOL_VERSION, arch))
    url = "https://api.github.com/repos/majd/ipatool/releases/assets/%d" % asset_id
    # GitHub's asset host is slow from some networks, so resume instead of restart.
    for attempt in range(1, 6):
        have = tar.stat().st_size if tar.exists() else 0
        if _sha256(tar) == want:
            break
        if on_line:
            on_line("第 %d 次下载 ipatool（已 %d MB）…" % (attempt, have // 1024 // 1024))
        cmd = ["/usr/bin/curl", "-sSL", "--max-time", "900", "-H",
               "Accept: application/octet-stream"]
        if have:
            cmd += ["-C", "-"]
        cmd += ["-o", str(tar), url]
        subprocess.run(cmd, check=False)
    else:
        if _sha256(tar) != want:
            raise StoreError("ipatool 下载不完整或校验失败，请检查网络后重试")
    if _sha256(tar) != want:
        raise StoreError("ipatool 校验失败（期望 %s…）" % want[:12])
    tmp = dst.parent / "ipatool-unpack"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True, exist_ok=True)
    subprocess.run(["tar", "xzf", str(tar), "-C", str(tmp)], check=True)
    found = sorted(tmp.rglob("ipatool-*"))
    if not found:
        raise StoreError("解压后找不到 ipatool 可执行文件")
    shutil.copy2(found[-1], dst)
    dst.chmod(0o755)
    shutil.rmtree(tmp, ignore_errors=True)
    # Ad-hoc signing keeps Gatekeeper quiet for a downloaded Mach-O we run locally.
    subprocess.run(["codesign", "--force", "-s", "-", str(dst)], check=False,
                   stderr=subprocess.DEVNULL)
    return dst


def _sha256(p: Path) -> str:
    if not p.exists():
        return ""
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def warm_unicorn(on_line=None) -> dict:
    """Make sure ipatool's Unicorn cache is filled, downloading it ourselves."""
    arch = host_arch()
    if arch not in _UNICORN:
        return {"ok": False, "reason": "这台 Mac 的架构 %s 没有可用的签名组件" % arch}
    rel, wheel_sha, name, lib_sha = _UNICORN[arch]
    root = Path.home() / "Library/Caches/ipatool/unicorn" / UNICORN_VERSION
    root.mkdir(parents=True, exist_ok=True)
    dst = root / lib_sha / UNICORN_FILENAME
    if dst.exists() and _sha256(dst) == lib_sha:
        if on_line:
            on_line("ipatool 认证组件已就绪（缓存命中）")
        return {"ok": True, "cached": True, "path": str(dst)}

    wheel = root / ("%s.part" % name)
    got = False
    for base in _PYPI_MIRRORS:
        net = base.split("//", 1)[1].split("/", 1)[0]
        broken = False
        for attempt in range(1, 4):
            if wheel.exists() and _sha256(wheel) == wheel_sha:
                break
            have = wheel.stat().st_size if wheel.exists() else 0
            if on_line:
                on_line("获取 ipatool 认证组件（%s，已 %.1f MB，第 %d 次）"
                        % (net, have / 1048576.0, attempt))
            cmd = ["/usr/bin/curl", "-sS", "-L", "--fail", "-w", "%{http_code}",
                   "-o", str(wheel), "--speed-time", "45", "--speed-limit", "2000",
                   "--max-time", "600"]
            if have:
                cmd += ["-C", "-"]
            cmd += [base + rel]
            r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            code = r.stdout.decode().strip()[-3:]
            if code[:1] in ("4", "5"):
                broken = True
                if on_line:
                    on_line("%s 返回 HTTP %s，换下一个镜像源" % (net, code))
                break
        if not broken and wheel.exists() and _sha256(wheel) == wheel_sha:
            got = True
            break
        wheel.unlink(missing_ok=True)
    if not got:
        raise StoreError("拿不到 ipatool 的认证组件（unicorn %s）。可以手动下载 "
                         "unicorn-2.1.4 wheel 放到 %s 后重试" % (UNICORN_VERSION, root))
    part = wheel
    try:
        with zipfile.ZipFile(part) as z:
            data = z.read(UNICORN_MEMBER)
    except (KeyError, OSError, zipfile.BadZipFile) as e:
        raise StoreError("认证组件解压失败: %s" % e)
    if hashlib.sha256(data).hexdigest() != lib_sha:
        raise StoreError("认证组件内容校验失败")
    dst.parent.mkdir(parents=True, exist_ok=True)
    staged = dst.parent / (".staged-" + UNICORN_FILENAME)
    staged.write_bytes(data)
    staged.chmod(0o755)
    staged.replace(dst)
    part.unlink(missing_ok=True)
    if on_line:
        on_line("ipatool 认证组件已就位")
    return {"ok": True, "cached": False, "path": str(dst)}


def ipatool_env(cache_root: Path, profile: str = "cn") -> dict:
    profile = _clean_profile(profile)
    env = dict(os.environ)
    env["XDG_DATA_HOME"] = str(state_dir(cache_root, profile))
    env["XDG_STATE_HOME"] = env["XDG_DATA_HOME"]
    env["IPATOOL_PROFILE"] = profile
    if profile == "hk":
        env["DUMPSHOP_TLS12"] = "1"
    # Keep TLS certificate verification and TLS 1.3 enabled. Avoid the hybrid
    # ML-KEM handshake on network equipment that interrupts Go's new default.
    # An explicitly configured value always takes precedence.
    debug = env.get("GODEBUG", "")
    if not any(item.strip().startswith("tlsmlkem=") for item in debug.split(",")):
        env["GODEBUG"] = (debug + "," if debug else "") + "tlsmlkem=0"
    return env


def _regional_tool(ipatool: Path, profile: str) -> Path:
    # Keep all existing regional helpers and their Keychain identities intact.
    # The HK helper owns the new HK session and uses TLS 1.2 on this network.
    if _clean_profile(profile) == "hk":
        compatible = ipatool.parent / "ipatool-hk-arm64"
        if compatible.is_file():
            return compatible
    return ipatool

# ------------------------------------------------------------------------- JSON run
def _lines(buf: bytes) -> list[dict]:
    out = []
    for raw in buf.decode("utf-8", "replace").splitlines():
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        try:
            out.append(json.loads(raw))
        except json.JSONDecodeError:
            pass
    return out


def run_json(ipatool: Path, args: list[str], cache_root: Path, timeout=900,
             on_line=None, profile: str = "cn") -> list[dict]:
    ipatool = _regional_tool(ipatool, profile)
    if _clean_profile(profile) != "cn":
        version = subprocess.run([str(ipatool), "--version"], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, timeout=15)
        if version.returncode or b"dumpshop-profiles" not in version.stdout:
            raise StoreError("缺少多地区专用下载组件，请重新安装完整应用包")
    try:
        proc = subprocess.run([str(ipatool)] + args + ["--format", "json", "--non-interactive"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env=ipatool_env(cache_root, profile), timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise StoreError("连接 App Store 超时：下载组件在 %d 秒内未完成，请检查网络后重试" % timeout) from error
    events = _lines(proc.stdout) + _lines(proc.stderr)
    if on_line:
        for ev in events:
            on_line(ev)
    if proc.returncode != 0 or any(ev.get("success") is False for ev in events):
        raise StoreError(_explain(events, proc))
    return events


def _explain(events: list[dict], proc) -> str:
    for ev in events:
        if ev.get("success") is False or ev.get("level") == "error":
            msg = ev.get("error") or ev.get("msg") or ""
            if msg:
                return _friendly(msg)
    err = proc.stderr.decode("utf-8", "replace").strip()
    out = proc.stdout.decode("utf-8", "replace").strip()
    return _friendly((err or out or "ipatool 退出码 %d" % proc.returncode)[-400:])


_ERROR_HINTS = [
    ("keyring", "还没有登录 Apple ID（钥匙串里没有 App Store 会话）"),
    ("did not complete verification",
     "验证码不对或已过期。这个接口不会推送验证码，需要你在受信设备上重新生成一个 6 位码；"
     "更省事的做法是改用 App 专用密码当作密码，见登录面板的说明"),
    ("invalid account information", "Apple ID 或密码不对，请重新登录"),
    ("password", "Apple ID 或密码不对，请重新登录"),
    ("2fa", "需要 6 位双重认证验证码"),
    ("auth code", "需要 6 位双重认证验证码"),
    ("purchasing paid apps is not supported",
     "该软件需要付费，暂不支持代购或砸壳。若这个账号已经购买过，请确认地区和 Apple ID 是否匹配"),
    ("license is required",
     "这个账号没有取得过该软件的许可。免费软件会自动尝试取得许可；付费软件暂不支持代购，"
     "请改用已经购买过这个软件的 Apple ID"),
    ("could not be found", "App Store 里搜不到这个 bundle id（可能已下架，或不属于当前商店地区）"),
    ("storefront", "Apple ID 的商店地区和这个 App 不一致"),
    ("network", "网络无法连接 App Store"),
    ("keychain", "macOS 钥匙串拒绝访问，请在弹窗里点“始终允许”"),
]


def _friendly(msg: str) -> str:
    if "（原始信息：" in msg and msg.startswith(("DNS 解析失败", "连接 App Store 超时或中断")):
        return msg
    kind = _network_failure_kind(msg)
    if kind:
        hint = ("DNS 解析失败，无法找到 App Store 服务器。请检查 Mac 的网络、DNS 或代理连接。"
                if kind == "dns" else
                "连接 App Store 超时或中断。请检查 Mac 的网络或代理连接。")
        return "%s（原始信息：%s）" % (hint, msg[-400:])
    low = msg.lower()
    for key, hint in _ERROR_HINTS:
        if key in low:
            return "%s（原始信息：%s）" % (hint, msg[:200])
    return msg[:400]


def _network_failure_kind(message: str) -> str:
    low = message.lower()
    if any(token in low for token in ("no such host", "temporary failure in name resolution",
                                      "nodename nor servname", "dns 解析失败")):
        return "dns"
    if any(token in low for token in ("i/o timeout", "operation timed out", "connection timed out",
                                      "timeout awaiting response headers", "connection reset", "connection refused",
                                      "network is unreachable", "tls handshake timeout",
                                      "context deadline exceeded", "连接 app store 超时",
                                      "tls: bad record mac", "broken pipe")):
        return "connection"
    if "unexpected eof" in low and any(token in low for token in ("download", "request", "read tcp")):
        return "connection"
    if (re.search(r"\beof[\s)\]）'\"]*$", low)
            and any(token in low for token in ("request failed", "http request", "round trip", "read tcp"))):
        return "connection"
    if any("unexpected download response status: %d" % status in low
           for status in (408, 500, 502, 503, 504)):
        return "connection"
    return ""


# ------------------------------------------------------------------------- auth
def auth_info(ipatool: Path, cache_root: Path, profile: str = "cn") -> dict:
    if not ipatool or not ipatool.exists():
        return {"logged_in": False, "binary": False, "error": "未找到 ipatool"}
    try:
        events = run_json(ipatool, ["auth", "info"], cache_root, timeout=90,
                          profile=profile)
    except SystemExit:
        raise
    except StoreError as e:
        text = str(e)
        # A missing keyring item simply means "not signed in yet", nothing scary.
        quiet = "尚未登录" in text or "keyring" in text.lower()
        return {"logged_in": False, "binary": True, "error": "" if quiet else text}
    for ev in events:
        if ev.get("success"):
            return _auth_summary(ev, profile)
    return {"logged_in": False, "binary": True, "error": "未登录"}


_STOREFRONTS = {"143465": "cn", "143441": "us", "143462": "jp",
               "143463": "hk", "143470": "tw"}


def _auth_summary(event: dict, profile: str) -> dict:
    profile = _clean_profile(profile)
    storefront = str(event.get("storefront", "")).split("-", 1)[0]
    region = _STOREFRONTS.get(storefront, "")
    email = str(event.get("email") or "").strip().lower()
    if (region and region != profile) or (profile != "cn" and not region):
        return {"logged_in": False, "binary": True,
                "error": "Apple 账号实际商店地区与所选地区不符，或无法确认地区，请用对应地区账号重新初始化"}
    return {"logged_in": bool(email), "binary": True,
            "name": event.get("name", ""), "email": _mask(email),
            "account_id": hashlib.sha256(email.encode()).hexdigest() if email else "",
            "region": region.upper()}


def _mask(email: str) -> str:
    if "@" not in email:
        return email
    who, dom = email.split("@", 1)
    keep = who[:2]
    return "%s%s@%s" % (keep, "*" * max(1, len(who) - len(keep)), dom)


def _login_session(ipatool: Path, cache_root: Path, email: str, password: str,
                   code, on_line, fetch_code, profile: str = "cn") -> None:
    """Drive `ipatool auth login` over a pty so the password stays out of argv.

    ipatool treats "interactive" as a flag, not a tty probe, so omitting
    --non-interactive makes it prompt for the password and, if Apple asks, the
    2FA code -- in the same process, which also lets a code arriving late be
    answered without restarting the sign-in.

    Prompts and the masked echo go to stderr, the JSON result goes to stdout, so
    the two are read separately: stderr is only ever scanned for a prompt to
    answer, stdout is only ever parsed for the outcome.

    `code` answers the first second-factor prompt without asking again; further
    prompts go through `fetch_code`, which for the GUI means popping the dialog.
    Raises StoreError when Apple rejects the attempt; returns on success.
    """
    import pty
    import select

    ipatool = _regional_tool(ipatool, profile)
    argv = [str(ipatool), "auth", "login", "--email", email, "--format", "json"]
    master, slave = pty.openpty()
    # ipatool calls term.MakeRaw on stdin, which needs a real terminal, but it
    # never draws anything there -- the pty exists purely to satisfy that call.
    proc = subprocess.Popen(argv, stdin=slave, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=ipatool_env(cache_root, profile))
    os.close(slave)

    prompts = ""          # accumulated stderr, reset after each answered prompt
    stdout_buf = b""
    answered_password = False
    # Only time spent waiting on the child counts against the budget, so a person
    # looking up a code on their phone is never timed out mid-action.
    budget = 420.0
    spent = 0.0
    supplied = [code] if code else []

    def next_code() -> str:
        if supplied:
            return supplied.pop(0)
        return fetch_code()

    try:
        while True:
            mark = time.time()
            r, _, _ = select.select([proc.stderr, proc.stdout], [], [], 0.5)
            spent += time.time() - mark
            if spent > budget:
                raise StoreError("登录太久没有完成，已中止。请确认 Apple ID 状态后重试")
            done = True
            # Drain the pty master too: the terminal's line discipline echoes what
            # we type back to it, and a full master buffer would block the child.
            try:
                while True:
                    ready, _, _ = select.select([master], [], [], 0)
                    if not ready or not os.read(master, 4096):
                        break
            except OSError:
                pass
            for stream in r:
                try:
                    data = os.read(stream.fileno(), 65536)
                except OSError:
                    data = b""
                if not data:
                    continue
                done = False
                if stream is proc.stdout:
                    stdout_buf += data
                else:
                    text = data.decode("utf-8", "replace")
                    prompts += text
                    low = prompts.lower()
                    if "password" in low and not answered_password:
                        # raw mode ends the password on "\r"; sending "\r\n" too
                        # would leak a newline into the next (2FA) prompt read.
                        os.write(master, password.encode() + b"\r")
                        answered_password = True
                        prompts = ""
                    elif "2fa code" in low:
                        # No latch needed: prompts is cleared each time a prompt is
                        # answered, so a second request is seen as a fresh match.
                        got = next_code()
                        if not got:
                            raise StoreError(
                                "没有拿到验证码，已取消登录。请在受信设备上生成 6 位验证码后重试，"
                                "或者改用 App 专用密码")
                        emit(e="log", m="已收到验证码，继续向 Apple 验证")
                        os.write(master, got.encode() + b"\n")
                        prompts = ""
                    elif "apple id" in low and not answered_password:
                        os.write(master, email.encode() + b"\n")
                        prompts = ""
                    if on_line:
                        for line in text.splitlines():
                            line = line.replace("*", "").strip()
                            if line:
                                on_line(line[:200])
            if done and proc.poll() is not None:
                break
        rc = proc.wait(timeout=30)
    finally:
        try:
            os.close(master)
        except OSError:
            pass
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=10)
        for stream in (proc.stdout, proc.stderr):
            try:
                stream.close()
            except OSError:
                pass

    events = _lines(stdout_buf)
    if rc != 0:
        raise StoreError(_friendly(_text(events) or "登录失败（退出码 %d）" % rc))


def login(ipatool: Path, cache_root: Path, email: str, password: str,
          code: str | None = None, on_line=None, ask_code=None,
          profile: str = "cn") -> dict:
    """Sign in, re-asking for the second factor as many times as it takes.

    Apple rejects a wrong or expired code and ipatool exits, but the password is
    still only in this process' memory, so the GUI gets its dialog back instead of
    making the user retype everything.
    """
    # Sign-in needs the SAP signer before Apple will even look at the password.
    warm_unicorn(on_line=on_line)

    def fetch_code() -> str:
        if ask_code is None:
            return ""
        emit(e="need-code",
             m="需要 6 位双重认证验证码。这个接口不会推送，请在 iPhone 或 Mac 的"
               "「设置 → Apple 账户 → 登录与安全性 → 获取验证码」里手动生成后填入")
        return (ask_code() or "").strip()

    pending = (code or "").strip() or None
    for attempt in range(1, 4):
        try:
            _login_session(ipatool, cache_root, email, password, pending, on_line,
                           fetch_code, profile)
            break
        except StoreError as e:
            text = str(e)
            # Only a code Apple actually looked at and refused is worth re-asking.
            # "no code supplied" must not match here, or cancelling the dialog would
            # just pop it again.
            rejected = ("did not complete verification" in text
                        or "try a fresh 2FA code" in text)
            if not rejected or ask_code is None or attempt >= 3:
                raise
            log("这个验证码没通过（多半是过期了），重新向你要一个", level="warn")
            pending = fetch_code()
            if not pending:
                raise StoreError("没有拿到新的验证码，已取消登录") from e

    info = auth_info(ipatool, cache_root, profile)
    if not info.get("logged_in"):
        raise StoreError("登录流程结束了，但钥匙串里没有会话。多半是 macOS 钥匙串弹了授权框被忽略，"
                         "请在弹窗里点“始终允许”再试一次：" + str(info.get("error", "")))
    return info


def _text(events: list[dict]) -> str:
    for ev in events:
        if ev.get("error") or ev.get("msg"):
            return str(ev.get("error") or ev.get("msg"))
    return ""


def logout(ipatool: Path, cache_root: Path, profile: str = "cn") -> None:
    run_json(ipatool, ["auth", "revoke"], cache_root, timeout=90, profile=profile)


# --------------------------------------------------------------------- download
def list_versions(ipatool, cache_root, bundle_id, profile="cn", expected_account=""):
    import store_history
    return store_history.list_versions(sys.modules[__name__], ipatool, cache_root,
                                       bundle_id, profile, expected_account)


def version_metadata(ipatool, cache_root, bundle_id, external_version_id,
                     profile="cn", expected_account=""):
    import store_history
    store_history.session(sys.modules[__name__], ipatool, cache_root, profile, expected_account)
    return store_history.metadata(sys.modules[__name__], ipatool, cache_root,
                                  bundle_id, external_version_id, profile)


def download(ipatool: Path, cache_root: Path, bundle_id: str, dst: Path,
             on_progress=None, purchase=True, timeout=1800,
             profile: str = "cn", expected_account: str = "",
             external_version_id: str = "", expected_version: str = "") -> Path:
    if external_version_id:
        import store_history
        return store_history.download(sys.modules[__name__], ipatool, cache_root,
                                      bundle_id, dst, external_version_id, profile,
                                      expected_account, expected_version, timeout, on_progress)
    if expected_version:
        raise StoreError("指定预期版本时必须同时指定外部版本 ID")
    return _download(ipatool, cache_root, bundle_id, dst, on_progress, purchase,
                     timeout, profile, expected_account)


def _download(ipatool: Path, cache_root: Path, bundle_id: str, dst: Path,
             on_progress=None, purchase=True, timeout=1800,
             profile: str = "cn", expected_account: str = "",
             external_version_id: str = "") -> Path:
    """Download a signed .ipa; returns the final path.

    ipatool writes to `<dst>.tmp` and renames at the end, and in --non-interactive
    mode prints no progress, so the growing temp file is watched instead.
    """
    info = auth_info(ipatool, cache_root, profile)
    if not info.get("logged_in"):
        raise StoreError(info.get("error") or "当前地区的下载会话未初始化")
    if expected_account and info.get("account_id") != expected_account:
        raise StoreError("当前下载账号已变更，请刷新会话并为新账号绑定对应凭据后重试")
    dst.parent.mkdir(parents=True, exist_ok=True)
    args = ["download", "--bundle-identifier", bundle_id, "--platform", "iphone",
            "--output", str(dst)]
    if external_version_id:
        args += ["--external-version-id", external_version_id]
    if purchase:
        args.append("--purchase")
    stop = threading.Event()

    def watch():
        last = -1
        while not stop.wait(1.0):
            size = 0
            for cand in (Path(str(dst) + ".tmp"), dst):
                if cand.exists():
                    size = max(size, cand.stat().st_size)
            if size != last:
                last = size
                if on_progress:
                    on_progress(size)

    if on_progress:
        on_progress(0)
    t = threading.Thread(target=watch, daemon=True)
    t.start()
    deadline = time.monotonic() + timeout
    try:
        for attempt in range(DOWNLOAD_MAX_ATTEMPTS):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise StoreError("连接 App Store 超时：本次下载已超过总等待时间，请检查网络后重试")
            try:
                events = run_json(ipatool, args, cache_root, timeout=remaining, profile=profile)
                break
            except StoreError as error:
                if (not _network_failure_kind(str(error))
                        or attempt == DOWNLOAD_MAX_ATTEMPTS - 1):
                    raise
                partial = Path(str(dst) + ".tmp")
                try:
                    saved = partial.stat().st_size
                except OSError:
                    saved = 0
                delay = min(2 ** attempt, 8)
                if deadline - time.monotonic() <= delay:
                    raise
                message = "网络连接暂时失败，%d 秒后自动重试（%d/%d）" % (
                    delay, attempt + 1, DOWNLOAD_MAX_ATTEMPTS - 1)
                if saved:
                    message += "；保留已下载的 %.1f MB，尝试断点续传" % (saved / 1048576.0)
                log(message, phase="download-retry")
                time.sleep(delay)
                current = auth_info(ipatool, cache_root, profile)
                if not current.get("logged_in"):
                    raise StoreError(current.get("error") or "当前地区的下载会话未初始化") from error
                if current.get("account_id") != info.get("account_id"):
                    raise StoreError("重试前检测到下载账号已变更，请刷新会话后重新提交") from error
    except StoreError as error:
        if not purchase and "license is required" in str(error).lower():
            raise StoreError("该软件需要付费，暂不支持砸壳。当前账号尚未购买，请使用已购账号。") from error
        raise
    finally:
        stop.set()
    final = None
    for ev in events:
        if ev.get("output"):
            final = Path(ev["output"])
            break
    if final is None or not final.exists():
        raise StoreError("下载结束但没找到 .ipa 文件")
    return final


# --------------------------------------------------------------------- package
def package_info(ipa: Path) -> dict:
    """Read bundle id / version / SINF / iTunesMetadata out of a store .ipa."""
    out = {"path": str(ipa), "bundle_id": "", "version": "", "build": "",
           "name": "", "exe": "", "app_dir": "", "sinf": None,
           "sinf_paths": [], "metadata": None}
    with zipfile.ZipFile(ipa) as z:
        names = z.namelist()
        if "iTunesMetadata.plist" in names:
            out["metadata"] = z.read("iTunesMetadata.plist")
            try:
                md = plistlib.loads(out["metadata"])
                out["version"] = str(md.get("bundleVersion") or out["version"])
                out["name"] = str(md.get("softwareVersionBundleId") or "")
            except Exception:
                pass
        for n in names:
            if not n.startswith("Payload/") or not n.endswith(".app/Info.plist"):
                continue
            if n.count("/") != 2 or "/Watch/" in n:
                continue
            data = z.read(n)
            try:
                pl = plistlib.loads(data)
            except Exception:
                continue
            out["app_dir"] = n[: -len("Info.plist")]
            out["exe"] = str(pl.get("CFBundleExecutable") or "")
            out["bundle_id"] = str(pl.get("CFBundleIdentifier") or "")
            out["version"] = str(pl.get("CFBundleShortVersionString") or out["version"])
            out["build"] = str(pl.get("CFBundleVersion") or "")
            out["name"] = str(pl.get("CFBundleDisplayName") or pl.get("CFBundleName")
                              or out["name"])
            break
        want = out["app_dir"] + "SC_Info/%s.sinf" % out["exe"] if out["exe"] else ""
        for n in names:
            if "/SC_Info/" in n and n.endswith(".sinf"):
                out["sinf_paths"].append(n)
                if n == want or out["sinf"] is None:
                    out["sinf"] = z.read(n)
    if not out["bundle_id"]:
        raise StoreError("这个 .ipa 里读不到 CFBundleIdentifier，包可能不完整")
    return out


def encrypt_probe(ipa: Path) -> dict:
    """Report whether the freshly downloaded binary really is FairPlay wrapped.

    This is the first chance the tool gets to see a genuinely encrypted Mach-O,
    so the answer is worth putting in the job log.
    """
    info = package_info(ipa)
    exe = info["app_dir"] + info["exe"] if info["exe"] else ""
    res = {"bundle_id": info["bundle_id"], "version": info["version"],
           "has_sinf": bool(info["sinf"]), "has_metadata": bool(info["metadata"]),
           "cryptid": None, "cryptsize_mb": None}
    if not exe:
        return res
    with zipfile.ZipFile(ipa) as z:
        if exe not in z.namelist():
            return res
        buf = z.read(exe)
    # LC_ENCRYPTION_INFO(_64): cryptoff/cryptsize/cryptid at +8/+12/+16.
    import struct
    for off in _slice_offsets(buf):
        magic = struct.unpack("<I", buf[off:off + 4])[0]
        if magic not in (0xFEEDFACF, 0xFEEDFACE):
            continue
        is64 = magic == 0xFEEDFACF
        ncmds = struct.unpack("<I", buf[off + 16:off + 20])[0]
        p = off + (32 if is64 else 28)
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack("<II", buf[p:p + 8])
            if cmdsize == 0 or cmdsize > 0x100000:
                break
            if cmd in (0x2C, 0x21):
                _, cs, ci = struct.unpack("<III", buf[p + 8:p + 20])
                res["cryptid"] = ci
                res["cryptsize_mb"] = round(cs / 1e6, 1)
                return res
            p += cmdsize
    return res


def _slice_offsets(buf: bytes):
    import struct
    if len(buf) < 8:
        return
    be = struct.unpack(">I", buf[:4])[0]
    if be in (0xCAFEBABE, 0xCAFEBABF):
        is64 = be == 0xCAFEBABF
        n = struct.unpack(">I", buf[4:8])[0]
        hdr, off = (32 if is64 else 20), 8
        for _ in range(n):
            if off + hdr > len(buf):
                return
            o = (struct.unpack(">Q", buf[off + 8:off + 16])[0] if is64
                 else struct.unpack(">I", buf[off + 8:off + 12])[0])
            yield o
            off += hdr
        return
    yield 0


# ------------------------------------------------------------------ standalone CLI
def main(argv=None):
    import argparse

    ap = argparse.ArgumentParser(description="App Store download helpers (NDJSON output)")
    ap.add_argument("--cache-root", default=str(Path.home() /
                    "Library/Application Support/DumpShop"))
    ap.add_argument("--ipatool", default=None)
    ap.add_argument("--profile", default="cn")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("resolve")
    sub.add_parser("auth-info")
    p = sub.add_parser("login")
    p.add_argument("--email", required=True)
    p.add_argument("--revoke", action="store_true")
    sub.add_parser("logout")
    d = sub.add_parser("download")
    d.add_argument("--bundle-id", required=True)
    d.add_argument("--dest", required=True)
    d.add_argument("--no-purchase", action="store_true")
    d.add_argument("--expected-account", default="")
    d.add_argument("--external-version-id", default="")
    d.add_argument("--expected-version", default="")
    for name in ("list-versions", "version-metadata", "versions"):
        v = sub.add_parser(name)
        v.add_argument("--bundle-id", required=True)
        v.add_argument("--expected-account", default="")
        if name == "version-metadata":
            v.add_argument("--external-version-id", required=True)
        if name == "versions":
            v.add_argument("--offset", type=int, default=0)
            v.add_argument("--limit", type=int, default=8)
    s = sub.add_parser("inspect")
    s.add_argument("--ipa", required=True)
    sub.add_parser("warm")
    args = ap.parse_args(argv)

    cache_root = Path(args.cache_root)
    cache_root.mkdir(parents=True, exist_ok=True)
    binary = Path(args.ipatool) if args.ipatool else None
    try:
        if args.cmd == "resolve":
            path, label = find_ipatool(None, binary, cache_root / "bin/ipatool")
            if not path:
                path = download_ipatool(cache_root / "bin/ipatool", on_line=log)
                label = "已下载"
            emit(e="result", ipatool=str(path), source=label,
                 version=IPATOOL_VERSION, arch=host_arch())
            return 0
        path, label = find_ipatool(args.ipatool, None, cache_root / "bin/ipatool")
        if not path:
            raise StoreError("找不到 ipatool，请在「App Store」面板里点“获取 ipatool”")
        if args.cmd == "auth-info":
            emit(e="result", **auth_info(path, cache_root, args.profile))
        elif args.cmd == "warm":
            emit(e="result", **warm_unicorn(on_line=lambda s: log(s)))
        elif args.cmd == "login":
            # Credentials arrive on stdin, never in argv: a command line can be read
            # by any process owned by the same user. The pipe stays open, so a 2FA
            # code can still be typed after the sign-in is already in flight.
            def ask_code(timeout=300):
                import select as _s
                ready, _, _ = _s.select([sys.stdin], [], [], timeout)
                return sys.stdin.readline() if ready else ""

            password = sys.stdin.readline().rstrip("\r\n")
            if not password:
                raise StoreError("没有从标准输入读到 Apple ID 密码")
            if args.revoke:
                logout(path, cache_root, args.profile)
            emit(e="result", **login(path, cache_root, args.email, password,
                                     None, ask_code=ask_code, profile=args.profile))
        elif args.cmd == "logout":
            logout(path, cache_root, args.profile)
            emit(e="result", logged_in=False, binary=True, name="", email="",
                 error="")
        elif args.cmd in ("list-versions", "version-metadata", "versions"):
            import store_history
            if args.cmd == "list-versions":
                result = list_versions(path, cache_root, args.bundle_id,
                                       args.profile, args.expected_account)
            elif args.cmd == "version-metadata":
                result = version_metadata(path, cache_root, args.bundle_id,
                                          args.external_version_id, args.profile,
                                          args.expected_account)
            else:
                result = store_history.page(sys.modules[__name__], path, cache_root,
                                            args.bundle_id, args.profile, args.expected_account,
                                            args.offset, args.limit)
            emit(e="result", **result)
        elif args.cmd == "download":
            dst = Path(args.dest)
            log("正在检查当前地区账号及下载授权")

            def report_progress(size):
                emit(e="progress", phase="download", done=float(size), total=0)

            got = download(path, cache_root, args.bundle_id, dst,
                           on_progress=report_progress,
                           purchase=not args.no_purchase,
                           profile=args.profile, expected_account=args.expected_account,
                           external_version_id=args.external_version_id,
                           expected_version=args.expected_version)
            emit(e="progress", phase="download",
                 done=float(got.stat().st_size), total=float(got.stat().st_size))
            log("下载完成 %s（%.1f MB）" %
                (got.name, got.stat().st_size / 1048576.0))
            emit(e="result", ipa=str(got), **encrypt_probe(got))
        else:
            emit(e="result", **encrypt_probe(Path(args.ipa)))
        return 0
    except StoreError as e:
        emit(e="error", m=str(e))
        return 1
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001 - surface anything as an NDJSON error
        emit(e="error", m="%s: %s" % (type(e).__name__, e))
        return 1


if __name__ == "__main__":
    sys.exit(main())
