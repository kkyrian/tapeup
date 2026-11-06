#!/usr/bin/env python3
"""Install worktree-safe Lefthook launchers in the Git common directory.

Git never copies hooks or core.hooksPath when a repository is cloned, so every
clone activates its own hooks by running this once. Linked worktrees share the
activation of the clone they belong to.
"""

from __future__ import annotations

import argparse
import os
import stat
import subprocess
import sys
from pathlib import Path


RUNNER = r"""#!/bin/sh
set -eu

hook_name=${1:?hook name is required}
shift
current_worktree=$(git rev-parse --show-toplevel)

find_mise() {
  if command -v mise >/dev/null 2>&1; then
    command -v mise
  elif test -x "${HOME}/.local/bin/mise"; then
    printf '%s\n' "${HOME}/.local/bin/mise"
  elif test -x /opt/homebrew/bin/mise; then
    printf '%s\n' /opt/homebrew/bin/mise
  elif test -x /usr/local/bin/mise; then
    printf '%s\n' /usr/local/bin/mise
  else
    return 1
  fi
}

mise_bin=$(find_mise) || {
  echo "ERROR: mise is unavailable; install it and run mise install" >&2
  exit 1
}
lefthook_bin=$("$mise_bin" which lefthook 2>/dev/null) || {
  echo "ERROR: repo-pinned lefthook is unavailable; run mise install" >&2
  exit 1
}

cd "$current_worktree"
exec "$lefthook_bin" run "$hook_name" "$@" --no-auto-install
"""
PRE_COMMIT = '#!/bin/sh\nexec "$(dirname "$0")/run-lefthook.sh" pre-commit "$@"\n'
COMMIT_MSG = '#!/bin/sh\nexec "$(dirname "$0")/run-lefthook.sh" commit-msg "$@"\n'
PRE_PUSH = r"""#!/bin/sh
set -eu
AGENT_WORKSPACE_PRE_PUSH_REFS=$(cat)
export AGENT_WORKSPACE_PRE_PUSH_REFS
exec "$(dirname "$0")/run-lefthook.sh" pre-push --force "$@"
"""


#: Variables that point Git at a repository other than the one this script sits
#: in. Git exports some of them to hooks, so an install started from a hook in
#: one repository must not land in that repository instead of this one.
REPOSITORY_ENVIRONMENT = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
    "GIT_PREFIX",
)


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={
            key: value
            for key, value in os.environ.items()
            if key not in REPOSITORY_ENVIRONMENT
        },
    )


HOOKS_DIRECTORY = "agent-workspace-hooks-v1"
INSTALLER = "scripts/agent-workspace/install-hooks.py"
INSTALL_COMMAND = f"python3 {INSTALLER}"
LAUNCHERS = {
    "run-lefthook.sh": RUNNER,
    "pre-commit": PRE_COMMIT,
    "pre-push": PRE_PUSH,
    "commit-msg": COMMIT_MSG,
}


def work_tree() -> Path:
    return Path(git("rev-parse", "--show-toplevel").stdout.strip())


def location_problem() -> str | None:
    """Why this copy has no clone of its own to configure, or None when it does.

    Git answers for the nearest enclosing repository, so a copy unpacked inside
    someone else's work tree (a vendored package, an exported tree, a scratch
    directory) would otherwise configure that repository.
    """
    try:
        inside = git("rev-parse", "--is-inside-work-tree", check=False)
    except OSError:
        return "git is unavailable"
    if inside.returncode != 0 or inside.stdout.strip() != "true":
        return "this is not a Git work tree"
    root = work_tree()
    try:
        own = (root / INSTALLER).samefile(__file__)
    except OSError:
        own = False
    if not own:
        return f"this copy is not the installer of the enclosing work tree {root}"
    return None


def unmanaged_reason() -> str | None:
    """Why --check and --auto leave this checkout alone, or None when they act."""
    if os.environ.get("CI", "").strip().lower() not in ("", "0", "false"):
        return "CI is set"
    return location_problem()


def managed_hooks_directory() -> Path:
    # Resolved here rather than with `--path-format=absolute`, which Git older
    # than 2.31 echoes back as if it were a path.
    common = git("rev-parse", "--git-common-dir").stdout.strip()
    return Path(os.path.abspath(common)) / HOOKS_DIRECTORY


