"""Docker installer: pulls images, optionally saves tarballs for offline load."""
from __future__ import annotations

import logging
import subprocess
from pathlib import Path

from ._common import is_command

log = logging.getLogger("installers.docker")


def _image_tarname(image: str) -> str:
    return image.replace("/", "__").replace(":", "__") + ".tar"


def _image_present(image: str) -> bool:
    r = subprocess.run(
        ["docker", "image", "inspect", image],
        capture_output=True,
    )
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

    for image in images:
        tar = cache / _image_tarname(image)
        if tar.exists() and not ctx.refresh:
            log.info("cached: %s", tar.name)
            continue
        log.info("docker pull %s", image)
        ctx.run(["docker", "pull", image])
        if save:
            log.info("docker save %s -> %s", image, tar)
            ctx.run(["docker", "save", "-o", str(tar), image])


def install(section: dict, ctx) -> None:
    images = section.get("images", []) or []
    if not images:
        return
    if not is_command("docker"):
        log.error("docker not installed; run apt install first")
        return
    cache = ctx.cache_dir / "docker"
    for image in images:
        if _image_present(image):
            log.info("image already loaded: %s", image)
            continue
        tar = cache / _image_tarname(image)
        if tar.exists():
            log.info("docker load %s", image)
            ctx.run(["docker", "load", "-i", str(tar)])
        else:
            log.info("docker pull %s (no tarball cache)", image)
            ctx.run(["docker", "pull", image])
