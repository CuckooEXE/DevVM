"""rustup installer."""
from __future__ import annotations

import logging
import subprocess
from pathlib import Path

from ._common import http_download, is_command

log = logging.getLogger("installers.rustup")

RUSTUP_INIT_URL = "https://sh.rustup.rs"


def prepare(section: dict, ctx) -> None:
    cache = ctx.cache_dir / "rustup"
    cache.mkdir(parents=True, exist_ok=True)
    http_download(RUSTUP_INIT_URL, cache / "rustup-init.sh")


def install(section: dict, ctx) -> None:
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
        log.info("running rustup-init")
        ctx.run([
            "bash", str(installer),
            "-y",
            "--no-modify-path",
            "--default-toolchain", default,
            "--profile", "minimal",
        ])

    rustup_cmd = str(rustup) if rustup.exists() else "rustup"

    # Ensure toolchains + default
    for tc in toolchains:
        ctx.run([rustup_cmd, "toolchain", "install", tc])
    ctx.run([rustup_cmd, "default", default])

    if components:
        ctx.run([rustup_cmd, "component", "add", *components])
    if targets:
        ctx.run([rustup_cmd, "target", "add", *targets])
