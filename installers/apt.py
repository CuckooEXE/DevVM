"""apt installer: adds third-party repos, installs packages.

Offline story: prepare downloads all required .debs (plus their full
transitive dep closure) into cache/apt/debs/. Install tries dpkg -i from
that cache first and only falls through to online apt-get when the cache
is empty. Same pattern as bootstrap.sh uses for its own apt prereqs.
"""
from __future__ import annotations

import logging
import os
import re
import shlex
import tempfile
import urllib.parse
from pathlib import Path

from ._common import dpkg_arch, dpkg_installed, http_download

log = logging.getLogger("installers.apt")

KEYRING_DIR = Path("/etc/apt/keyrings")
SOURCES_DIR = Path("/etc/apt/sources.list.d")
SOURCES_LIST = Path("/etc/apt/sources.list")


def prepare(section: dict, ctx) -> None:
    """Download repo keys + all package .debs into cache/apt/."""
    cache_keys = ctx.cache_dir / "apt" / "keys"
    cache_keys.mkdir(parents=True, exist_ok=True)
    for repo in section.get("repos", []) or []:
        dest = cache_keys / f"{repo['name']}.asc"
        http_download(repo["key_url"], dest)

    packages = section.get("packages", []) or []
    if not packages:
        return

    debs = ctx.cache_dir / "apt" / "debs"
    # apt requires a partial/ subdir inside the archive cache.
    ctx.run(["install", "-d", "-m", "0755", str(debs), str(debs / "partial")],
            sudo=True)

    # Repos need to be configured on the prepare host too — otherwise
    # packages from docker-ce / vscode can't be resolved when we go to
    # --download-only them. Wire repos and refresh apt.
    _ensure_debian_components(
        section.get("enable_components",
                    ["main", "contrib", "non-free", "non-free-firmware"]),
        ctx,
    )
    repos = section.get("repos", []) or []
    if repos:
        _install_repos(repos, ctx)
    log.info("apt-get update (prepare: refresh indices before deb download)")
    ctx.run(["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "update"],
            sudo=True, check=False)

    # --reinstall forces apt to include pkgs already installed on the
    # prepare host, so the cache is portable to a fresh coworker machine.
    # Dir::Cache::Archives redirects the download dir for this invocation.
    log.info("apt: caching %d pkgs (+ transitive deps) to %s",
             len(packages), debs)
    ctx.run([
        "env", "DEBIAN_FRONTEND=noninteractive",
        "apt-get", "install", "-y",
        "--download-only", "--reinstall", "--no-install-recommends",
        "-o", f"Dir::Cache::Archives={debs}",
        *packages,
    ], sudo=True)

    # Let non-root users copy/rsync the cache bundle around later.
    ctx.run(["chmod", "-R", "a+rX", str(debs)], sudo=True)


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

    if not packages:
        return

    missing = [p for p in packages if not dpkg_installed(p)]
    if not missing:
        log.info("all %d apt packages already installed", len(packages))
        return

    _preseed_debconf(packages, ctx)

    debs = ctx.cache_dir / "apt" / "debs"
    deb_files = sorted(debs.glob("*.deb")) if debs.is_dir() else []
    if deb_files:
        log.info("installing %d apt packages from local .deb cache (%d files)",
                 len(missing), len(deb_files))
        # Install the whole cached closure through apt-get, NOT raw `dpkg -i`.
        # `dpkg -i *.deb` processes files in argv order and cannot satisfy
        # Pre-Depends that sort later on the command line — it bails with
        # "pre-dependency problem - not installing <pkg>", and once enough
        # pile up dpkg hits its error ceiling ("too many errors, stopping"),
        # aborting the transaction in a state `apt-get -f install` can't
        # recover. Handing every .deb to apt as a local file lets apt compute
        # a correct unpack/configure order (Pre-Depends included) and resolve
        # deps among the cached files. `--no-download` keeps it offline: prepare
        # cached the full transitive closure, so a genuinely missing dep now
        # fails loudly here instead of silently cascading.
        ctx.run(
            ["env", "DEBIAN_FRONTEND=noninteractive",
             "apt-get", "install", "-y",
             "--no-install-recommends", "--allow-downgrades", "--no-download",
             "-o", f"Dir::Cache::Archives={debs}",
             *[str(p) for p in deb_files]],
            sudo=True,
        )
    else:
        log.info("no cached .debs at %s — falling back to online apt-get install",
                 debs)
        ctx.run(
            ["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "update"],
            sudo=True,
        )
        # run the full list so apt re-asserts held state; cheap.
        # `env DEBIAN_FRONTEND=noninteractive` is the only reliable way to
        # suppress debconf prompts — sudo strips env by default.
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

    if not selections:
        return

    log.info("pre-seeding debconf for %d answer(s)", len(selections))
    blob = "\n".join(selections) + "\n"
    ctx.run(
        ["bash", "-c", f"printf '%s' {shlex.quote(blob)} | debconf-set-selections"],
        sudo=True,
    )


def _ensure_debian_components(components: list[str], ctx) -> None:
    """Ensure every Debian mirror lists `components` (main/contrib/non-free/…).

    Walks all apt source definitions — the legacy one-line format in
    /etc/apt/sources.list and /etc/apt/sources.list.d/*.list, plus the
    DEB822 format in /etc/apt/sources.list.d/*.sources — and, for entries
    that point at a Debian archive mirror, adds any missing requested
    components without dropping ones the admin already enabled.

    Third-party repos (docker, vscode, tailscale, …) are left untouched:
    only entries recognized as Debian mirrors are rewritten. Idempotent —
    files already carrying every requested component are not rewritten.
    """
    wanted = list(components)

    # (path, format) for every source file that could hold a Debian mirror.
    targets: list[tuple[Path, str]] = []
    if SOURCES_LIST.exists():
        targets.append((SOURCES_LIST, "legacy"))
    if SOURCES_DIR.is_dir():
        targets += [(p, "deb822") for p in sorted(SOURCES_DIR.glob("*.sources"))]
        targets += [(p, "legacy") for p in sorted(SOURCES_DIR.glob("*.list"))]

    if not targets:
        log.debug("no apt source files found; skipping component enablement")
        return

    for path, fmt in targets:
        try:
            current = path.read_text()
        except (PermissionError, OSError) as exc:
            log.debug("cannot read %s (%s); skipping", path, exc)
            continue

        rewrite = _rewrite_deb822 if fmt == "deb822" else _rewrite_legacy
        updated, changed = rewrite(current, wanted)
        if not changed:
            continue

        if ctx.dry_run:
            log.info("[dry-run] would enable Debian components in %s: %s",
                     path, " ".join(wanted))
            continue
        log.info("enabling Debian components in %s: %s", path, " ".join(wanted))
        _write_root_file(path, updated, ctx)


# Hosts recognized as Debian archive mirrors. A local/corporate mirror that
# doesn't live under *.debian.org is still matched by the "/debian" path
# heuristic below (e.g. http://mirror.corp/debian trixie main).
def _uri_is_debian(uri: str) -> bool:
    try:
        parsed = urllib.parse.urlparse(uri)
    except ValueError:
        return False
    host = (parsed.hostname or "").lower()
    if host == "debian.org" or host.endswith(".debian.org"):
        return True
    # Local/corporate mirrors: the Debian archive is served at the path root
    # (/debian, /debian-security, /debian-ports). Require the first path
    # segment to be debian-ish so we don't match third-party repos that merely
    # nest "debian" deeper (e.g. download.docker.com/linux/debian).
    segments = parsed.path.lower().strip("/").split("/")
    first = segments[0] if segments else ""
    return first == "debian" or first.startswith("debian-")


def _is_debian_source(uris: list[str], signed_by: str | None) -> bool:
    """A source is a Debian mirror if it's signed by the Debian archive key
    or any of its URIs points at a Debian archive path/host."""
    if signed_by and "debian-archive-keyring" in signed_by:
        return True
    return any(_uri_is_debian(u) for u in uris)


def _merge_components(existing: list[str], wanted: list[str]) -> list[str]:
    """Existing components, then any wanted ones not already present. Preserves
    the admin's order and never removes a component."""
    merged = list(existing)
    for comp in wanted:
        if comp not in merged:
            merged.append(comp)
    return merged


def _rewrite_legacy(text: str, wanted: list[str]) -> tuple[str, bool]:
    """Rewrite legacy `deb`/`deb-src` lines for Debian mirrors, appending any
    missing components. Non-Debian lines and comments pass through verbatim."""
    line_re = re.compile(
        r"^(?P<indent>\s*)(?P<type>deb(?:-src)?)\s+"
        r"(?P<opts>\[[^\]]*\]\s+)?"
        r"(?P<uri>\S+)\s+(?P<suite>\S+)\s+(?P<comps>.+?)\s*$"
    )
    changed = False
    out: list[str] = []
    for line in text.split("\n"):
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            out.append(line)
            continue
        m = line_re.match(line)
        if not m:
            out.append(line)
            continue

        opts = m.group("opts") or ""
        sb = re.search(r"signed-by=(\S+)", opts)
        signed_by = sb.group(1) if sb else None
        if not _is_debian_source([m.group("uri")], signed_by):
            out.append(line)
            continue

        existing = m.group("comps").split()
        merged = _merge_components(existing, wanted)
        if merged == existing:
            out.append(line)
            continue

        out.append(
            f"{m.group('indent')}{m.group('type')} {opts}"
            f"{m.group('uri')} {m.group('suite')} {' '.join(merged)}"
        )
        changed = True
    return "\n".join(out), changed


def _rewrite_deb822(text: str, wanted: list[str]) -> tuple[str, bool]:
    """Rewrite the `Components:` line of DEB822 stanzas that describe a Debian
    mirror, appending any missing components. Other stanzas pass through."""
    changed = False

    def flush(stanza: list[str]) -> list[str]:
        nonlocal changed
        if not stanza:
            return stanza
        fields: dict[str, str] = {}
        comp_idx: int | None = None
        for i, ln in enumerate(stanza):
            if ln.lstrip().startswith("#") or ":" not in ln:
                continue
            key, _, val = ln.partition(":")
            key = key.strip().lower()
            fields[key] = val.strip()
            if key == "components":
                comp_idx = i
        if comp_idx is None:
            return stanza
        uris = fields.get("uris", "").split()
        if not _is_debian_source(uris, fields.get("signed-by")):
            return stanza
        existing = stanza[comp_idx].partition(":")[2].split()
        merged = _merge_components(existing, wanted)
        if merged == existing:
            return stanza
        label = stanza[comp_idx].partition(":")[0]
        stanza = list(stanza)
        stanza[comp_idx] = f"{label}: " + " ".join(merged)
        changed = True
        return stanza

    out: list[str] = []
    stanza: list[str] = []
    for line in text.split("\n"):
        if line.strip() == "":
            out.extend(flush(stanza))
            stanza = []
            out.append(line)
        else:
            stanza.append(line)
    out.extend(flush(stanza))
    return "\n".join(out), changed


def _write_root_file(path: Path, content: str, ctx) -> None:
    """Overwrite a root-owned file, preserving its mode. Uses a tempfile +
    `install` so shell quoting never mangles the content (same pattern as
    _install_repos)."""
    try:
        mode = oct(path.stat().st_mode & 0o777)[2:]
    except OSError:
        mode = "0644"
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".apt") as f:
        f.write(content)
        tmp = f.name
    try:
        ctx.run(["install", "-m", mode, tmp, str(path)], sudo=True)
    finally:
        os.unlink(tmp)


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

        # Install the ASCII-armored key directly. apt accepts both .gpg
        # (binary) and .asc (armored) files in `signed-by=…` so long as
        # the filename suffix matches the format. Skipping the dearmor
        # step means prepare doesn't need the `gpg` binary on PATH,
        # which in turn means `python3 setup.py --mode prepare` runs on
        # a host where only `bootstrap.sh prepare` has been done (debs
        # cached but not yet installed).
        keyring = KEYRING_DIR / f"{name}.asc"
        ctx.run(
            ["install", "-m", "0644", str(key_cached), str(keyring)],
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
