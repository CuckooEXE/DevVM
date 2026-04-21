"""pip_system installer: libs into system python with --break-system-packages.

Escape hatch for Python libraries that need to be importable from any `python3`
shell without activating a venv (e.g. pwntools, capstone).
"""
from __future__ import annotations

import logging
import subprocess
import sys
from pathlib import Path

from ._common import is_command

log = logging.getLogger("installers.pip_system")


def prepare(section: dict, ctx) -> None:
    packages = section.get("packages", []) or []
    if not packages:
        return
    cache = ctx.cache_dir / "pip_system"
    cache.mkdir(parents=True, exist_ok=True)
    if not is_command("pip3") and not is_command("pip"):
        log.warning("pip not available yet; skipping pip_system prepare")
        return
    pip = "pip3" if is_command("pip3") else "pip"
    for pkg in packages:
        log.info("caching pip_system package %s", pkg)
        ctx.run([pip, "download", "--dest", str(cache), pkg])


def install(section: dict, ctx) -> None:
    packages = section.get("packages", []) or []
    if not packages:
        return
    cache = ctx.cache_dir / "pip_system"
    # Check which are already importable to avoid redundant work.
    missing = [p for p in packages if not _importable(p)]
    if not missing:
        log.info("all %d pip_system packages already importable", len(packages))
        return

    base = ["pip3", "install", "--break-system-packages"]
    if cache.is_dir() and any(cache.iterdir()):
        # Offline-cache mode: some packages (r2pipe, rzpipe) ship only sdists.
        # Building them in pip's default isolated venv requires network access
        # to fetch setuptools. `--no-build-isolation` sidesteps that by using
        # the system-installed setuptools (which apt.python3-setuptools provides).
        base += ["--no-index", "--find-links", str(cache), "--no-build-isolation"]
    log.info("pip_system installing: %s", " ".join(missing))
    ctx.run(base + missing, sudo=True)


def _importable(pkg_spec: str) -> bool:
    """Best-effort: derive importable name from pkg spec and try importing it."""
    name = pkg_spec.split("[")[0].split("=")[0].split(">")[0].split("<")[0].strip()
    # Map common differences (pypi dist -> import name)
    aliases = {
        "pwntools": "pwn",
        "keystone-engine": "keystone",
        "capstone": "capstone",
        "unicorn": "unicorn",
        "requests": "requests",
    }
    import_name = aliases.get(name.lower(), name.replace("-", "_"))
    try:
        subprocess.run(
            [sys.executable, "-c", f"import {import_name}"],
            check=True, capture_output=True,
        )
        return True
    except subprocess.CalledProcessError:
        return False
