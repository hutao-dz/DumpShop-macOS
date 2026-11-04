"""Shared history operations for the macOS and Linux store adapters."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import time


def version_id(value, error):
    text = str(value)
    if not re.fullmatch(r"[1-9][0-9]{0,19}", text):
        raise error("版本 ID 必须是 Apple 返回的正整数标识")
    return text


def session(store, tool, cache, profile, expected_account=""):
    info = store.auth_info(tool, cache, profile)
    if not info.get("logged_in"):
        raise store.StoreError(info.get("error") or "当前地区的下载会话未初始化")
    if expected_account and expected_account != info.get("account_id"):
        raise store.StoreError("当前下载账号已变更，请重新查询历史版本")
    return info


def list_versions(store, tool, cache, bundle_id, profile="cn", expected_account="", timeout=90):
    session(store, tool, cache, profile, expected_account)
    events = store.run_json(tool, ["list-versions", "--bundle-identifier", bundle_id,
                                  "--platform", "iphone"], cache, profile=profile, timeout=timeout)
    for event in events:
        if event.get("success") and isinstance(event.get("externalVersionIdentifiers"), list):
            ids = list(dict.fromkeys(version_id(v, store.StoreError)
                                     for v in event["externalVersionIdentifiers"]))
            return {"externalVersionIdentifiers": ids, "total": len(ids)}
    raise store.StoreError("版本查询未返回有效列表；请检查下载组件是否支持历史版本")


def metadata(store, tool, cache, bundle_id, external_version_id, profile="cn", timeout=45):
    ident = version_id(external_version_id, store.StoreError)
    events = store.run_json(tool, ["get-version-metadata", "--bundle-identifier", bundle_id,
                                  "--platform", "iphone", "--external-version-id", ident],
                            cache, profile=profile, timeout=timeout)
    for event in events:
        if event.get("success") and event.get("displayVersion"):
            if str(event.get("externalVersionID")) != ident:
                raise store.StoreError("版本信息与请求的版本 ID 不符")
            return {"externalVersionID": ident, "displayVersion": str(event["displayVersion"]),
                    "releaseDate": str(event.get("releaseDate") or "")}
    raise store.StoreError("Apple 未返回该版本的信息，可能已不可下载")


def page(store, tool, cache, bundle_id, profile="cn", expected_account="", offset=0, limit=8):
    if offset < 0 or not 1 <= limit <= 20:
        raise store.StoreError("分页参数无效：offset ≥ 0，limit 为 1–20")
    info = session(store, tool, cache, profile, expected_account)
    result = list_versions(store, tool, cache, bundle_id, profile, info["account_id"])
    # Preserve Apple's order (in reverse for browsing); IDs are not version numbers.
    ids = list(reversed(result["externalVersionIdentifiers"]))

    def resolve(ident):
        try:
            return metadata(store, tool, cache, bundle_id, ident, profile, timeout=25)
        except store.StoreError as error:
            return {"externalVersionID": ident, "displayVersion": "", "releaseDate": "",
                    "error": str(error)}

    with ThreadPoolExecutor(max_workers=2) as pool:
        rows = list(pool.map(resolve, ids[offset:offset + limit]))
    session(store, tool, cache, profile, info["account_id"])
    end = offset + len(rows)
    return {"versions": rows, "total": len(ids), "offset": offset,
            "next_offset": end if end < len(ids) else None}


@contextmanager
def transfer_lock(directory, error):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / "transfer.lock").open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise error("同一目标的这个版本正在下载，请等待现有任务完成") from None
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def download(store, tool, cache, bundle_id, dst, external_version_id, profile="cn",
             expected_account="", expected_version="", timeout=1800, on_progress=None):
    started = time.monotonic()
    ident = version_id(external_version_id, store.StoreError)
    info = session(store, tool, cache, profile, expected_account)
    target = metadata(store, tool, cache, bundle_id, ident, profile, timeout=min(45, timeout))
    if expected_version and target["displayVersion"] != expected_version:
        raise store.StoreError("所选版本信息已变化，请重新查询后提交")
    # Separate partial files by destination, account, storefront, app and version.
    key = hashlib.sha256(json.dumps([store._clean_profile(profile), info["account_id"],
                                   bundle_id, ident], separators=(",", ":")).encode()).hexdigest()[:24]
    dst = Path(dst)
    work = dst.parent / ("." + dst.name + ".history-" + key)
    with transfer_lock(work, store.StoreError):
        remaining = timeout - (time.monotonic() - started)
        if remaining <= 0:
            raise store.StoreError("查询历史版本超时，请重试")
        # A historical download only uses the account's existing license.
        got = store._download(tool, cache, bundle_id, work / dst.name,
                              on_progress=on_progress, purchase=False, timeout=remaining,
                              profile=profile, expected_account=info["account_id"],
                              external_version_id=ident)
        package = store.package_info(got)
        if package["bundle_id"] != bundle_id or package["version"] != target["displayVersion"]:
            got.unlink(missing_ok=True)
            raise store.StoreError("Apple 返回的应用或版本与所选版本不符，已停止处理")
        if package.get("metadata"):
            import plistlib
            manifest = plistlib.loads(package["metadata"])
            actual = manifest.get("softwareVersionExternalIdentifier")
            if actual is not None and str(actual) != ident:
                got.unlink(missing_ok=True)
                raise store.StoreError("下载包的外部版本 ID 与请求不符，已停止处理")
        session(store, tool, cache, profile, info["account_id"])
        os.replace(got, dst)
    return dst
