"""pipx installer: installs CLI tools globally-accessible on PATH.

Offline: prepare pre-downloads wheels (PyPI) and builds wheels (git+URL)
into cache/pipx/wheels/, plus pip/setuptools/wheel for pipx's own shared
venv bootstrap. Install then points pipx's inner pip at the cache via
`--pip-args="--no-index --find-links <cache>"` and also seeds the shared
venv directly so pipx doesn't try to upgrade pip from the network on
first use.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
from pathlib import Path

from ._common import is_command

log = logging.getLogger("installers.pipx")

# Wheels that pipx needs for its own shared-libs venv. Without these
# cached, pipx's first install still wants to fetch pip/setuptools/wheel
# from PyPI regardless of --pip-args.
_PIPX_SHARED_LIBS = ["pip", "setuptools", "wheel"]


def _pipx_bin() -> str:
    return "pipx"


def _cache_dir(ctx) -> Path:
    return ctx.cache_dir / "pipx" / "wheels"


def _pip_bin() -> str | None:
    for c in ("pip3", "pip"):
        if is_command(c):
            return c
    return None


def prepare(section: dict, ctx) -> None:
    packages = section.get("packages", []) or []
    if not packages:
        return

    pip = _pip_bin()
    if pip is None:
        log.warning("pipx prepare: pip not on PATH yet; skipping wheel cache. "
                    "Re-run prepare after bootstrap installs python3-pip.")
        return

    cache = _cache_dir(ctx)
    cache.mkdir(parents=True, exist_ok=True)

    # 1) Cache the shared-libs wheels pipx itself needs.
    log.info("pipx: caching shared-libs wheels (%s)",
             ", ".join(_PIPX_SHARED_LIBS))
    ctx.run([pip, "download", "--dest", str(cache), *_PIPX_SHARED_LIBS])

    # 2) Cache wheels for each pipx package. PyPI specs -> `pip download`;
    #    git+URL specs -> `pip wheel` (builds a wheel locally from the repo).
    for pkg in packages:
        is_git = pkg.startswith(("git+", "git://"))
        log.info("pipx: caching %s %s", "(git build)" if is_git else "(download)",
                 pkg)
        if is_git:
            ctx.run([pip, "wheel", "--wheel-dir", str(cache),
                     "--no-deps", pkg])
            # pip wheel for git+URL only builds the top package; its runtime
            # deps still need downloading. `pip download` the same spec with
            # deps-only semantics via --no-build-isolation+no-binary probably
            # won't resolve cleanly, so we rely on `pip install`'s resolver
            # later. Best-effort: try to download the wheel's declared
            # dependencies at install time instead.
        else:
            ctx.run([pip, "download", "--dest", str(cache), pkg])


def install(section: dict, ctx) -> None:
    packages = section.get("packages", []) or []
    if not packages:
        return
    if not is_command(_pipx_bin()):
        log.error("pipx not found on PATH. Install via apt (pipx) first.")
        return

    cache = _cache_dir(ctx)
    use_cache = cache.is_dir() and any(cache.glob("*.whl"))

    pip_args = ""
    env_extra = {}
    if use_cache:
        log.info("pipx: installing from local wheel cache at %s", cache)
        pip_args = f"--no-index --find-links={cache}"
        # Pre-seed pipx's shared-libs venv so it doesn't hit PyPI on first
        # install. pipx keeps this venv at $PIPX_SHARED_LIBS or, by default,
        # $PIPX_HOME/shared. _pre_seed_shared_libs runs python3 -m venv +
        # pip install from the cache.
        _pre_seed_shared_libs(cache, ctx)
    else:
        log.info("pipx: no wheel cache at %s — installing from PyPI", cache)

    installed = _pipx_list()
    for pkg in packages:
        pkg_name = _venv_name_for(pkg)
        if pkg_name in installed:
            log.info("pipx %s already installed (venv=%s)", pkg, pkg_name)
            continue
        log.info("pipx install %s", pkg)
        cmd = [_pipx_bin(), "install"]
        if pip_args:
            cmd += [f"--pip-args={pip_args}"]
        cmd.append(pkg)
        ctx.run(cmd)

    ctx.run([_pipx_bin(), "ensurepath"])


def _pre_seed_shared_libs(cache: Path, ctx) -> None:
    """Create pipx's shared-libs venv from the local wheel cache.

    pipx lazily bootstraps its shared-libs venv the first time any install
    runs, and that bootstrap always hits PyPI to upgrade pip, regardless
    of --pip-args. We short-circuit that by creating the venv ourselves
    with pip installed from the local cache, so pipx sees a valid shared
    venv on its own path and never tries to reach PyPI.
    """
    pipx_home = Path(os.environ.get("PIPX_HOME")
                     or (Path.home() / ".local" / "share" / "pipx"))
    shared = Path(os.environ.get("PIPX_SHARED_LIBS")
                  or (pipx_home / "shared"))

    # If the shared venv already looks healthy, skip.
    if (shared / "bin" / "python").exists() or (shared / "Scripts" / "python.exe").exists():
        log.debug("pipx shared-libs venv already present at %s", shared)
        return

    log.info("pipx: seeding shared-libs venv at %s", shared)
    shared.parent.mkdir(parents=True, exist_ok=True)
    ctx.run(["python3", "-m", "venv", "--clear", str(shared)])
    venv_pip = shared / "bin" / "pip"
    ctx.run([str(venv_pip), "install", "--no-index",
             f"--find-links={cache}",
             *_PIPX_SHARED_LIBS])


def _venv_name_for(pkg: str) -> str:
    """Derive the venv name pipx will use for a package spec.

    Handles:
      - PyPI names with optional extras/version:  'ruff', 'foo[extras]>=1.0'
      - git URLs:                                  'git+https://host/org/repo.git@branch'
      - local paths:                               './path/to/wheel' (uses basename)
    """
    pkg = pkg.strip()
    if pkg.startswith(("git+", "git://")):
        # Take the last path segment of the URL, strip ref (@branch), .git suffix
        url = pkg.removeprefix("git+")
        base = url.split("@", 1)[0]  # drop @ref
        return base.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git").lower()
    if pkg.startswith(("http://", "https://")):
        return pkg.rstrip("/").rsplit("/", 1)[-1].split(".")[0].lower()
    # plain pkg spec: strip extras and any version operator
    base = pkg.split("[")[0]
    for op in ("===", "==", ">=", "<=", "~=", ">", "<", "!="):
        base = base.split(op, 1)[0]
    return base.strip().lower()


def _pipx_list() -> set[str]:
    try:
        r = subprocess.run(
            ["pipx", "list", "--json"],
            check=True, capture_output=True, text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return set()
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return set()
    venvs = data.get("venvs", {})
    return {name.lower() for name in venvs.keys()}


def _venv_name_for(pkg: str) -> str:
    """Derive the venv name pipx will use for a package spec.

    Handles:
      - PyPI names with optional extras/version:  'ruff', 'foo[extras]>=1.0'
      - git URLs:                                  'git+https://host/org/repo.git@branch'
      - local paths:                               './path/to/wheel' (uses basename)
    """
    pkg = pkg.strip()
    if pkg.startswith(("git+", "git://")):
        # Take the last path segment of the URL, strip ref (@branch), .git suffix
        url = pkg.removeprefix("git+")
        base = url.split("@", 1)[0]  # drop @ref
        return base.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git").lower()
    if pkg.startswith(("http://", "https://")):
        return pkg.rstrip("/").rsplit("/", 1)[-1].split(".")[0].lower()
    # plain pkg spec: strip extras and any version operator
    base = pkg.split("[")[0]
    for op in ("===", "==", ">=", "<=", "~=", ">", "<", "!="):
        base = base.split(op, 1)[0]
    return base.strip().lower()


def _pipx_list() -> set[str]:
    try:
        r = subprocess.run(
            ["pipx", "list", "--json"],
            check=True, capture_output=True, text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return set()
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return set()
    venvs = data.get("venvs", {})
    return {name.lower() for name in venvs.keys()}
