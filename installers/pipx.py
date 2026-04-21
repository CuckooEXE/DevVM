"""pipx installer: installs CLI tools globally-accessible on PATH."""
from __future__ import annotations

import json
import logging
import subprocess

from ._common import is_command

log = logging.getLogger("installers.pipx")


def _pipx_bin() -> str:
    return "pipx"


def prepare(section: dict, ctx) -> None:
    # pipx is hard to do fully-offline: pipx creates a shared venv and tries
    # to upgrade pip in it before installing anything, which requires a pip
    # wheel (plus setuptools + wheel) available to it. Rather than half-build
    # a wheelhouse mirror here, we treat pipx as online-install only. If you
    # need offline pipx, point PIP_INDEX_URL at a proper simple-index mirror.
    pass


def install(section: dict, ctx) -> None:
    packages = section.get("packages", []) or []
    if not packages:
        return
    if not is_command(_pipx_bin()):
        log.error("pipx not found on PATH. Install via apt (pipx) first.")
        return

    installed = _pipx_list()
    for pkg in packages:
        pkg_name = _venv_name_for(pkg)
        if pkg_name in installed:
            log.info("pipx %s already installed (venv=%s)", pkg, pkg_name)
            continue
        log.info("pipx install %s", pkg)
        ctx.run([_pipx_bin(), "install", pkg])

    ctx.run([_pipx_bin(), "ensurepath"])


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