def hooks_path_state(hooks: Path) -> tuple[str, str]:
    """Classify core.hooksPath as unset, managed, stale, or foreign.

    Stale is a path this script wrote for another location: the clone was moved
    or copied, and the absolute path stayed behind.
    """
    value = git("config", "--get", "core.hooksPath", check=False).stdout.strip()
    if not value:
        return "unset", value
    resolved = Path(value).expanduser()
    if not resolved.is_absolute():
        resolved = work_tree() / resolved
    if resolved.resolve() == hooks.resolve():
        return "managed", value
    if resolved.name == HOOKS_DIRECTORY:
        return "stale", value
    return "foreign", value


def inactive_reason(hooks: Path) -> tuple[str, str] | None:
    """Return (what is wrong, the command that fixes it), or None when active."""
    state, value = hooks_path_state(hooks)
    if state == "unset":
        return "core.hooksPath is not set", INSTALL_COMMAND
    if state == "stale":
        return (
            f"core.hooksPath still points to {value}, where this clone was "
            "before it was moved or copied",
            INSTALL_COMMAND,
        )
    if state == "foreign":
        return (
            f"core.hooksPath points to {value}, not the managed launchers",
            f"inspect that path, then run {INSTALL_COMMAND} --replace",
        )
    missing = [
        name
        for name in LAUNCHERS
        if not (hooks / name).is_file() or not os.access(hooks / name, os.X_OK)
    ]
    if missing:
        return f"missing launcher(s) in {hooks}: {', '.join(missing)}", INSTALL_COMMAND
    return None


def install(hooks: Path) -> None:
    hooks.mkdir(parents=True, exist_ok=True)
    for name, content in LAUNCHERS.items():
        destination = hooks / name
        temporary = hooks / f".{name}.{os.getpid()}.tmp"
        temporary.write_text(content)
        temporary.chmod(
            temporary.stat().st_mode
            | stat.S_IXUSR
            | stat.S_IXGRP
            | stat.S_IXOTH
        )
        temporary.replace(destination)
    git("config", "core.hooksPath", str(hooks))
    print(f"Git hooks installed at {hooks}")


def check() -> int:
    skipped = unmanaged_reason()
    if skipped:
        print(f"Git hook check skipped: {skipped}.")
        return 0
    problem = inactive_reason(managed_hooks_directory())
    if problem is None:
        return 0
    reason, fix = problem
    print(
        f"Git hooks are not active in this clone: {reason}.\nFix: {fix}",
        file=sys.stderr,
    )
    return 1


def auto() -> int:
    """Activate hooks from an install-time trigger without ever failing it."""
    try:
        skipped = unmanaged_reason()
        if skipped:
            print(f"Git hooks not installed: {skipped}.")
            return 0
        hooks = managed_hooks_directory()
        state, value = hooks_path_state(hooks)
        if state == "foreign":
            print(
                f"Git hooks not installed: core.hooksPath already points to "
                f"{value}. Inspect it, then run {INSTALL_COMMAND} --replace",
                file=sys.stderr,
            )
            return 0
        install(hooks)
    except (OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", "") or str(error)
        print(
            f"Git hooks not installed: {detail.strip()}\nRun {INSTALL_COMMAND}",
            file=sys.stderr,
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "Activate this clone's Git hooks. Git does not copy hooks on clone, "
            "so each clone runs this once; linked worktrees share the result.\n\n"
            "Examples:\n"
            "  install-hooks.py           install or refresh the launchers\n"
            "  install-hooks.py --check   exit 1 with the fix when hooks are inactive\n"
            "  install-hooks.py --auto    for install-time triggers; never fails"
        ),
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--replace",
        action="store_true",
        help="replace a different existing core.hooksPath after manual inspection",
    )
    mode.add_argument(
        "--check",
        action="store_true",
        help=(
            "change nothing; exit 0 when hooks are active and 1 with the fixing "
            "command when they are not. Skipped when CI is set, outside a Git "
            "work tree, or in a copy nested inside another repository"
        ),
    )
    mode.add_argument(
        "--auto",
        action="store_true",
        help=(
            "install unless --check would skip or another core.hooksPath is "
            "configured; then say why not. Always exits 0 so a package install "
            "is never broken by it"
        ),
    )
    args = parser.parse_args()
    if args.check:
        return check()
    if args.auto:
        return auto()

    misplaced = location_problem()
    if misplaced:
        print(f"ERROR: {misplaced}", file=sys.stderr)
        return 1
    hooks = managed_hooks_directory()
    state, value = hooks_path_state(hooks)
    if state == "foreign" and not args.replace:
        print(
            "ERROR: core.hooksPath already points elsewhere: "
            f"{value}\nInspect it, then rerun with --replace only if the "
            "managed Lefthook launchers should own the hook path.",
            file=sys.stderr,
        )
        return 1
    install(hooks)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
