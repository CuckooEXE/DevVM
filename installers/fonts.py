"""Fonts installer: cached download + system-wide install of font archives.

Prepare fetches each font's archive into cache/fonts/<name>/ so install
runs can work offline. Install extracts the matching files into install_dir
(typically somewhere under /usr/share/fonts) and refreshes the font cache.
"""
from __future__ import annotations

import logging
import shutil
from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZipFile

from ._common import http_download, is_command

log = logging.getLogger("installers.fonts")


def _cache_dir(ctx, name: str) -> Path:
    return ctx.cache_dir / "fonts" / name


def _archive_path(ctx, entry: dict) -> Path:
    name = entry["name"]
    url = entry["url"]
    return _cache_dir(ctx, name) / url.rsplit("/", 1)[-1]


def prepare(section: list, ctx) -> None:
    for entry in section or []:
        archive = _archive_path(ctx, entry)
        http_download(entry["url"], archive)


def install(section: list, ctx) -> None:
    if not section:
        return
    for entry in section or []:
        name = entry["name"]
        archive = _archive_path(ctx, entry)
        if not archive.exists():
            log.error("fonts[%s]: archive missing at %s; run prepare first",
                      name, archive)
            continue

        install_dir = Path(entry["install_dir"])
        pattern = entry.get("extract_pattern", "*.ttf")

        # Extract matching files to a temp dir, then sudo-install them to
        # install_dir. This keeps the extract/copy split clean: we only
        # touch install_dir through `install -m 0644 -D`, preserving mode.
        with TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            _extract_matching(archive, tmp_path, pattern)
            files = list(tmp_path.rglob(pattern))
            if not files:
                log.warning("fonts[%s]: no files matched %r in %s",
                            name, pattern, archive.name)
                continue
            ctx.run(["install", "-d", "-m", "0755", str(install_dir)],
                    sudo=True)
            # `install -m 0644 -D -t dest src...` installs multiple files
            # into dest with mode 0644 in one call.
            ctx.run(
                ["install", "-m", "0644", "-D", "-t", str(install_dir),
                 *[str(f) for f in files]],
                sudo=True,
            )

        if is_command("fc-cache"):
            log.info("fonts[%s]: refreshing font cache for %s", name, install_dir)
            ctx.run(["fc-cache", "-f", str(install_dir)], sudo=True)
        else:
            log.warning("fonts[%s]: fc-cache not available — installed files "
                        "are in place but not registered with fontconfig", name)


def _extract_matching(archive: Path, dest: Path, pattern: str) -> None:
    """Extract files matching `pattern` from a .zip into `dest`.

    For now only .zip archives are supported (Nerd Fonts ship as zips).
    Extend with tar handling here if a future font needs it.
    """
    name = archive.name.lower()
    if not name.endswith(".zip"):
        raise RuntimeError(f"fonts: unsupported archive format: {archive.name}")
    # zipfile.ZipFile.extract writes to dest; we glob-filter members up
    # front so we don't pull binaries we'll just throw away.
    with ZipFile(archive) as zf:
        import fnmatch
        for info in zf.infolist():
            if info.is_dir():
                continue
            base = info.filename.rsplit("/", 1)[-1]
            if not fnmatch.fnmatch(base, pattern):
                continue
            target = dest / base
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, target.open("wb") as dst:
                shutil.copyfileobj(src, dst)
