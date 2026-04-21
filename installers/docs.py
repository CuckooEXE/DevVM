"""Docs installer: rebuild man-db/info indexes, fetch zeal docsets."""
from __future__ import annotations

import logging
from pathlib import Path

from ._common import extract, http_download, is_command

log = logging.getLogger("installers.docs")

# Kapeli's `go.kapeli.com` shortener has a cert hostname mismatch; use a
# regional mirror directly. The feed XMLs at github.com/Kapeli/feeds list
# these mirrors. Change to london/newyork/sydney/singapore if sanfrancisco
# is slow or down from your network.
KAPELI_FEEDS = "http://sanfrancisco.kapeli.com/feeds"


def prepare(section: dict, ctx) -> None:
    docsets = section.get("zeal_docsets", []) or []
    if not docsets:
        return
    cache = ctx.cache_dir / "docsets"
    cache.mkdir(parents=True, exist_ok=True)
    for name in docsets:
        archive = cache / f"{name}.tgz"
        if archive.exists() and not ctx.refresh:
            continue
        url = f"{KAPELI_FEEDS}/{name}.tgz"
        try:
            http_download(url, archive)
        except Exception as e:
            log.warning("failed to fetch docset %s: %s", name, e)


def install(section: dict, ctx) -> None:
    if section.get("rebuild_mandb", False):
        if is_command("mandb"):
            log.info("rebuilding man-db")
            ctx.run(["mandb", "-q"], sudo=True, check=False)
        else:
            log.warning("mandb not installed — skipping man-db rebuild "
                        "(add `man-db` to apt.packages if you want man pages indexed)")

    if section.get("rebuild_info", False) and is_command("install-info"):
        log.info("info dir will be refreshed on next install-info invocation")

    docsets = section.get("zeal_docsets", []) or []
    if not docsets:
        return
    cache = ctx.cache_dir / "docsets"
    zeal_dir = Path.home() / ".local" / "share" / "Zeal" / "Zeal" / "docsets"
    zeal_dir.mkdir(parents=True, exist_ok=True)
    for name in docsets:
        archive = cache / f"{name}.tgz"
        if not archive.exists():
            log.warning("docset %s not cached; skipping", name)
            continue
        target = zeal_dir / f"{name}.docset"
        if target.exists():
            log.info("docset %s already installed", name)
            continue
        log.info("extracting docset %s", name)
        extract(archive, zeal_dir, strip_components=0)
