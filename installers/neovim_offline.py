"""NeovimOffline installer: stages the LazyVim bundle during prepare, deploys it during install.

The bundle lives at <root>/NeovimOffline/. Staging downloads every asset the
bundle needs (nvim, node, JDK, Nerd Font, tree-sitter CLI) and runs headless
nvim to pre-resolve plugins, Mason packages, and compiled treesitter parsers.
install.sh then deploys everything into the invoking user's $HOME with no
further network access required.
"""
from __future__ import annotations

import logging
import os
import pwd
import shutil
from pathlib import Path

from ._common import is_command

log = logging.getLogger("installers.neovim_offline")

BUNDLE_DIRNAME = "NeovimOffline"
STAGE_TOOLS_BY_MODE = {
    "fetch":   ["curl", "tar"],
    "all":     ["curl", "tar", "unzip", "gcc", "make"],
}
INSTALL_TOOLS = ["tar", "unzip", "curl", "fc-cache"]


def _bundle_dir(section: dict, ctx) -> Path:
    bundle = section.get("bundle_dir")
    return Path(bundle) if bundle else (ctx.root / BUNDLE_DIRNAME)


def _is_staged(bundle: Path) -> bool:
    lazy = bundle / "share" / "nvim" / "lazy"
    if not lazy.is_dir():
        return False
    try:
        return any(lazy.iterdir())
    except OSError:
        return False


def _user_home() -> Path:
    return Path(pwd.getpwuid(os.geteuid()).pw_dir)


def _link_cache(bundle: Path, ctx) -> None:
    """Expose bundle-relative downloads under cache/neovim_offline/ as symlinks."""
    if ctx.dry_run:
        return
    cache_link = ctx.cache_dir / "neovim_offline"
    cache_link.mkdir(parents=True, exist_ok=True)
    for sub in ("bin", "jdk", "fonts", "share", ".downloads"):
        src = bundle / sub
        if not src.exists():
            continue
        link = cache_link / sub.lstrip(".")
        if link.is_symlink() or link.exists():
            continue
        try:
            link.symlink_to(src)
        except OSError as e:
            log.debug("could not symlink %s -> %s: %s", link, src, e)


def prepare(section: dict, ctx) -> None:
    if section.get("enabled") is False:
        log.info("neovim_offline: disabled in config; skipping stage")
        return

    bundle = _bundle_dir(section, ctx)
    if not bundle.is_dir():
        log.warning("neovim_offline: bundle dir %s not found; skipping", bundle)
        return

    stage_script = bundle / "stage.sh"
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

    log.info("neovim_offline: running %s %s", stage_script.name, stage_mode)
    ctx.run(["bash", str(stage_script), stage_mode])

    _link_cache(bundle, ctx)


def install(section: dict, ctx) -> None:
    if section.get("enabled") is False:
        log.info("neovim_offline: disabled in config; skipping install")
        return

    bundle = _bundle_dir(section, ctx)
    install_script = bundle / "install.sh"
    if not install_script.is_file():
        log.warning("neovim_offline: %s missing; skipping", install_script)
        return

    if not _is_staged(bundle):
        log.warning(
            "neovim_offline install: bundle not staged "
            "(empty %s/share/nvim/lazy). Run with --mode prepare on a "
            "connected machine first.", bundle,
        )
        return

    missing = [t for t in INSTALL_TOOLS if not is_command(t)]
    if missing:
        log.warning(
            "neovim_offline install: missing %s on PATH. Install the "
            "tar/unzip/curl/fontconfig apt packages before re-running.",
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

    log.info("neovim_offline: deploying bundle -> %s", home)
    ctx.run(["bash", str(install_script), "--force"])
