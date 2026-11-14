#!/usr/bin/env python3
"""Check the intended public source files or supplied release bundle for private data."""

import os
import re
import sys
from pathlib import Path


DEFAULT_PATHS = [
    ".gitignore", "Package.swift", "README.md", "CHANGELOG.md",
    "Sources", "Tests", "assets", "catalog", "scripts",
]
PATTERNS = {
    "personal-home-path": rb"/(?:Users|home)/[A-Za-z0-9._-]+(?=[/\x00\s\"'<>]|$)",
    "private-temporary-path": rb"/(?:private/)?var/folders/[a-z0-9]{2}/[A-Za-z0-9_-]{8,}",
    "private-key": rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----",
    "github-token": rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})",
    "api-token": rb"sk-[A-Za-z0-9_-]{24,}",
    "aws-access-key": rb"AKIA[0-9A-Z]{16}",
    "slack-token": rb"xox[bpars]-[A-Za-z0-9-]{20,}",
    "email-address": rb"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
}
PRIVATE_NAMES = {".DS_Store", ".env", ".workbuddy", ".claude", ".codex", ".git"}
PRIVATE_SUFFIXES = {".pem", ".key", ".p12", ".p8", ".mobileprovision", ".provisionprofile"}


def main():
    paths = [Path(value) for value in (sys.argv[1:] or DEFAULT_PATHS)]
    files = []
    for path in paths:
        if not path.exists() and not path.is_symlink():
            print(f"FAIL missing input {path.name}")
            return 1
        files.extend(sorted(path.rglob("*")) if path.is_dir() else [path])

    failed = False
    checked = 0
    for path in files:
        if any(part in PRIVATE_NAMES for part in path.parts) or path.suffix in PRIVATE_SUFFIXES:
            print(f"FAIL private file or directory {path.name}")
            failed = True
            continue
        if path.is_symlink():
            data = os.fsencode(os.readlink(path))
        elif path.is_file():
            data = path.read_bytes()
        else:
            continue
        checked += 1
        findings = [name for name, pattern in PATTERNS.items() if re.search(pattern, data)]
        account_name = Path.home().name.encode()
        if len(account_name) >= 4 and account_name.lower() in data.lower():
            findings.append("local-account-name")
        if findings:
            print(f"FAIL {path.name} ({', '.join(findings)})")
            failed = True
    print(f"Checked {checked} files, {'FAILED' if failed else 'PASSED'}.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
