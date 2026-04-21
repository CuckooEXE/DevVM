"""VSCode extensions installer.

Runs `code --install-extension <id>` for each entry. Extensions land under
``~/.vscode/extensions`` of the invoking user, so we run the command as
that user (not root). We don't skip on pre-install check here because
`code --list-extensions` is almost as slow as a no-op install, and
``--install-extension`` is already idempotent.
"""
from __future__ import annotations

import logging
import os
import pwd
import subprocess

from ._common import is_command

log = logging.getLogger("installers.vscode_extensions")


def prepare(section: dict, ctx) -> None:
    # Nothing to pre-cache — the VSCode CLI talks directly to the
    # marketplace at install time.
    return


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
        cmd: list[str]
        if running_as_root:
            cmd = ["sudo", "-u", user, "-H",
                   "env", f"HOME={home}", "code", "--install-extension", ext, "--force"]
        else:
            cmd = ["code", "--install-extension", ext, "--force"]

        log.info("code --install-extension %s", ext)
        if ctx.dry_run:
            log.info("[dry-run] %s", " ".join(cmd))
            continue
        # Don't abort the whole run if one extension fails (e.g. marketplace
        # rename, transient 503). Report and continue.
        r = subprocess.run(cmd, check=False)
        if r.returncode != 0:
            log.warning("failed to install extension %s (exit=%d)", ext, r.returncode)
