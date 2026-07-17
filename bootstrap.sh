#!/usr/bin/env bash
# Bootstrap — handle the host-level apt prereqs that setup.py can't install
# itself (it's written in Python + PyYAML + jsonschema, which have to exist
# before it can run at all).
#
# Split into prepare / install so a prepare run on a connected machine can
# produce a shareable cache/bootstrap/debs/ directory that coworkers pick
# up for an offline install.
#
# Usage:
#   ./bootstrap.sh                 # default: full (prepare + install)
#   ./bootstrap.sh prepare         # download .debs into cache/bootstrap/debs/
#   ./bootstrap.sh install         # install from that cache (or from apt if empty)
#   ./bootstrap.sh full            # prepare + install
#
# After bootstrap finishes, run setup.py yourself:
#   python3 setup.py --mode full
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DEBS="$HERE/cache/bootstrap/debs"

REQUIRED_APT=(
    # Python runtime + libs setup.py imports
    python3
    python3-yaml
    python3-jsonschema
    python3-pip         # pipx/pip_system prepare use pip to pre-download wheels
    python3-venv        # mason's pypi installer runs `python3 -m venv`
    # TLS / signing / network
    ca-certificates
    curl
    gnupg
    # git_sources prepare uses `git clone --mirror`
    git
    # Generic build/extract prereqs some prepare steps lean on: a C
    # toolchain + headers and unzip for archive handling.
    unzip
    gcc
    make
    libc6-dev
)

# ---------------------------------------------------------------------------
# The rest of this script (and setup.py) leans on passwordless sudo for its
# many privileged apt/install calls. If sudo is missing or still asks this
# user for a password, drop a NOPASSWD rule into /etc/sudoers.d/ — done as
# root via `su`, so it prompts once for the root password instead of failing
# on every sudo call downstream.
ensure_passwordless_sudo() {
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        return 0
    fi

    echo "bootstrap: passwordless sudo is not available for '$USER'." >&2
    echo "bootstrap: writing /etc/sudoers.d/$USER — enter the ROOT password when prompted." >&2

    # Run everything that needs root in one su invocation (one password
    # prompt). If sudo isn't installed we install it first, since the rest of
    # bootstrap needs the binary regardless of the sudoers rule. visudo -cf
    # validates the drop-in before it can take effect; a bad file is removed
    # so we never leave sudo in a state that locks the user out.
    su root -c "$(cat <<EOF
set -e
if ! command -v sudo >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y sudo
fi
echo "$USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USER
chmod 0440 /etc/sudoers.d/$USER
if ! visudo -cf /etc/sudoers.d/$USER; then
    rm -f /etc/sudoers.d/$USER
    echo "bootstrap: generated sudoers file failed validation; removed it." >&2
    exit 1
fi
EOF
)"

    if ! sudo -n true 2>/dev/null; then
        echo "bootstrap: still cannot run sudo without a password; aborting." >&2
        exit 1
    fi
    echo "bootstrap: passwordless sudo configured for '$USER'."
}

ensure_passwordless_sudo

MODE="${1:-full}"
case "$MODE" in
    prepare|install|full) ;;
    -h|--help)
        sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "bootstrap: unknown mode '$MODE' (try: prepare, install, full)" >&2
        exit 2
        ;;
esac

# ---------------------------------------------------------------------------
# Self-heal: earlier versions of this script created cache/ via `sudo
# install -d`, leaving it owned by root. That blocked setup.py (running
# as the invoking user) from creating sibling cache/apt/, cache/github/,
# etc. dirs. Chown it back before we do anything else.
if [[ -d "$HERE/cache" ]] \
   && [[ "$(stat -c '%u' "$HERE/cache")" != "$(id -u)" ]]; then
    echo "bootstrap: $HERE/cache is owned by uid=$(stat -c '%u' "$HERE/cache"); chowning to $USER"
    sudo chown -R "$(id -u):$(id -g)" "$HERE/cache"
fi

# ---------------------------------------------------------------------------
do_prepare() {
    echo "bootstrap: prepare — caching apt prereqs under $CACHE_DEBS"
    # Create the cache tree as the invoking user (not sudo). apt will run
    # under sudo for the actual downloads; root can write .deb files into
    # a user-owned dir just fine. If we sudo-created cache/ here instead,
    # it would land owned by root:root 0755, and the user-run `setup.py`
    # couldn't create sibling cache/apt/, cache/github/, etc. dirs.
    mkdir -p "$CACHE_DEBS/partial"

    echo "bootstrap: apt-get update (required so --download-only can resolve)"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update

    # Download the .debs + their full transitive dep closure into our
    # cache dir:
    #   --download-only         don't unpack
    #   --reinstall             force include pkgs already installed on this
    #                           host so the cache is portable to a fresh one
    #   --no-install-recommends match the install-time behavior
    #   Dir::Cache::Archives    private download dir for this invocation;
    #                           keeps /var/cache/apt/archives clean
    echo "bootstrap: downloading ${#REQUIRED_APT[@]} pkgs (+deps) to cache"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --download-only --reinstall --no-install-recommends \
        -o "Dir::Cache::Archives=$CACHE_DEBS" \
        "${REQUIRED_APT[@]}"

    # apt owns the files now; make them readable so coworkers who receive
    # the cache dir as a non-root user can still rsync/copy it around.
    sudo chmod -R a+rX "$CACHE_DEBS"
    local count
    count="$(find "$CACHE_DEBS" -maxdepth 1 -name '*.deb' | wc -l)"
    echo "bootstrap: cached $count .deb files"
}

# ---------------------------------------------------------------------------
do_install() {
    local missing=()
    for pkg in "${REQUIRED_APT[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
             | grep -q 'install ok installed'; then
            missing+=("$pkg")
        fi
    done

    if ((${#missing[@]} == 0)); then
        echo "bootstrap: all required packages already installed"
        return 0
    fi
    echo "bootstrap: missing packages: ${missing[*]}"

    # Cached debs? Install offline. Otherwise fall back to apt (needs net).
    if compgen -G "$CACHE_DEBS"/*.deb >/dev/null; then
        echo "bootstrap: installing from cached .debs at $CACHE_DEBS"
        # `dpkg -i` doesn't resolve deps, but feeding it every cached .deb
        # in one invocation lets it order them itself. Any stragglers get
        # resolved by `apt-get install -f` with the same archive cache
        # pointed at our local dir, so it can do that without network.
        sudo dpkg -i "$CACHE_DEBS"/*.deb || true
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -f \
            --no-download \
            -o "Dir::Cache::Archives=$CACHE_DEBS"
    else
        echo "bootstrap: cache empty — installing via apt (needs network)"
        sudo env DEBIAN_FRONTEND=noninteractive apt-get update
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            --no-install-recommends "${missing[@]}"
    fi
}

# ---------------------------------------------------------------------------
case "$MODE" in
    prepare) do_prepare ;;
    install) do_install ;;
    full)    do_prepare; do_install ;;
esac

cat <<HINT

bootstrap: done.

Next step — run setup.py yourself (not exec'd by bootstrap any more):
    python3 $HERE/setup.py --mode full

    # or match bootstrap's mode:
    python3 $HERE/setup.py --mode prepare    # download everything into ./cache/
    python3 $HERE/setup.py --mode install    # install from ./cache/
HINT
