"""LazyVim offline bundle installer.

Layout:
- installers/neovim_offline/     — source (this package): stage.sh,
                                   install.sh, config/nvim/
- <cache_dir>/neovim_offline/    — artifacts: bin/, jdk/,
                                   share/nvim/{lazy,mason,site}

Staging downloads every asset the bundle needs (nvim, node, JDK,
tree-sitter CLI) into the cache dir, then runs headless nvim to
pre-resolve plugins, Mason packages, and compiled treesitter parsers
there. install.sh deploys from that cache into the invoking user's
$HOME with no further network access required.

Both scripts honour the BUNDLE_DIR env var; this module sets it to
<cache_dir>/neovim_offline so artifacts live under the shared cache/
tree alongside every other offline-capable installer.
"""
from __future__ import annotations

import logging
import os
import pwd
from pathlib import Path

from .._common import is_command

log = logging.getLogger("installers.neovim_offline")

CACHE_SUBDIR = "neovim_offline"

STAGE_TOOLS_BY_MODE = {
    "fetch":   ["curl", "tar"],
    "all":     ["curl", "tar", "unzip", "gcc", "make"],
}
INSTALL_TOOLS = ["tar", "unzip", "curl"]


def _source_dir(section: dict, ctx) -> Path:
    """Where the tracked scripts + config/nvim live (this package dir)."""
    override = section.get("source_dir") or section.get("bundle_dir")
    return Path(override) if override else Path(__file__).resolve().parent


def _bundle_cache(ctx) -> Path:
    """Where downloaded tarballs + staged plugin/mason/ts trees live."""
    return ctx.cache_dir / CACHE_SUBDIR


def _is_staged(bundle_cache: Path) -> bool:
    lazy = bundle_cache / "share" / "nvim" / "lazy"
    if not lazy.is_dir():
        return False
    try:
        return any(lazy.iterdir())
    except OSError:
        return False


def _user_home() -> Path:
    return Path(pwd.getpwuid(os.geteuid()).pw_dir)


def _run_script(ctx, script: Path, bundle_cache: Path, *args: str) -> None:
    """Invoke stage.sh or install.sh with BUNDLE_DIR wired to the cache."""
    ctx.run([
        "env", f"BUNDLE_DIR={bundle_cache}",
        "bash", str(script), *args,
    ])


def prepare(section: dict, ctx) -> None:
    if section.get("enabled") is False:
        log.info("neovim_offline: disabled in config; skipping stage")
        return

    source = _source_dir(section, ctx)
    if not source.is_dir():
        log.warning("neovim_offline: source dir %s not found; skipping", source)
        return

    stage_script = source / "stage.sh"
    if not stage_script.is_file():
        log.warning("neovim_offline: %s missing; skipping", stage_script)
        return

    stage_mode = section.get("stage_mode", "all")
    if stage_mode == "none":
        log.info("neovim_offline: stage_mode=none; skipping stage")
        return
    if stage_mode not in STAGE_TOOLS_BY_MODE:
        log.error("neovim_offline: unknown stage_mode %r", stage_mode)
        return

    missing = [t for t in STAGE_TOOLS_BY_MODE[stage_mode] if not is_command(t)]
    if missing:
        log.warning(
            "neovim_offline prepare: missing tools on PATH (%s); "
            "stage.sh %s may fail. Install them or set stage_mode=fetch/none.",
            ", ".join(missing), stage_mode,
        )

    bundle_cache = _bundle_cache(ctx)
    bundle_cache.mkdir(parents=True, exist_ok=True)
    log.info("neovim_offline: staging into %s", bundle_cache)
    _run_script(ctx, stage_script, bundle_cache, stage_mode)


def install(section: dict, ctx) -> None:
    if section.get("enabled") is False:
        log.info("neovim_offline: disabled in config; skipping install")
        return

    source = _source_dir(section, ctx)
    install_script = source / "install.sh"
    if not install_script.is_file():
        log.warning("neovim_offline: %s missing; skipping", install_script)
        return

    bundle_cache = _bundle_cache(ctx)
    if not _is_staged(bundle_cache):
        log.warning(
            "neovim_offline install: bundle not staged "
            "(empty %s/share/nvim/lazy). Run with --mode prepare on a "
            "connected machine first, or ship cache/neovim_offline/ "
            "alongside this repo.", bundle_cache,
        )
        return

    missing = [t for t in INSTALL_TOOLS if not is_command(t)]
    if missing:
        log.warning(
            "neovim_offline install: missing %s on PATH. Install the "
            "tar/unzip/curl apt packages before re-running.",
            ", ".join(missing),
        )
        return

    home = Path(section.get("home") or _user_home())
    already = (home / ".local/share/nvim-runtime").is_dir() and \
              (home / ".config/nvim").is_dir()
    if already and not ctx.refresh:
        log.info(
            "neovim_offline: already deployed at %s. Remove "
            "%s/.config/nvim and %s/.local/share/nvim-runtime to re-run, "
            "or pass --refresh.", home, home, home,
        )
        return

    log.info("neovim_offline: deploying %s -> %s", bundle_cache, home)
    _run_script(ctx, install_script, bundle_cache, "--force")
