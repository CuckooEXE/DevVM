"""Generic tarball installer (Zig, Ghidra, etc.)."""
from __future__ import annotations

import logging
from pathlib import Path

from ._common import extract, http_download, latest_release, pick_asset, http_get_json

log = logging.getLogger("installers.tarballs")

ZIG_TARGET = "x86_64-linux"  # TODO: derive from arch if needed


def _cache_dir(ctx, name: str, version: str) -> Path:
    return ctx.cache_dir / "tarballs" / name / version


def _resolve(entry: dict, ctx) -> dict:
    name = entry["name"]
    lock_key = f"tarball:{name}"
    locked = ctx.lock.get(lock_key)
    if locked and not ctx.refresh and "version" in locked:
        return locked

    resolve = entry.get("resolve", "static")
    if resolve == "github-release":
        repo = entry["url"]  # e.g. "NationalSecurityAgency/ghidra"
        release = latest_release(repo)
        asset = pick_asset(release, entry["asset_regex"])
        resolved = {
            "version": release["tag_name"],
            "asset_name": asset["name"],
            "asset_url": asset["browser_download_url"],
            "asset_size": asset.get("size"),
        }
    elif resolve == "zig-index":
        idx = http_get_json(entry["url"])
        # pick the latest stable (top-level key that looks like a version).
        versions = [k for k in idx.keys() if k and k[0].isdigit()]
        versions.sort(key=lambda v: [int(p) for p in v.split(".") if p.isdigit()], reverse=True)
        latest_version = versions[0]
        target = idx[latest_version].get(ZIG_TARGET)
        if not target:
            raise RuntimeError(f"zig index has no {ZIG_TARGET} for {latest_version}")
        resolved = {
            "version": latest_version,
            "asset_name": target["tarball"].rsplit("/", 1)[-1],
            "asset_url": target["tarball"],
            "asset_size": int(target.get("size", 0)) or None,
        }
    elif resolve == "static":
        resolved = {
            "version": entry.get("version", "static"),
            "asset_name": entry["url"].rsplit("/", 1)[-1],
            "asset_url": entry["url"],
            "asset_size": None,
        }
    else:
        raise RuntimeError(f"unknown resolve mode: {resolve}")

    ctx.lock[lock_key] = resolved
    return resolved


def prepare(section: list, ctx) -> None:
    for entry in section or []:
        resolved = _resolve(entry, ctx)
        cache = _cache_dir(ctx, entry["name"], resolved["version"])
        archive = cache / resolved["asset_name"]
        http_download(resolved["asset_url"], archive,
                      expected_size=resolved.get("asset_size"))


def install(section: list, ctx) -> None:
    for entry in section or []:
        name = entry["name"]
        resolved = ctx.lock.get(f"tarball:{name}")
        if not resolved:
            log.error("no lock entry for tarball %s; run prepare first", name)
            continue
        cache = _cache_dir(ctx, name, resolved["version"])
        archive = cache / resolved["asset_name"]
        if not archive.exists():
            log.error("cached archive missing: %s", archive)
            continue

        install_dir = Path(entry["install_dir"])
        versioned = install_dir / resolved["version"]
        current = install_dir / "current"

        ctx.run(["install", "-d", "-m", "0755", str(install_dir)], sudo=True)
        ctx.run(["install", "-d", "-m", "0755", str(versioned)], sudo=True)

        # Extract into a tmp dir then move into place, so failures don't leave partial installs.
        tmp_dir = cache / "extracted"
        if not tmp_dir.exists():
            extract(archive, tmp_dir,
                    strip_components=entry.get("strip_components", 1))

        ctx.run(["cp", "-a", f"{tmp_dir}/.", str(versioned)], sudo=True)
        ctx.run(["ln", "-sfn", str(versioned), str(current)], sudo=True)
        log.info("installed %s %s -> %s", name, resolved["version"], current)

        for sl in entry.get("symlinks", []) or []:
            ctx.run(["ln", "-sfn", sl["src"], sl["dest"]], sudo=True)
