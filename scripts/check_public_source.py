#!/usr/bin/env python3
"""Check a source export without reading Keychain or application runtime state.

Reports paths and line numbers only, never the matching secret text.
Generated build directories are ignored; use git archive for source releases.
"""
from __future__ import annotations

import hashlib
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
GENERATED = {".git", ".build", ".swiftpm", "__pycache__", ".pytest_cache",
             ".venv", "venv", "build", "dist", "outputs"}
PRIVATE_DIRS = {"ipatool-state", "fairplay-credentials", "fairplay-staging",
                "unfairplay-models", "unfairplay-reports", "scratch",
                "private", "secrets", "backups"}
PRIVATE_NAMES = {"credential.bin", "device-udid.bin", "account", "account.json",
                 "account.enc", "cookies", "session-password", "machine-id"}
BAD_SUFFIXES = {".ipa", ".dmg", ".zip", ".key", ".pem", ".p12", ".pfx",
                ".mobileprovision", ".sqlite", ".db", ".log", ".har", ".jsonl",
                ".ios", ".pyc", ".pyo"}
PUBLIC_TABLES = {
    "vendor/fairplay-decrypt/credential-retrieval/credential/static-key-table.bin":
        "c7b33507f71d5f7a07f623eb21f6b9f23997f950119371631f6535f63e6d2af1",
    "vendor/fairplay-decrypt/credential-retrieval/credential/core4-word-table.bin":
        "6f471504d53746e4f21cc52aabc1ea6ed1be9a130a0bfa7e348139cd8b68a912",
}
PATTERNS = {
    "personal absolute path": re.compile(r"/Users/(?!Shared(?:/|\b)|example/|YOUR_NAME/)[A-Za-z0-9_.-]+/|/Volumes/[^\s\"']+/"),
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "GitHub token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b"),
    "AWS access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "Apple app password": re.compile(r"\b[a-z]{4}(?:-[a-z]{4}){3}\b"),
    "personal mailbox": re.compile(r"\b[A-Za-z0-9._%+-]+@(?:qq\.com|163\.com|126\.com|icloud\.com|gmail\.com|outlook\.com)\b", re.I),
    "encrypted session record": re.compile(r"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"),
    "JWT token": re.compile(r"\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{20,}\b"),
}
MAILBOX = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
URL_TEST_IDENTIFIERS = {"user@downloaddispatch.itunes.apple.com",
                        "user@buy.itunes.apple.com",
                        "user@example.apple.com",
                        "secret-password@buy.itunes.apple.com"}


def check() -> int:
    findings: list[str] = []
    scanned = 0
    for path in sorted(ROOT.rglob("*")):
        relative = path.relative_to(ROOT)
        if path.name == ".git" and len(relative.parts) > 1:
            findings.append(f"{relative}: nested Git history is not allowed")
            continue
        if any(part in GENERATED for part in relative.parts):
            continue
        if path.is_symlink():
            findings.append(f"{relative}: symlink is not allowed in the source export")
            continue
        if not path.is_file():
            continue
        if (path.name.startswith("._") or path.name == ".DS_Store"
                or any(part in PRIVATE_DIRS for part in relative.parts)
                or path.name in PRIVATE_NAMES
                or path.suffix.lower() in BAD_SUFFIXES
                or (path.name.startswith(".env") and path.name != ".env.example")
                or re.search(r"\.keychain(?:-db)?$", path.name, re.I)
                or path.name.startswith("cookies.")):
            findings.append(f"{relative}: private data or generated artifact")
            continue
        data = path.read_bytes()
        scanned += 1
        if path.suffix == ".bin":
            expected = PUBLIC_TABLES.get(relative.as_posix())
            if not expected or hashlib.sha256(data).hexdigest() != expected:
                findings.append(f"{relative}: unrecognized binary table or credential")
            continue
        if data[:4] in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\x7fELF"):
            findings.append(f"{relative}: compiled executable is not source")
            continue
        if path.suffix.lower() in {".png", ".icns", ".gif", ".jpg", ".jpeg"}:
            continue
        try:
            content = data.decode("utf-8")
        except UnicodeDecodeError:
            findings.append(f"{relative}: unexpected non-text artifact")
            continue
        for label, expression in PATTERNS.items():
            for match in expression.finditer(content):
                line = content.count("\n", 0, match.start()) + 1
                findings.append(f"{relative}:{line}: {label}")
        for match in MAILBOX.finditer(content):
            domain = match.group(1).lower()
            if (domain in {"example.com", "example.test"}
                    or domain.endswith((".example.com", ".example.test"))
                    or match.group(0) in URL_TEST_IDENTIFIERS):
                continue
            line = content.count("\n", 0, match.start()) + 1
            findings.append(f"{relative}:{line}: non-example mailbox needs review")
    if findings:
        print("Source check needs review (matched content is hidden):")
        print("\n".join(findings))
        return 1
    print(f"PASS: {scanned} source/assets checked; no listed private data found.")
    print("Two upstream public algorithm tables are allowlisted by exact SHA256.")
    return 0


if __name__ == "__main__":
    sys.exit(check())
