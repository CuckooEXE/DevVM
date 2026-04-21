"""Shared helpers for installers."""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile
from pathlib import Path
from typing import Any, Iterable

log = logging.getLogger("installers")

DEFAULT_TIMEOUT = 60
GITHUB_API = "https://api.github.com"


def dpkg_arch() -> str:
    out = subprocess.run(
        ["dpkg", "--print-architecture"], check=True, capture_output=True, text=True
    )
    return out.stdout.strip()


def _ua_headers() -> dict[str, str]:
    h = {"User-Agent": "DevVMSetup/1.0"}
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def http_get_json(url: str) -> dict:
    req = urllib.request.Request(url, headers=_ua_headers())
    with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp:
        return json.load(resp)


def http_download(url: str, dest: Path, *, expected_size: int | None = None) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and (expected_size is None or dest.stat().st_size == expected_size):
        log.debug("cached: %s", dest)
        return dest
    tmp = dest.with_suffix(dest.suffix + ".part")
    log.info("downloading %s -> %s", url, dest)
    req = urllib.request.Request(url, headers=_ua_headers())
    with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp, tmp.open("wb") as f:
        shutil.copyfileobj(resp, f)
    tmp.replace(dest)
    return dest


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def latest_release(repo: str) -> dict:
    """GitHub releases/latest payload."""
    return http_get_json(f"{GITHUB_API}/repos/{repo}/releases/latest")


def pick_asset(release: dict, asset_regex: str) -> dict:
    # Case-insensitive: vendors are inconsistent about Linux/linux, X64/x64,
    # etc. If a pattern needs strict casing, anchor it with (?-i:...).
    pat = re.compile(asset_regex, re.IGNORECASE)
    for asset in release.get("assets", []):
        if pat.search(asset["name"]):
            return asset
    names = [a["name"] for a in release.get("assets", [])]
    raise RuntimeError(
        f"no asset matched {asset_regex!r} in release {release.get('tag_name')} "
        f"(saw {names})"
    )


def extract(archive: Path, dest: Path, strip_components: int = 0) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    name = archive.name.lower()
    if name.endswith((".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".tar.zst", ".tar")):
        _extract_tar(archive, dest, strip_components)
    elif name.endswith(".zip"):
        _extract_zip(archive, dest, strip_components)
    elif name.endswith((".gz",)):
        import gzip
        out = dest / archive.stem
        with gzip.open(archive, "rb") as src, out.open("wb") as dst:
            shutil.copyfileobj(src, dst)
    else:
        # assume it's a raw binary
        shutil.copy2(archive, dest / archive.name)


def _extract_tar(archive: Path, dest: Path, strip_components: int) -> None:
    mode = "r:*"
    if archive.name.endswith(".tar.zst"):
        # tarfile doesn't natively speak zstd across all versions; shell out.
        subprocess.run(
            ["tar", "--zstd", "-xf", str(archive), "-C", str(dest),
             f"--strip-components={strip_components}"],
            check=True,
        )
        return
    with tarfile.open(archive, mode) as tf:
        members = []
        for m in tf.getmembers():
            parts = m.name.split("/")
            if strip_components:
                if len(parts) <= strip_components:
                    continue
                m.name = "/".join(parts[strip_components:])
            members.append(m)
        tf.extractall(dest, members=members, filter="data")


def _extract_zip(archive: Path, dest: Path, strip_components: int) -> None:
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            parts = info.filename.split("/")
            if strip_components:
                if len(parts) <= strip_components:
                    continue
                new_name = "/".join(parts[strip_components:])
            else:
                new_name = info.filename
            if not new_name or new_name.endswith("/"):
                continue
            target = dest / new_name
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, target.open("wb") as dst:
                shutil.copyfileobj(src, dst)
            if info.external_attr >> 16 & 0o111:
                target.chmod(target.stat().st_mode | 0o755)


def sudo_install_file(ctx, src: Path, dest: str, mode: int = 0o755) -> None:
    """Copy src -> dest with sudo, preserving mode."""
    ctx.run(["install", "-D", "-m", oct(mode)[2:], str(src), dest], sudo=True)


def dpkg_installed(pkg: str) -> bool:
    r = subprocess.run(
        ["dpkg-query", "-W", "-f=${Status}", pkg],
        capture_output=True, text=True,
    )
    return r.returncode == 0 and "install ok installed" in r.stdout


def is_command(name: str) -> bool:
    return shutil.which(name) is not None
