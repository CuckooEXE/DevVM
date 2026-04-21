"""GitHub Releases installer: fetches latest, extracts, installs binaries + man pages."""
from __future__ import annotations

import logging
import shutil
from pathlib import Path

from ._common import (
    extract, http_download, latest_release, pick_asset, sha256, sudo_install_file,
)

log = logging.getLogger("installers.github_releases")


def _cache_dir(ctx, repo: str, tag: str) -> Path:
    return ctx.cache_dir / "github" / repo.replace("/", "__") / tag


def _resolve_one(entry: dict, ctx) -> dict:
    """Return {tag, asset_name, asset_url, asset_size} for an entry."""
    repo = entry["repo"]
    lock_key = f"github:{repo}"
    locked = ctx.lock.get(lock_key)
    if locked and not ctx.refresh and "tag" in locked:
        return locked
    log.info("resolving latest for %s", repo)
    release = latest_release(repo)
    asset = pick_asset(release, entry["asset_regex"])
    resolved = {
        "tag": release["tag_name"],
        "asset_name": asset["name"],
        "asset_url": asset["browser_download_url"],
        "asset_size": asset.get("size"),
    }
    ctx.lock[lock_key] = resolved
    return resolved


def prepare(section: list, ctx) -> None:
    for entry in section or []:
        resolved = _resolve_one(entry, ctx)
        cache = _cache_dir(ctx, entry["repo"], resolved["tag"])
        archive = cache / resolved["asset_name"]
        http_download(resolved["asset_url"], archive,
                      expected_size=resolved.get("asset_size"))
        ctx.lock[f"github:{entry['repo']}"]["sha256"] = sha256(archive)


def install(section: list, ctx) -> None:
    for entry in section or []:
        repo = entry["repo"]
        resolved = ctx.lock.get(f"github:{repo}")
        if not resolved:
            log.error("no lock entry for %s; run prepare first", repo)
            continue
        cache = _cache_dir(ctx, repo, resolved["tag"])
        archive = cache / resolved["asset_name"]
        if not archive.exists():
            log.error("cached archive missing: %s", archive)
            continue

        extracted = cache / "extracted"
        if not extracted.exists():
            extract(archive, extracted, strip_components=entry.get("strip_components", 0))

        for b in entry.get("bin", []) or []:
            src = extracted / b["src"]
            if not src.exists():
                matches = list(extracted.glob(b["src"]))
                if matches:
                    src = matches[0]
                else:
                    log.error("bin src not found: %s", src)
                    continue
            sudo_install_file(ctx, src, b["dest"], 0o755)
            log.info("installed %s -> %s", repo, b["dest"])

        for m in entry.get("man", []) or []:
            src = extracted / m["src"]
            if not src.exists():
                log.warning("man src not found: %s", src)
                continue
            sudo_install_file(ctx, src, m["dest"], 0o644)
