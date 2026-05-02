"""VSCodium extensions installer.

Runs `codium --install-extension` for each entry. Extensions land under
``~/.vscode-oss/extensions`` of the invoking user, so we run the command
as that user (not root).

Offline: prepare resolves the latest version for each extension via the
Open VSX REST API, then downloads the .vsix bundle to cache/codium/.
Install then feeds the cached paths to `codium --install-extension`,
which installs fully offline.

Why Open VSX rather than the Microsoft marketplace: VSCodium is not a
Microsoft product, and the Microsoft marketplace ToS forbid non-MS
clients from using it. Open VSX (https://open-vsx.org) is the registry
VSCodium is configured against by default.
"""
from __future__ import annotations

import json
import logging
import os
import pwd
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

from ._common import is_command, http_download, _ua_headers

log = logging.getLogger("installers.codium_extensions")

_OPENVSX_API = "https://open-vsx.org/api"
# CodeLLDB and a few others publish per-platform .vsix bundles. Try the
# Linux x64 channel first, fall back to the universal channel for the
# (overwhelming majority of) extensions that publish a single bundle.
_TARGET_PLATFORM = "linux-x64"


def _cache_dir(ctx) -> Path:
    return ctx.cache_dir / "codium"


def _vsix_path(ctx, ext_id: str, version: str) -> Path:
    safe = ext_id.replace("/", "_")
    return _cache_dir(ctx) / f"{safe}-{version}.vsix"


def _split_id(ext_id: str) -> tuple[str, str]:
    if "." not in ext_id:
        raise ValueError(f"extension id must be 'publisher.name', got {ext_id!r}")
    publisher, name = ext_id.split(".", 1)
    return publisher, name


def _fetch_metadata(url: str) -> dict | None:
    """GET a JSON metadata blob, returning None on 404."""
    req = urllib.request.Request(url, headers={**_ua_headers(), "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def _query_latest(ext_id: str) -> tuple[str, str]:
    """Return (version, vsix_download_url) for a 'publisher.name' id."""
    publisher, name = _split_id(ext_id)
    # Try the linux-x64 target first so platform-specific extensions
    # (e.g. vadimcn.vscode-lldb) get the correct binary.
    candidates = [
        f"{_OPENVSX_API}/{publisher}/{name}/{_TARGET_PLATFORM}/latest",
        f"{_OPENVSX_API}/{publisher}/{name}/latest",
    ]
    last_err: Exception | None = None
    for url in candidates:
        try:
            data = _fetch_metadata(url)
        except Exception as e:
            last_err = e
            continue
        if not data:
            continue
        version = data.get("version")
        download = (data.get("files") or {}).get("download")
        if version and download:
            return version, download
    if last_err:
        raise last_err
    raise RuntimeError(f"open-vsx has no extension matching {ext_id!r}")


def prepare(section: dict, ctx) -> None:
    extensions = section.get("extensions", []) or []
    if not extensions:
        return
    cache = _cache_dir(ctx)
    cache.mkdir(parents=True, exist_ok=True)

    for ext_id in extensions:
        lock_key = f"codium:{ext_id}"
        locked = ctx.lock.get(lock_key)
        try:
            if locked and not ctx.refresh and "version" in locked:
                version, url = locked["version"], locked["url"]
            else:
                version, url = _query_latest(ext_id)
                ctx.lock[lock_key] = {"version": version, "url": url}
        except Exception as e:
            log.warning("codium[%s]: open-vsx query failed: %s", ext_id, e)
            continue

        dest = _vsix_path(ctx, ext_id, version)
        if dest.exists():
            log.debug("codium[%s] v%s already cached", ext_id, version)
            continue
        try:
            log.info("codium: downloading %s v%s", ext_id, version)
            http_download(url, dest)
        except Exception as e:
            log.warning("codium[%s]: download failed: %s", ext_id, e)


def _invoking_user() -> tuple[str, str]:
    """Return (username, home) of the human driving this run.

    ``SUDO_USER`` is populated when the script is invoked under sudo,
    which is how bootstrap.sh normally runs. Falling back to ``USER``
    covers the bare-run case.
    """
    name = os.environ.get("SUDO_USER") or os.environ.get("USER") or pwd.getpwuid(os.geteuid()).pw_name
    try:
        home = pwd.getpwnam(name).pw_dir
    except KeyError:
        home = os.path.expanduser("~" + name)
    return name, home


def install(section: dict, ctx) -> None:
    extensions = section.get("extensions", []) or []
    if not extensions:
        return

    if not is_command("codium"):
        log.warning("`codium` not on PATH; skipping codium_extensions "
                    "(install the `codium` apt package first)")
        return

    user, home = _invoking_user()
    log.info("installing %d Codium extensions as user %s", len(extensions), user)

    # If we're running as root (typical under sudo), drop to the real user
    # so extensions land in their $HOME, not /root/.vscode-oss.
    running_as_root = os.geteuid() == 0 and user != "root"

    for ext in extensions:
        # Prefer a cached .vsix — fully offline install. Fall back to
        # letting `codium` hit Open VSX by id when no cache exists
        # (e.g. first run on a connected machine).
        locked = ctx.lock.get(f"codium:{ext}") or {}
        arg = ext
        if "version" in locked:
            path = _vsix_path(ctx, ext, locked["version"])
            if path.exists():
                arg = str(path)
            else:
                log.debug("codium[%s]: cached path %s missing; hitting open-vsx",
                          ext, path)

        cmd: list[str]
        if running_as_root:
            cmd = ["sudo", "-u", user, "-H",
                   "env", f"HOME={home}", "codium", "--install-extension", arg, "--force"]
        else:
            cmd = ["codium", "--install-extension", arg, "--force"]

        log.info("codium --install-extension %s", arg if arg == ext else f"{ext} (vsix)")
        if ctx.dry_run:
            log.info("[dry-run] %s", " ".join(cmd))
            continue
        # Don't abort the whole run if one extension fails (e.g. registry
        # rename, transient 503). Report and continue.
        r = subprocess.run(cmd, check=False)
        if r.returncode != 0:
            log.warning("failed to install extension %s (exit=%d)", ext, r.returncode)
