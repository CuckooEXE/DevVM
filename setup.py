#!/usr/bin/env python3
"""DevVMSetup orchestrator. Reads vmconfig.yaml, dispatches to installers."""
from __future__ import annotations

import argparse
import importlib
import json
import logging
import os
import pwd
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml
from jsonschema import Draft202012Validator

SECTION_ORDER = [
    "apt",
    "github_releases",
    "tarballs",
    "rustup",
    "pipx",
    "pip_system",
    "git_sources",
    "docker",
    "docs",
    "fonts",
    "codium_extensions",
    "neovim_offline",
]

log = logging.getLogger("setup")


@dataclass
class Context:
    root: Path
    cache_dir: Path
    mode: str            # "prepare", "install", "full"
    dry_run: bool
    refresh: bool
    lock: dict[str, Any] = field(default_factory=dict)

    def phase_prepare(self) -> bool:
        return self.mode in ("prepare", "full")

    def phase_install(self) -> bool:
        return self.mode in ("install", "full")

    def run(self, argv: list[str], *, sudo: bool = False, check: bool = True,
            capture: bool = False) -> subprocess.CompletedProcess:
        cmd = (["sudo"] + argv) if sudo else argv
        log.debug("exec: %s", " ".join(cmd))
        if self.dry_run:
            log.info("[dry-run] %s", " ".join(cmd))
            return subprocess.CompletedProcess(cmd, 0, b"", b"")
        # USER/HOME are normally populated by login/PAM; when setup.py is
        # invoked from an entrypoint or service they can be missing, which
        # causes `set -u` post-hooks to abort. Fill them from the passwd db
        # so every child process (including post-hooks) has them set.
        env = os.environ.copy()
        pw = pwd.getpwuid(os.geteuid())
        env.setdefault("USER", pw.pw_name)
        env.setdefault("HOME", pw.pw_dir)
        env.setdefault("LOGNAME", pw.pw_name)
        return subprocess.run(
            cmd, check=check, env=env,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )


def load_config(config_path: Path, schema_path: Path) -> dict:
    with config_path.open() as f:
        config = yaml.safe_load(f) or {}
    with schema_path.open() as f:
        schema = json.load(f)
    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(config), key=lambda e: e.absolute_path)
    if errors:
        for err in errors:
            path = "/" + "/".join(str(p) for p in err.absolute_path)
            log.error("config error at %s: %s", path, err.message)
        sys.exit(2)
    return config


def dispatch(section: str, data: Any, ctx: Context, phase: str) -> None:
    module_name = f"installers.{section}"
    try:
        mod = importlib.import_module(module_name)
    except ModuleNotFoundError:
        log.warning("no installer for section %r, skipping", section)
        return
    fn = getattr(mod, phase, None)
    if fn is None:
        log.debug("%s has no %s() phase", module_name, phase)
        return
    log.info("[%s] %s", phase, section)
    fn(data, ctx)


def run_post_hooks(ctx: Context) -> None:
    post_dir = ctx.root / "post"
    if not post_dir.is_dir():
        return
    for script in sorted(post_dir.iterdir()):
        if script.suffix != ".sh" or not script.is_file():
            continue
        log.info("[post] %s", script.name)
        ctx.run(["bash", str(script)])


def write_lock(ctx: Context) -> None:
    if ctx.dry_run or not ctx.lock:
        return
    lockfile = ctx.root / "vmconfig.lock"
    with lockfile.open("w") as f:
        json.dump(ctx.lock, f, indent=2, sort_keys=True)
        f.write("\n")
    log.info("wrote %s", lockfile)


def load_lock(ctx: Context) -> None:
    lockfile = ctx.root / "vmconfig.lock"
    if lockfile.exists():
        with lockfile.open() as f:
            ctx.lock = json.load(f)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="DevVMSetup orchestrator")
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parent,
                    help="project root (default: directory of setup.py)")
    ap.add_argument("--config", type=Path, default=None,
                    help="config file (default: <root>/vmconfig.yaml)")
    ap.add_argument("--schema", type=Path, default=None,
                    help="schema file (default: <root>/schema.json)")
    ap.add_argument("--mode", choices=["prepare", "install", "full"], default="full")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--refresh", action="store_true",
                    help="ignore vmconfig.lock and re-resolve 'latest' versions")
    ap.add_argument("--only", action="append", default=[],
                    help="limit to named section(s); repeatable")
    ap.add_argument("--skip", action="append", default=[],
                    help="skip named section(s); repeatable. Useful to bypass "
                         "a section that's failing (e.g. --skip github_releases "
                         "when the GitHub API is rate-limiting you)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )

    root: Path = args.root.resolve()
    config_path = args.config or (root / "vmconfig.yaml")
    schema_path = args.schema or (root / "schema.json")

    sys.path.insert(0, str(root))

    config = load_config(config_path, schema_path)

    ctx = Context(
        root=root,
        cache_dir=root / "cache",
        mode=args.mode,
        dry_run=args.dry_run,
        refresh=args.refresh,
    )
    ctx.cache_dir.mkdir(exist_ok=True)
    load_lock(ctx)

    sections = SECTION_ORDER
    if args.only:
        sections = [s for s in sections if s in args.only]
    if args.skip:
        unknown = [s for s in args.skip if s not in SECTION_ORDER]
        if unknown:
            log.warning("--skip ignores unknown section(s): %s "
                        "(valid: %s)", ", ".join(unknown), ", ".join(SECTION_ORDER))
        sections = [s for s in sections if s not in args.skip]
        log.info("skipping section(s): %s", ", ".join(args.skip))

    if ctx.phase_prepare():
        for section in sections:
            if section in config:
                dispatch(section, config[section], ctx, "prepare")
        write_lock(ctx)

    if ctx.phase_install():
        for section in sections:
            if section in config:
                dispatch(section, config[section], ctx, "install")
        run_post_hooks(ctx)

    log.info("done (mode=%s)", args.mode)
    return 0


if __name__ == "__main__":
    sys.exit(main())
