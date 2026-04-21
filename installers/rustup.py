"""rustup installer.

Offline story: prepare runs rustup-init into a private
cache/rustup/{rustup,cargo}/ tree, populating it with every toolchain /
component / target the config asks for. Install then rsyncs that tree
into $HOME/.rustup + $HOME/.cargo for the invoking user, with no network
access needed.

Caveat: the cached tree is specific to the prepare host's arch (we target
x86_64-unknown-linux-gnu only). That's fine for this project's use case
— prepare machine and coworker VMs are all amd64 Debian.
"""
from __future__ import annotations

import logging
import os
import pwd
import subprocess
from pathlib import Path

from ._common import http_download, is_command

log = logging.getLogger("installers.rustup")

RUSTUP_INIT_URL = "https://sh.rustup.rs"


def _cache_roots(ctx) -> tuple[Path, Path, Path]:
    """Return (cache_dir, rustup_home, cargo_home)."""
    cache = ctx.cache_dir / "rustup"
    return cache, cache / "rustup", cache / "cargo"


def _invoking_user() -> tuple[str, str]:
    name = os.environ.get("SUDO_USER") or os.environ.get("USER") \
        or pwd.getpwuid(os.geteuid()).pw_name
    try:
        home = pwd.getpwnam(name).pw_dir
    except KeyError:
        home = os.path.expanduser("~" + name)
    return name, home


def prepare(section: dict, ctx) -> None:
    toolchains = section.get("toolchains", ["stable"]) or ["stable"]
    default = section.get("default", toolchains[0])
    components = section.get("components", []) or []
    targets = section.get("targets", []) or []

    cache, rustup_home, cargo_home = _cache_roots(ctx)
    cache.mkdir(parents=True, exist_ok=True)

    installer = cache / "rustup-init.sh"
    http_download(RUSTUP_INIT_URL, installer)

    env = {
        **os.environ,
        "RUSTUP_HOME": str(rustup_home),
        "CARGO_HOME":  str(cargo_home),
    }
    rustup_bin = cargo_home / "bin" / "rustup"

    if not rustup_bin.exists():
        log.info("rustup: installing into cache at %s", cache)
        if ctx.dry_run:
            log.info("[dry-run] bash %s -y --no-modify-path …", installer)
        else:
            subprocess.run([
                "bash", str(installer),
                "-y",
                "--no-modify-path",
                "--default-toolchain", default,
                "--profile", "minimal",
            ], env=env, check=True)
    else:
        log.info("rustup: cache-dir install already present at %s", cargo_home)

    rustup_str = str(rustup_bin)

    def _rustup(*args: str) -> None:
        if ctx.dry_run:
            log.info("[dry-run] rustup %s", " ".join(args))
            return
        subprocess.run([rustup_str, *args], env=env, check=True)

    for tc in toolchains:
        log.info("rustup: caching toolchain %s", tc)
        _rustup("toolchain", "install", tc, "--profile", "minimal")
    log.info("rustup: setting default toolchain → %s", default)
    _rustup("default", default)
    if components:
        log.info("rustup: adding components %s", components)
        _rustup("component", "add", *components)
    if targets:
        log.info("rustup: adding targets %s", targets)
        _rustup("target", "add", *targets)


def install(section: dict, ctx) -> None:
    _, rustup_home, cargo_home = _cache_roots(ctx)
    user, user_home = _invoking_user()
    target_rustup = Path(user_home) / ".rustup"
    target_cargo  = Path(user_home) / ".cargo"

    cached = rustup_home.is_dir() and cargo_home.is_dir()
    if cached:
        log.info("rustup: deploying cached toolchain → %s + %s",
                 target_rustup, target_cargo)
        _copy_tree(rustup_home, target_rustup, user, ctx)
        _copy_tree(cargo_home,  target_cargo,  user, ctx)
        return

    # Fallback: no cache — do the old online-install flow in the user's
    # home directly.
    log.info("rustup: no cache at %s — falling back to online install",
             rustup_home)
    _online_install_fallback(section, ctx)


def _copy_tree(src: Path, dest: Path, user: str, ctx) -> None:
    # Use rsync -a to preserve rustup's symlinks (toolchain/bin/* are
    # symlinks under the hood on some platforms), then chown the tree
    # to the invoking user.
    running_as_root = os.geteuid() == 0 and user != "root"
    rsync_cmd = ["rsync", "-a", "--delete", f"{src}/", f"{dest}/"]
    if running_as_root:
        ctx.run(rsync_cmd, sudo=False)
        ctx.run(["chown", "-R", f"{user}:{user}", str(dest)], sudo=True)
    else:
        ctx.run(rsync_cmd)


def _online_install_fallback(section: dict, ctx) -> None:
    toolchains = section.get("toolchains", ["stable"]) or ["stable"]
    default = section.get("default", toolchains[0])
    components = section.get("components", []) or []
    targets = section.get("targets", []) or []

    cargo_bin = Path.home() / ".cargo" / "bin"
    rustup = cargo_bin / "rustup"

    if not rustup.exists() and not is_command("rustup"):
        installer = ctx.cache_dir / "rustup" / "rustup-init.sh"
        if not installer.exists():
            log.error("rustup installer not cached; run prepare first")
            return
        ctx.run(["bash", str(installer), "-y", "--no-modify-path",
                 "--default-toolchain", default, "--profile", "minimal"])

    rustup_cmd = str(rustup) if rustup.exists() else "rustup"
    for tc in toolchains:
        ctx.run([rustup_cmd, "toolchain", "install", tc])
    ctx.run([rustup_cmd, "default", default])
    if components:
        ctx.run([rustup_cmd, "component", "add", *components])
    if targets:
        ctx.run([rustup_cmd, "target", "add", *targets])
