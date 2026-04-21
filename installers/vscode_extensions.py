"""VSCode extensions installer.

Runs `code --install-extension` for each entry. Extensions land under
``~/.vscode/extensions`` of the invoking user, so we run the command as
that user (not root).

Offline: prepare resolves the latest version for each extension via the
Marketplace gallery query API, then downloads the .vsix bundle to
cache/vscode/. Install then feeds the cached paths to
`code --install-extension`, which installs fully offline.
"""
from __future__ import annotations

import json
import logging
import os
import pwd
import subprocess
import urllib.request
from pathlib import Path

from ._common import is_command, http_download, _ua_headers

log = logging.getLogger("installers.vscode_extensions")

_MARKETPLACE_API = "https://marketplace.visualstudio.com/_apis/public/gallery"
_QUERY_URL = f"{_MARKETPLACE_API}/extensionquery"
# Filter type 7 = ExtensionName. Flags 131 = IncludeVersions +
# IncludeFiles + IncludeVersionProperties (enough to pick a .vsix asset).
_QUERY_FLAGS = 131


def _cache_dir(ctx) -> Path:
    return ctx.cache_dir / "vscode"


def _vsix_path(ctx, ext_id: str, version: str) -> Path:
    # ext_id is e.g. "ms-python.python"; sanitize for filename.
    safe = ext_id.replace("/", "_")
    return _cache_dir(ctx) / f"{safe}-{version}.vsix"


def _query_latest(ext_id: str) -> tuple[str, str]:
    """Return (version, vsix_download_url) for a 'publisher.name' id."""
    body = json.dumps({
        "filters": [{
            "criteria": [{"filterType": 7, "value": ext_id}],
            "pageNumber": 1,
            "pageSize": 1,
        }],
        "flags": _QUERY_FLAGS,
    }).encode("utf-8")
    headers = {
        **_ua_headers(),
        "Content-Type": "application/json",
        # Must be 3.0-preview.1 for the extensionquery endpoint.
        "Accept": "application/json;api-version=3.0-preview.1",
    }
    req = urllib.request.Request(_QUERY_URL, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.load(resp)

    results = data.get("results") or []
    extensions = results[0].get("extensions", []) if results else []
    if not extensions:
        raise RuntimeError(f"marketplace has no extension matching {ext_id!r}")
    versions = extensions[0].get("versions", [])
    if not versions:
        raise RuntimeError(f"no versions returned for {ext_id!r}")
    v = versions[0]
    version = v["version"]
    for f in v.get("files", []):
        if f.get("assetType") == "Microsoft.VisualStudio.Services.VSIXPackage":
            return version, f["source"]
    raise RuntimeError(f"{ext_id} v{version}: no VSIXPackage asset in response")


def prepare(section: dict, ctx) -> None:
    extensions = section.get("extensions", []) or []
    if not extensions:
        return
    cache = _cache_dir(ctx)
    cache.mkdir(parents=True, exist_ok=True)

    for ext_id in extensions:
        lock_key = f"vscode:{ext_id}"
        locked = ctx.lock.get(lock_key)
        try:
            if locked and not ctx.refresh and "version" in locked:
                version, url = locked["version"], locked["url"]
            else:
                version, url = _query_latest(ext_id)
                ctx.lock[lock_key] = {"version": version, "url": url}
        except Exception as e:
            log.warning("vscode[%s]: marketplace query failed: %s", ext_id, e)
            continue

        dest = _vsix_path(ctx, ext_id, version)
        if dest.exists():
            log.debug("vscode[%s] v%s already cached", ext_id, version)
            continue
        try:
            log.info("vscode: downloading %s v%s", ext_id, version)
            http_download(url, dest)
        except Exception as e:
            log.warning("vscode[%s]: download failed: %s", ext_id, e)


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

    if not is_command("code"):
        log.warning("`code` not on PATH; skipping vscode_extensions "
                    "(install the `code` apt package first)")
        return

    user, home = _invoking_user()
    log.info("installing %d VSCode extensions as user %s", len(extensions), user)

    # If we're running as root (typical under sudo), drop to the real user
    # so extensions land in their $HOME, not /root/.vscode.
    running_as_root = os.geteuid() == 0 and user != "root"

    for ext in extensions:
        # Prefer a cached .vsix — fully offline install. Fall back to
        # letting `code` hit the marketplace by id when no cache exists
        # (e.g. first run on a connected machine).
        locked = ctx.lock.get(f"vscode:{ext}") or {}
        arg = ext
        if "version" in locked:
            path = _vsix_path(ctx, ext, locked["version"])
            if path.exists():
                arg = str(path)
            else:
                log.debug("vscode[%s]: cached path %s missing; hitting marketplace",
                          ext, path)

        cmd: list[str]
        if running_as_root:
            cmd = ["sudo", "-u", user, "-H",
                   "env", f"HOME={home}", "code", "--install-extension", arg, "--force"]
        else:
            cmd = ["code", "--install-extension", arg, "--force"]

        log.info("code --install-extension %s", arg if arg == ext else f"{ext} (vsix)")
        if ctx.dry_run:
            log.info("[dry-run] %s", " ".join(cmd))
            continue
        # Don't abort the whole run if one extension fails (e.g. marketplace
        # rename, transient 503). Report and continue.
        r = subprocess.run(cmd, check=False)
        if r.returncode != 0:
            log.warning("failed to install extension %s (exit=%d)", ext, r.returncode)
