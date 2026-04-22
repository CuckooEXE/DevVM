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
    #
    # For git+URL specs we intentionally DON'T pass --no-deps: we want
    # every runtime dep pulled into the cache as a wheel too, so the
    # install phase can install the pre-built wheel fully offline.
    # (PEP 517 *build* dependencies like poetry-core and
    # poetry-dynamic-versioning get fetched on the fly from PyPI while
    # `pip wheel` is running here — they're ephemeral, used only to
    # produce the .whl. They don't need to end up in the cache because
    # install time installs the already-built .whl directly.)
    for pkg in packages:
        is_git = pkg.startswith(("git+", "git://"))
        log.info("pipx: caching %s %s", "(git build)" if is_git else "(download)",
                 pkg)
        if is_git:
            ctx.run([pip, "wheel", "--wheel-dir", str(cache), pkg])
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

        # For git+URL specs, install the wheel we pre-built in prepare
        # rather than re-running the source build. Going through the
        # git+URL again would trigger pip's PEP 517 build isolation,
        # which reaches out to PyPI for the package's build-system
        # deps (poetry-core, setuptools-scm, etc.) — those aren't in our
        # wheel cache, so --no-index would make it fail.
        pkg_arg = pkg
        if use_cache and pkg.startswith(("git+", "git://")):
            prebuilt = _find_prebuilt_wheel(cache, pkg)
            if prebuilt:
                log.info("pipx: using prebuilt wheel %s for %s",
                         prebuilt.name, pkg)
                pkg_arg = str(prebuilt)
            else:
                log.warning("pipx: no prebuilt wheel for %s in %s; "
                            "falling back to source install (may fail offline)",
                            pkg, cache)

        log.info("pipx install %s", pkg_arg)
        cmd = [_pipx_bin(), "install"]
        if pip_args:
            cmd += [f"--pip-args={pip_args}"]
        cmd.append(pkg_arg)
        ctx.run(cmd)

    ctx.run([_pipx_bin(), "ensurepath"])


def _find_prebuilt_wheel(cache: Path, pkg_spec: str) -> Path | None:
    """Locate a cached wheel built from the given pipx spec.

    `pip wheel` writes files as `<dist_name>-<version>-<py>-<abi>-<plat>.whl`
    where the dist name is the lowercased PEP 503 name with hyphens
    replaced by underscores. We match both variants (with hyphens and
    with underscores) to be forgiving across naming styles.
    """
    stem = _venv_name_for(pkg_spec)
    for pat in (f"{stem}-*.whl", f"{stem.replace('-', '_')}-*.whl"):
        matches = sorted(cache.glob(pat))
        if matches:
            return matches[-1]  # newest (lexical sort approximates version)
    return None


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
