"""apt installer: adds third-party repos, installs packages."""
from __future__ import annotations

import logging
import os
import shlex
import tempfile
from pathlib import Path

from ._common import dpkg_arch, dpkg_installed, http_download

log = logging.getLogger("installers.apt")

KEYRING_DIR = Path("/etc/apt/keyrings")
SOURCES_DIR = Path("/etc/apt/sources.list.d")


def prepare(section: dict, ctx) -> None:
    """Download repo keys into cache/apt/keys/ so install mode can work offline."""
    cache_keys = ctx.cache_dir / "apt" / "keys"
    cache_keys.mkdir(parents=True, exist_ok=True)
    for repo in section.get("repos", []) or []:
        dest = cache_keys / f"{repo['name']}.asc"
        http_download(repo["key_url"], dest)


def install(section: dict, ctx) -> None:
    repos = section.get("repos", []) or []
    packages = section.get("packages", []) or []
    # Components default to main + contrib + non-free + non-free-firmware because
    # a dev/research VM typically needs radare2, rizin, cutter, honggfuzz
    # (contrib) and manpages-posix*, gcc-doc, snmp-mibs-downloader (non-free).
    components = section.get(
        "enable_components",
        ["main", "contrib", "non-free", "non-free-firmware"],
    )

    _ensure_debian_components(components, ctx)

    if repos:
        _install_repos(repos, ctx)

    if packages:
        missing = [p for p in packages if not dpkg_installed(p)]
        if not missing:
            log.info("all %d apt packages already installed", len(packages))
        else:
            if repos or missing:
                ctx.run(
                    ["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "update"],
                    sudo=True,
                )
            _preseed_debconf(packages, ctx)
            log.info("installing %d apt packages (%d missing)", len(packages), len(missing))
            # run the full list so apt re-asserts held state; cheap.
            # `env DEBIAN_FRONTEND=noninteractive` is the only reliable way to
            # suppress debconf prompts — sudo strips env by default, so just
            # exporting in the parent shell isn't enough.
            ctx.run(
                ["env", "DEBIAN_FRONTEND=noninteractive",
                 "apt-get", "install", "-y", "--no-install-recommends", *packages],
                sudo=True,
            )


def _preseed_debconf(packages: list[str], ctx) -> None:
    """Pre-seed debconf answers for packages known to ask questions at install."""
    selections: list[str] = []
    pkgs = set(packages)

    # wireshark / tshark — "Should non-superusers be able to capture packets?"
    # Yes is the right answer for a dev/research VM (this is the whole point
    # of having wireshark as a user tool). Setting the flag causes dumpcap to
    # gain the cap_net_raw,cap_net_admin capabilities and become
    # executable by members of the `wireshark` group.
    if pkgs & {"wireshark", "wireshark-common", "tshark"}:
        selections.append(
            "wireshark-common wireshark-common/install-setuid boolean true"
        )

    # vscode (`code`) — its postinst asks whether to register the
    # Microsoft apt repo (`code/add-microsoft-repo`). We already configured
    # it declaratively via apt.repos, so answer "no" to suppress the prompt
    # and to avoid a second, duplicate sources.list entry.
    if "code" in pkgs:
        selections.append("code code/add-microsoft-repo boolean false")

    if not selections:
        return

    log.info("pre-seeding debconf for %d answer(s)", len(selections))
    blob = "\n".join(selections) + "\n"
    ctx.run(
        ["bash", "-c", f"printf '%s' {shlex.quote(blob)} | debconf-set-selections"],
        sudo=True,
    )


def _ensure_debian_components(components: list[str], ctx) -> None:
    """Make sure /etc/apt/sources.list.d/debian.sources lists `components`.

    Debian 12+ ships DEB822-format sources; we rewrite the `Components:` line
    in place. Idempotent — skips if all requested components are already
    present. No-op on systems without the DEB822 file.
    """
    debian_sources = Path("/etc/apt/sources.list.d/debian.sources")
    if not debian_sources.exists():
        log.debug("no %s; skipping component enablement", debian_sources)
        return

    try:
        current = debian_sources.read_text()
    except PermissionError:
        log.debug("cannot read %s as non-root; skipping component check", debian_sources)
        return

    wanted = set(components)
    # Each 'Components: ...' line is independent; check that every stanza has
    # the wanted set as a subset.
    all_present = True
    for ln in current.splitlines():
        if ln.startswith("Components:"):
            have = set(ln.split(":", 1)[1].split())
            if not wanted.issubset(have):
                all_present = False
                break
    if all_present:
        log.debug("all Debian components already enabled")
        return

    new_line = "Components: " + " ".join(components)
    # sed -E for ERE, replace every Components: line with our full list.
    if ctx.dry_run:
        log.info("[dry-run] would set %s: %s", debian_sources, new_line)
        return
    log.info("enabling Debian components: %s", " ".join(components))
    ctx.run(
        ["sed", "-i", "-E", f"s|^Components:.*$|{new_line}|", str(debian_sources)],
        sudo=True,
    )


def _install_repos(repos: list[dict], ctx) -> None:
    arch = dpkg_arch()
    cache_keys = ctx.cache_dir / "apt" / "keys"
    ctx.run(["install", "-d", "-m", "0755", str(KEYRING_DIR)], sudo=True)
    for repo in repos:
        name = repo["name"]
        key_cached = cache_keys / f"{name}.asc"
        if not key_cached.exists():
            if ctx.dry_run:
                log.info("[dry-run] would fetch repo key for %s", name)
            else:
                # fall back to fetching at install-time (prepare wasn't run).
                log.warning("key for %s not cached; fetching now", name)
                http_download(repo["key_url"], key_cached)

        keyring = KEYRING_DIR / f"{name}.gpg"
        # dearmor via gpg
        ctx.run(
            ["bash", "-c",
             f"gpg --dearmor < {key_cached} > /tmp/{name}.gpg && "
             f"install -m 0644 /tmp/{name}.gpg {keyring} && rm /tmp/{name}.gpg"],
            sudo=True,
        )

        repo_arch = repo.get("arch", arch)
        components = " ".join(repo["components"])
        line = (
            f"deb [arch={repo_arch} signed-by={keyring}] "
            f"{repo['uri']} {repo['suite']} {components}\n"
        )
        list_path = SOURCES_DIR / f"{name}.list"

        # Write the sources.list entry via a tempfile + `install`, so shell
        # quoting / escape-sequence handling never mangles the line.
        if ctx.dry_run:
            log.info("[dry-run] would write %s with %r", list_path, line)
        else:
            with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list") as f:
                f.write(line)
                tmp = f.name
            try:
                ctx.run(["install", "-D", "-m", "0644", tmp, str(list_path)], sudo=True)
            finally:
                os.unlink(tmp)
        log.info("configured apt repo %s", name)
