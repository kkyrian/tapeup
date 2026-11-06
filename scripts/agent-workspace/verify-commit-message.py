#!/usr/bin/env python3
"""Validate a commit message with Cocogitto and narrow Git exemptions."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


GIT_REVERT = re.compile(
    r'^Revert ".+"\n(?:\n.*)*\nThis reverts commit [0-9a-f]{40,64}\.\n?$',
    re.DOTALL,
)


def resolve_mise() -> str | None:
    candidates = [
        shutil.which("mise"),
        str(Path.home() / ".local/bin/mise"),
        "/opt/homebrew/bin/mise",
        "/usr/local/bin/mise",
    ]
    return next(
        (
            candidate
            for candidate in candidates
            if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK)
        ),
        None,
    )


def resolve_cog() -> str:
    override = os.environ.get("COG_BIN")
    if override:
        return override
    mise = resolve_mise()
    if mise:
        result = subprocess.run(
            [mise, "which", "cog"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    binary = shutil.which("cog")
    if binary:
        return binary
    raise RuntimeError(
        "Cocogitto is unavailable; run `mise install` from the repository root"
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify-commit-message.py <commit-message-file>", file=sys.stderr)
        return 2
    message_path = Path(sys.argv[1])
    message = message_path.read_text()
    if GIT_REVERT.fullmatch(message):
        print("Git-generated revert message accepted")
        return 0
    try:
        cog = resolve_cog()
    except RuntimeError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return subprocess.run(
        [
            cog,
            "verify",
            "--ignore-merge-commits",
            "--ignore-fixup-commits",
            "--file",
            str(message_path),
        ]
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
