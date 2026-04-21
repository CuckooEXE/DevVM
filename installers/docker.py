"""Docker installer: pulls images, optionally saves tarballs for offline load.

The invoking user isn't yet a member of the ``docker`` group when this
installer runs (``post/30-docker-group.sh`` adds them afterwards, and the
group change doesn't take effect until re-login anyway). So every docker
call here needs root access to talk to ``/var/run/docker.sock``. We
detect whether the socket is already writable by the current user and
only add ``sudo`` when it isn't — that way offline re-runs of ``install``
on a fully-provisioned machine don't spuriously prompt for a password.
"""
from __future__ import annotations

import logging
import os
import subprocess
from pathlib import Path

from ._common import is_command

log = logging.getLogger("installers.docker")

_DOCKER_SOCK = "/var/run/docker.sock"


def _image_tarname(image: str) -> str:
    return image.replace("/", "__").replace(":", "__") + ".tar"


def _needs_sudo() -> bool:
    """True if talking to the docker daemon requires elevation.

    root (geteuid==0) is already fine; otherwise the socket has to be
    writable by us, which generally means docker-group membership that's
    active in the current session.
    """
    if os.geteuid() == 0:
        return False
    try:
        return not os.access(_DOCKER_SOCK, os.W_OK)
    except OSError:
        return True


def _image_present(image: str, sudo: bool) -> bool:
    cmd = (["sudo"] if sudo else []) + ["docker", "image", "inspect", image]
    r = subprocess.run(cmd, capture_output=True)
    return r.returncode == 0


def prepare(section: dict, ctx) -> None:
    images = section.get("images", []) or []
    save = section.get("save_to_cache", True)
    if not images:
        return
    if not is_command("docker"):
        log.warning("docker not installed yet; skipping docker prepare")
        return
    cache = ctx.cache_dir / "docker"
    cache.mkdir(parents=True, exist_ok=True)
    sudo = _needs_sudo()

    for image in images:
        tar = cache / _image_tarname(image)
        if tar.exists() and not ctx.refresh:
            log.info("cached: %s", tar.name)
            continue
        log.info("docker pull %s", image)
        ctx.run(["docker", "pull", image], sudo=sudo)
        if save:
            log.info("docker save %s -> %s", image, tar)
            ctx.run(["docker", "save", "-o", str(tar), image], sudo=sudo)


def install(section: dict, ctx) -> None:
    images = section.get("images", []) or []
    if not images:
        return
    if not is_command("docker"):
        log.error("docker not installed; run apt install first")
        return
    cache = ctx.cache_dir / "docker"
    sudo = _needs_sudo()
    for image in images:
        if _image_present(image, sudo):
            log.info("image already loaded: %s", image)
            continue
        tar = cache / _image_tarname(image)
        if tar.exists():
            log.info("docker load %s", image)
            ctx.run(["docker", "load", "-i", str(tar)], sudo=sudo)
        else:
            log.info("docker pull %s (no tarball cache)", image)
            ctx.run(["docker", "pull", image], sudo=sudo)
