#!/usr/bin/env python3
"""Run staged, outgoing, or checkpointed Gitleaks scans."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


CACHE_SCHEMA = 1
CACHE_LIMIT = 64
OID = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
ZERO_OID = re.compile(r"^(?:0{40}|0{64})$")


def run(
    command: list[str],
    *,
    check: bool = False,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def git(*args: str, check: bool = False) -> subprocess.CompletedProcess[str]:
    return run(["git", *args], check=check)


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


def resolve_gitleaks() -> tuple[str, str]:
    candidates: list[str] = []
    if os.environ.get("GITLEAKS_BIN"):
        candidates.append(os.environ["GITLEAKS_BIN"])
    mise = resolve_mise()
    if mise:
        result = run([mise, "which", "gitleaks"])
        if result.returncode == 0 and result.stdout.strip():
            candidates.append(result.stdout.strip())
    if shutil.which("gitleaks"):
        candidates.append(shutil.which("gitleaks") or "gitleaks")

    for candidate in dict.fromkeys(candidates):
        try:
            result = run([candidate, "version"])
        except OSError:
            continue
        if result.returncode == 0:
            version = (result.stdout or result.stderr).strip()
            return candidate, version
    raise RuntimeError(
        "Gitleaks is unavailable; run `mise install` from the repository root"
    )


def repository_root() -> Path:
    result = git("rev-parse", "--show-toplevel")
    if result.returncode != 0:
        raise RuntimeError("not inside a Git worktree")
    return Path(result.stdout.strip()).resolve()


def common_directory() -> Path:
    result = git("rev-parse", "--path-format=absolute", "--git-common-dir")
    if result.returncode != 0 or not result.stdout.strip():
        raise RuntimeError("could not resolve the Git common directory")
    return Path(result.stdout.strip()).resolve()


def policy_digest(root: Path, version: str) -> str:
    digest = hashlib.sha256()
    digest.update(f"gitleaks-version\0{version}\0".encode())
    for name in (".gitleaks.toml", ".gitleaksignore"):
        path = root / name
        digest.update(f"{name}\0".encode())
        digest.update(path.read_bytes() if path.is_file() else b"<missing>")
        digest.update(b"\0")
    return digest.hexdigest()


def read_cache(path: Path) -> tuple[list[dict[str, str]], str | None]:
    try:
        payload = json.loads(path.read_text())
    except FileNotFoundError:
        return [], "no verified checkpoint"
    except (OSError, json.JSONDecodeError):
        return [], "verified-checkpoint cache is unreadable"
    if payload.get("schema") != CACHE_SCHEMA or not isinstance(
        payload.get("checkpoints"), list
    ):
        return [], "verified-checkpoint cache is invalid"
    entries = [
        entry
        for entry in payload["checkpoints"]
        if isinstance(entry, dict)
        and OID.fullmatch(str(entry.get("commit", "")))
        and isinstance(entry.get("policy_digest"), str)
    ]
    return entries, None


def revision_count(revisions: list[str]) -> int:
    result = git("rev-list", "--count", *revisions)
    try:
        count = int(result.stdout.strip())
    except ValueError as error:
        raise RuntimeError("could not count the selected Git history") from error
    if result.returncode != 0 or count < 0:
        raise RuntimeError("could not count the selected Git history")
    return count


def is_ancestor(ancestor: str, descendant: str) -> bool:
    return git("merge-base", "--is-ancestor", ancestor, descendant).returncode == 0


def choose_checkpoint(
    entries: list[dict[str, str]], target: str, digest: str
) -> tuple[str, int] | None:
    best: tuple[str, int] | None = None
    for entry in entries:
        commit = entry["commit"]
        if entry["policy_digest"] != digest or not is_ancestor(commit, target):
            continue
        count = revision_count([f"{commit}..{target}"])
        if best is None or count < best[1]:
            best = (commit, count)
    return best


def record_checkpoint(
    path: Path,
    entries: list[dict[str, str]],
    commit: str,
    digest: str,
) -> None:
    checkpoints = [
        {"commit": commit, "policy_digest": digest},
        *[
            entry
            for entry in entries
            if entry["commit"] != commit or entry["policy_digest"] != digest
        ],
    ][:CACHE_LIMIT]
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps({"schema": CACHE_SCHEMA, "checkpoints": checkpoints}) + "\n"
    )
    temporary.chmod(0o600)
    temporary.replace(path)


def parse_pre_push_records() -> list[tuple[str, str, str, str]]:
    raw = os.environ.get("AGENT_WORKSPACE_PRE_PUSH_REFS")
    if raw is None:
        raise RuntimeError("missing pre-push ref records")
    records: list[tuple[str, str, str, str]] = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) != 4:
            raise RuntimeError("malformed pre-push ref record")
        local_ref, local_oid, remote_ref, remote_oid = fields
        if not OID.fullmatch(local_oid) or not OID.fullmatch(remote_oid):
            raise RuntimeError("malformed pre-push object id")
        records.append((local_ref, local_oid, remote_ref, remote_oid))
    return records


def outgoing_revisions(
    records: list[tuple[str, str, str, str]],
    entries: list[dict[str, str]],
    digest: str,
) -> list[str]:
    local_oids = {
        local_oid
        for _, local_oid, _, _ in records
        if not ZERO_OID.fullmatch(local_oid)
    }
    if not local_oids:
        return []

    exclusions: set[str] = set()
    for _, local_oid, _, remote_oid in records:
        if ZERO_OID.fullmatch(local_oid):
            continue
        if not ZERO_OID.fullmatch(remote_oid):
            present = git("cat-file", "-e", f"{remote_oid}^{{commit}}")
            if present.returncode == 0:
                exclusions.add(remote_oid)
        checkpoint = choose_checkpoint(entries, local_oid, digest)
        if checkpoint is not None:
            exclusions.add(checkpoint[0])

    revisions = sorted(local_oids)
    if exclusions:
        revisions.extend(["--not", *sorted(exclusions)])
    return revisions


def scan(
    binary: str,
    root: Path,
    *,
    staged: bool = False,
    revisions: list[str] | None = None,
) -> int:
    command = [
        binary,
        "git",
        "--redact",
        "--no-banner",
    ]
    if staged:
        command.append("--staged")
    elif revisions:
        command.append(f"--log-opts={' '.join(revisions)}")
    command.append(str(root))
    return run(command, capture=False).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument(
        "--staged",
        action="store_true",
        help="scan only content staged in the Git index",
    )
    modes.add_argument(
        "--pre-push",
        action="store_true",
        help="scan outgoing revisions supplied by the managed pre-push hook",
    )
    modes.add_argument(
        "--full",
        action="store_true",
        help="ignore checkpoints and scan all reachable history",
    )
    args = parser.parse_args()

    try:
        root = repository_root()
        os.chdir(root)
        binary, version = resolve_gitleaks()
        digest = policy_digest(root, version)
        cache_path = (
            common_directory()
            / "agent-workspace"
            / "gitleaks-history-v1.json"
        )
        entries, cache_problem = read_cache(cache_path)

        if args.staged:
            status = scan(binary, root, staged=True)
            if status == 0:
                print("PASS: staged Gitleaks scan clean")
            return status

        if args.pre_push:
            records = parse_pre_push_records()
            revisions = outgoing_revisions(records, entries, digest)
            if not revisions:
                print("PASS: no outgoing commits to scan")
                return 0
            count = revision_count(revisions)
            if count == 0:
                print("PASS: no outgoing commits to scan")
                return 0
            status = scan(binary, root, revisions=revisions)
            if status == 0:
                print(
                    "PASS: Gitleaks outgoing scan clean "
                    f"({count} selected revisions)"
                )
            return status

        shallow = git("rev-parse", "--is-shallow-repository")
        if shallow.returncode != 0 or shallow.stdout.strip() != "false":
            raise RuntimeError(
                "checkpointed history scan requires a non-shallow checkout"
            )
        head_result = git("rev-parse", "--verify", "HEAD")
        head = head_result.stdout.strip()
        if head_result.returncode != 0:
            print("PASS: no reachable Git history to scan (unborn repository)")
            return 0
        if not OID.fullmatch(head):
            raise RuntimeError("could not resolve HEAD")

        checkpoint = None if args.full else choose_checkpoint(entries, head, digest)
        if checkpoint is not None and checkpoint[1] == 0:
            if policy_digest(root, version) != digest:
                raise RuntimeError("Gitleaks policy changed while checking the cache")
            print(f"PASS: Gitleaks cache hit at {head}")
            return 0

        if checkpoint is not None:
            revisions = [f"{checkpoint[0]}..{head}"]
            mode = f"incremental after {checkpoint[0]}"
        else:
            revisions = [head]
            if args.full:
                reason = "forced full scan"
            elif cache_problem:
                reason = cache_problem
            elif entries and not any(
                entry["policy_digest"] == digest for entry in entries
            ):
                reason = "Gitleaks version or policy changed"
            else:
                reason = "no verified checkpoint is an ancestor of HEAD"
            mode = f"full history ({reason})"

        count = revision_count(revisions)
        if count < 1:
            raise RuntimeError("selected history unexpectedly contains no commits")
        status = scan(binary, root, revisions=revisions)
        if status != 0:
            return status
        if policy_digest(root, version) != digest:
            raise RuntimeError("Gitleaks policy changed during the scan; retry")
        try:
            record_checkpoint(cache_path, entries, head, digest)
        except OSError as error:
            print(
                "WARNING: scan passed but the checkpoint could not be saved: "
                f"{error}",
                file=sys.stderr,
            )
        print(f"PASS: Gitleaks {mode} scan clean ({count} selected revisions)")
        return 0
    except RuntimeError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
