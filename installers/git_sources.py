"""git_sources installer.

Each entry clones a repo to ``dest``. The ``depth`` field controls history:

- ``depth: 1`` (default): shallow clone of just the target branch tip.
  Fastest, smallest on disk, no history. Good for wordlists, payloads,
  read-only references.
- ``depth: N`` for N > 1: shallow clone with N commits of history.
- ``depth: -1``: full clone with every branch and every commit. Use this
  when you want to ``git checkout <any-branch>`` offline or have a genuine
  development workflow against the repo.

Branch defaults to ``main``. The full-mirror (``depth: -1``) mode gets
cached as ``git clone --mirror`` so install can replay offline with all
refs intact; shallow modes mirror with ``--depth`` too, so the cache stays
small.

Each entry can also declare ``post_install``: a list of shell commands
run in the destination directory after the clone finishes (useful for
``keystone`` → ``kstool`` style build-from-source work). ``skip_if_command``
short-circuits post_install when the named executable is already on PATH.
"""
from __future__ import annotations

import logging
import shutil
import subprocess
from pathlib import Path

log = logging.getLogger("installers.git_sources")


def _name_from_url(url: str) -> str:
    return url.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")


def _mirror_dir(ctx, name: str) -> Path:
    return ctx.cache_dir / "git_sources" / f"{name}.git"


def _clone_flags_for_depth(depth: int, branch: str) -> list[str]:
    """Common clone flags for a given depth + branch."""
    if depth > 0:
        return ["--depth", str(depth), "--single-branch", "--branch", branch]
    # depth == -1 (or 0): full clone, all refs (nothing extra to pass)
    return []


def prepare(section: list, ctx) -> None:
    for entry in section or []:
        name = entry.get("name") or _name_from_url(entry["url"])
        mirror = _mirror_dir(ctx, name)
        depth = int(entry.get("depth", 1))
        branch = entry.get("branch", "main")

        if mirror.exists():
            if ctx.refresh:
                log.info("refreshing mirror for %s", name)
                ctx.run(["git", "-C", str(mirror), "remote", "update", "--prune"])
            else:
                log.debug("mirror cached: %s", mirror)
            continue

        mirror.parent.mkdir(parents=True, exist_ok=True)
        if depth > 0:
            log.info("mirroring %s (shallow, depth=%d, branch=%s)",
                     entry["url"], depth, branch)
            ctx.run([
                "git", "clone", "--mirror",
                "--depth", str(depth),
                "--single-branch", "--branch", branch,
                entry["url"], str(mirror),
            ])
        else:
            log.info("mirroring %s (full history, all branches)", entry["url"])
            ctx.run(["git", "clone", "--mirror", entry["url"], str(mirror)])


def install(section: list, ctx) -> None:
    for entry in section or []:
        name = entry.get("name") or _name_from_url(entry["url"])
        dest = Path(entry["dest"]).expanduser()
        branch = entry.get("branch", "main")
        depth = int(entry.get("depth", 1))
        mirror = _mirror_dir(ctx, name)

        if (dest / ".git").exists():
            log.info("%s already cloned at %s", name, dest)
            _run_post_install(entry, dest, ctx, only_if_needed=True)
            continue

        if not mirror.exists():
            log.error("mirror for %s not cached; run prepare first", name)
            continue

        dest.parent.mkdir(parents=True, exist_ok=True)
        clone_args = ["git", "clone"] + _clone_flags_for_depth(depth, branch)
        clone_args += [str(mirror), str(dest)]
        ctx.run(clone_args)

        # Rewrite origin to upstream so future fetches work against the real
        # remote, not the local mirror cache.
        ctx.run(["git", "-C", str(dest), "remote", "set-url", "origin", entry["url"]])
        log.info("cloned %s -> %s (depth=%s, branch=%s)",
                 name, dest, depth, branch)

        _run_post_install(entry, dest, ctx, only_if_needed=False)


def _run_post_install(entry: dict, dest: Path, ctx, *, only_if_needed: bool) -> None:
    cmds = entry.get("post_install") or []
    if not cmds:
        return

    skip_cmd = entry.get("skip_if_command")
    if skip_cmd and shutil.which(skip_cmd):
        log.info("skipping post_install for %s (%s already on PATH)",
                 entry["url"], skip_cmd)
        return

    if only_if_needed and not skip_cmd:
        # Repo was already cloned and there's no guard — assume build is done.
        log.debug("skipping post_install for already-cloned %s (no skip_if_command)",
                  entry["url"])
        return

    for cmd in cmds:
        log.info("post_install: %s", cmd)
        if ctx.dry_run:
            log.info("[dry-run] (cwd=%s) %s", dest, cmd)
            continue
        subprocess.run(["bash", "-c", cmd], cwd=str(dest), check=True)
